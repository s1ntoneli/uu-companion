// SPDX-License-Identifier: MIT
//
// UUMic — a minimal virtual audio INPUT device for macOS, written in Swift.
//
// Why this exists: when AirPods (or any Bluetooth headset) are selected as the
// system microphone, macOS switches them from the high-quality A2DP codec to the
// low-quality mono SCO/HFP "phone call" codec, wrecking playback quality. The usual
// fix is to point the input at some *other* real mic — but a Mac Studio has no
// built-in mic. UUMic adds a fake, always-silent input device you can select
// instead, so the AirPods stay in full-quality output mode.
//
// It is a CoreAudio Audio Server Plug-In (a userspace HAL driver — no kernel
// extension). It publishes one device with a single input stream (48 kHz, stereo,
// Float32) that always reads silence.
//
// Implementation notes:
//   * AudioServerPlugInDriverInterface is a C "COM" vtable. We build it from
//     non-capturing closures, which Swift bridges to `@convention(c)` function
//     pointers. All driver state therefore lives in globals.
//   * The realtime IO callbacks (DoIOOperation / GetZeroTimeStamp) touch only C
//     primitives and a lock held via a heap pointer — no ARC, no allocation.

import CoreAudio
import CoreAudio.AudioServerPlugIn
import Darwin
import Foundation
import os

// MARK: - Configuration

private let kDeviceName    = "uu伴侣 Native Mic"
private let kDeviceUID     = "com.uucompanion.native.input.v1"
private let kModelUID      = "com.uucompanion.native.model.v1"
private let kManufacturer  = "uu伴侣"
private let kSampleRate: Float64 = 48_000
private let kChannels: UInt32    = 2
private let kBytesPerFrame: UInt32 = kChannels * UInt32(MemoryLayout<Float32>.size)
private let kRingBufferSize: UInt32 = 19_200   // zero-timestamp period, in frames

private enum Obj {
    static let plugIn:      AudioObjectID = AudioObjectID(kAudioObjectPlugInObject) // == 1
    static let device:      AudioObjectID = 2
    static let streamInput: AudioObjectID = 3
}

private let gLog = Logger(subsystem: "com.timschmolka.uucompanion.native", category: "driver")

// These live in AudioServerPlugIn.h / CFPlugInCOM.h as C macros that Swift can't
// import, so we recreate them here.
private let kIOOpReadInput: UInt32 = 0x7265_6164 // 'read'
// Custom HAL property for injecting interleaved Float32 stereo frames
// from the authorized receiver process into this input-only virtual mic.
private let kAudioPacketSelector: UInt32 = 0x7575_6170 // "uuap"
private let kBufferCapacity = 96_000


private func makeUUID(_ s: String) -> CFUUID { CFUUIDCreateFromString(kCFAllocatorDefault, s as CFString) }
private let gTypeUUID        = makeUUID("443ABAB8-E7B3-491A-B985-BEB9187030DB") // kAudioServerPlugInTypeUUID
private let gDriverIfaceUUID = makeUUID("EEA5773D-CC43-49F1-8E00-8F96E7D23B17") // kAudioServerPlugInDriverInterfaceUUID
private let gIUnknownUUID    = makeUUID("00000000-0000-0000-C000-000000000046") // IUnknownUUID

// MARK: - Global State

// A lock kept behind a heap pointer so the realtime path never takes `&global`
// (which would trip Swift's exclusivity checks under contention).
private let gLock: UnsafeMutablePointer<os_unfair_lock> = {
    let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    p.initialize(to: os_unfair_lock())
    return p
}()
@inline(__always) private func lock()   { os_unfair_lock_lock(gLock) }
@inline(__always) private func unlock() { os_unfair_lock_unlock(gLock) }

private var gRefCount: UInt32 = 0
nonisolated(unsafe) private var gHost: AudioServerPlugInHostRef?
// Single-producer (receiver process) / single-consumer (HAL IO callback)
// ring, guarded by os_unfair_lock within the driver's host process.
// All storage is allocated during plug-in initialization, never on the realtime thread.
private let gPCM: UnsafeMutablePointer<Float32> = {
    let p = UnsafeMutablePointer<Float32>.allocate(capacity: kBufferCapacity * 2)
    p.initialize(repeating: 0, count: kBufferCapacity * 2)
    return p
}()
private var gReadFrame: Int = 0
private var gWriteFrame: Int = 0
private var gPendingFrames: Int = 0
private var gPrimed: Bool = false

@inline(__always)
private func inject(_ data: UnsafeRawPointer, frames: Int) {
    let pcm = data.assumingMemoryBound(to: Float32.self)
    lock()
    for frame in 0..<frames {
        if gPendingFrames >= kBufferCapacity {
            gReadFrame = (gReadFrame + 1) % kBufferCapacity
            gPendingFrames -= 1
        }
        let dst = gWriteFrame * 2
        let src = frame * 2
        gPCM[dst] = pcm[src]
        gPCM[dst + 1] = pcm[src + 1]
        gWriteFrame = (gWriteFrame + 1) % kBufferCapacity
        gPendingFrames += 1
    }
    unlock()
}

// The HAL may consume silence while idle. After an underrun, hold until
// around 80 ms of audio is buffered before resuming normal sampling.
@inline(__always)
private func readInput(_ raw: UnsafeMutableRawPointer, frames: Int) {
    let out = raw.assumingMemoryBound(to: Float32.self)
    lock()
    if !gPrimed && gPendingFrames >= 3_840 { gPrimed = true }
    var readCount = 0
    if gPrimed {
        readCount = min(frames, gPendingFrames)
        for frame in 0..<readCount {
            let src = gReadFrame * 2
            out[frame * 2] = gPCM[src]
            out[frame * 2 + 1] = gPCM[src + 1]
            gReadFrame = (gReadFrame + 1) % kBufferCapacity
            gPendingFrames -= 1
        }
        if gPendingFrames == 0 { gPrimed = false }
    }
    unlock()
    if readCount < frames {
        memset(out.advanced(by: readCount * 2), 0, (frames - readCount) * 2 * MemoryLayout<Float32>.stride)
    }
}


private var gIOCount: UInt64 = 0
private var gHostTicksPerFrame: Float64 = 0
private var gNumberTimeStamps: UInt64 = 0
private var gAnchorHostTime: UInt64 = 0

// MARK: - Format helpers

private func mockFormat() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: kSampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        mBytesPerPacket: kBytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: kBytesPerFrame,
        mChannelsPerFrame: kChannels,
        mBitsPerChannel: 32,
        mReserved: 0)
}

// MARK: - PropertyValue

/// A property's value paired with how it encodes into a CoreAudio buffer.
///
/// This is the single source of truth for the property system: size, presence,
/// and data all derive from `value(for:)` below, so they can never disagree.
/// The raw-pointer `storeBytes` calls — the only genuinely "unsafe" part of the
/// property layer — are confined to `write(to:)`.
private enum PropertyValue {
    case uint32(UInt32)
    case objectID(AudioObjectID)
    case float64(Float64)
    case string(String)
    case pair(UInt32, UInt32)
    case asbd(AudioStreamBasicDescription)
    case rangedFormat(AudioStreamRangedDescription)
    case valueRange(AudioValueRange)
    case channelLayout(AudioChannelLayout)
    case customInfo(AudioServerPlugInCustomPropertyInfo)
    case cfData([UInt8])
    case empty

    var byteSize: UInt32 {
        switch self {
        case .uint32, .objectID: UInt32(MemoryLayout<UInt32>.size)
        case .float64:           UInt32(MemoryLayout<Float64>.size)
        case .string:            UInt32(MemoryLayout<UnsafeMutableRawPointer>.size) // CFStringRef
        case .pair:              UInt32(2 * MemoryLayout<UInt32>.size)
        case .asbd:              UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        case .rangedFormat:      UInt32(MemoryLayout<AudioStreamRangedDescription>.size)
        case .valueRange:        UInt32(MemoryLayout<AudioValueRange>.size)
        case .channelLayout:     UInt32(MemoryLayout<AudioChannelLayout>.size)
        case .customInfo:        UInt32(MemoryLayout<AudioServerPlugInCustomPropertyInfo>.size)
        case .cfData:            UInt32(MemoryLayout<UnsafeMutableRawPointer>.size)
        case .empty:             0
        }
    }

    /// Encodes into `dst`. Callers only invoke this once they've confirmed the
    /// destination buffer is large enough, so the CFString retain can't leak.
    func write(to dst: UnsafeMutableRawPointer) {
        switch self {
        case let .uint32(v):        dst.storeBytes(of: v, as: UInt32.self)
        case let .objectID(v):      dst.storeBytes(of: v, as: AudioObjectID.self)
        case let .float64(v):       dst.storeBytes(of: v, as: Float64.self)
        case let .string(s):
            dst.storeBytes(of: Unmanaged.passRetained(s as CFString).toOpaque(), as: UnsafeMutableRawPointer.self)
        case let .pair(a, b):
            dst.storeBytes(of: a, toByteOffset: 0, as: UInt32.self)
            dst.storeBytes(of: b, toByteOffset: MemoryLayout<UInt32>.size, as: UInt32.self)
        case let .asbd(v):          dst.storeBytes(of: v, as: AudioStreamBasicDescription.self)
        case let .rangedFormat(v):  dst.storeBytes(of: v, as: AudioStreamRangedDescription.self)
        case let .valueRange(v):    dst.storeBytes(of: v, as: AudioValueRange.self)
        case let .channelLayout(v): dst.storeBytes(of: v, as: AudioChannelLayout.self)
        case let .customInfo(v):    dst.storeBytes(of: v, as: AudioServerPlugInCustomPropertyInfo.self)
        case let .cfData(bytes):
            let value = bytes.withUnsafeBufferPointer {
                CFDataCreate(kCFAllocatorDefault, $0.baseAddress, bytes.count)!
            }
            dst.storeBytes(of: Unmanaged.passRetained(value).toOpaque(), as: UnsafeMutableRawPointer.self)
        case .empty:                break
        }
    }
}

// MARK: - Interface vtable

private let gInterface: UnsafeMutablePointer<AudioServerPlugInDriverInterface> = {
    let p = UnsafeMutablePointer<AudioServerPlugInDriverInterface>.allocate(capacity: 1)
    p.initialize(to: makeInterface())
    return p
}()

private let gDriverRef: UnsafeMutablePointer<UnsafeMutablePointer<AudioServerPlugInDriverInterface>?> = {
    let pp = UnsafeMutablePointer<UnsafeMutablePointer<AudioServerPlugInDriverInterface>?>.allocate(capacity: 1)
    pp.initialize(to: gInterface)
    return pp
}()

private func makeInterface() -> AudioServerPlugInDriverInterface {
    AudioServerPlugInDriverInterface(
        _reserved: nil,
        QueryInterface: { (driver, uuid, outInterface) in UUMicQueryInterface(driver, uuid, outInterface) },
        AddRef:  { _ in lock(); if gRefCount < UInt32.max { gRefCount += 1 }; let r = gRefCount; unlock(); return r },
        Release: { _ in lock(); if gRefCount > 0 { gRefCount -= 1 }; let r = gRefCount; unlock(); return r },
        Initialize: { (_, host) in
            gHost = host
            gLog.info("UUMic initialized (device \"\(kDeviceName, privacy: .public)\", \(kSampleRate) Hz, \(kChannels) ch)")
            return noErr
        },
        CreateDevice: { _, _, _, _ in kAudioHardwareUnsupportedOperationError },
        DestroyDevice: { _, _ in kAudioHardwareUnsupportedOperationError },
        AddDeviceClient: { _, _, _ in noErr },
        RemoveDeviceClient: { _, _, _ in noErr },
        PerformDeviceConfigurationChange: { _, _, _, _ in noErr },
        AbortDeviceConfigurationChange: { _, _, _, _ in noErr },
        HasProperty: { (_, obj, _, addr) in DarwinBoolean(UUMicHasProperty(obj, addr)) },
        IsPropertySettable: { (_, obj, _, addr, outSettable) in UUMicIsSettable(obj, addr, outSettable) },
        GetPropertyDataSize: { (_, obj, _, addr, _, _, outSize) in UUMicGetPropertyDataSize(obj, addr, outSize) },
        GetPropertyData: { (_, obj, _, addr, _, qd, inSize, outSize, outData) in
            UUMicGetPropertyData(obj, addr, qd, inSize, outSize, outData)
        },
        SetPropertyData: { (_, obj, _, addr, _, _, inSize, inData) in
            UUMicSetPropertyData(obj, addr, inSize, inData)
        },
        StartIO: { (_, device, _) in UUMicStartIO(device) },
        StopIO:  { (_, device, _) in UUMicStopIO(device) },
        GetZeroTimeStamp: { (_, device, _, outSampleTime, outHostTime, outSeed) in
            UUMicGetZeroTimeStamp(device, outSampleTime, outHostTime, outSeed)
        },
        WillDoIOOperation: { (_, _, _, opID, outWillDo, outWillDoInPlace) in
            let willDo = (opID == kIOOpReadInput)
            outWillDo.pointee = DarwinBoolean(willDo)
            outWillDoInPlace.pointee = DarwinBoolean(true)
            return noErr
        },
        BeginIOOperation: { _, _, _, _, _, _ in noErr },
        DoIOOperation: { (_, _, _, _, opID, frameSize, _, ioMainBuffer, _) in
            if opID == kIOOpReadInput, let buf = ioMainBuffer {
                readInput(buf, frames: Int(frameSize))
            }
            return noErr
        },
        EndIOOperation: { _, _, _, _, _, _ in noErr })
}

// MARK: - Factory (entry point named in Info.plist)

@_cdecl("UUMicCreate")
public func UUMicCreate(_ allocator: CFAllocator?, _ requestedTypeUUID: CFUUID?) -> UnsafeMutableRawPointer? {
    guard let requested = requestedTypeUUID,
          CFEqual(requested, gTypeUUID) else { return nil }
    return UnsafeMutableRawPointer(gDriverRef)
}

// MARK: - COM

private func UUMicQueryInterface(_ driver: UnsafeMutableRawPointer?,
                                _ uuid: CFUUIDBytes,
                                _ outInterface: UnsafeMutablePointer<LPVOID?>?) -> HRESULT {
    guard driver == UnsafeMutableRawPointer(gDriverRef), let outInterface else {
        return HRESULT(kAudioHardwareBadObjectError)
    }
    let requested = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, uuid)
    if CFEqual(requested, gDriverIfaceUUID) || CFEqual(requested, gIUnknownUUID) {
        lock(); if gRefCount < UInt32.max { gRefCount += 1 }; unlock()
        outInterface.pointee = UnsafeMutableRawPointer(gDriverRef)
        return HRESULT(0) // S_OK
    }
    return HRESULT(bitPattern: 0x8000_0004) // E_NOINTERFACE
}

// MARK: - Property access

private func UUMicHasProperty(_ obj: AudioObjectID, _ addr: UnsafePointer<AudioObjectPropertyAddress>?) -> Bool {
    guard let a = addr?.pointee else { return false }
    return value(for: obj, a.mSelector, scope: a.mScope, qualifier: nil) != nil
}

private func UUMicIsSettable(_ obj: AudioObjectID,
                            _ addr: UnsafePointer<AudioObjectPropertyAddress>?,
                            _ outSettable: UnsafeMutablePointer<DarwinBoolean>?) -> OSStatus {
    guard let sel = addr?.pointee.mSelector else { return kAudioHardwareBadObjectError }
    switch sel {
    case kAudioPacketSelector:
        outSettable?.pointee = DarwinBoolean(obj == Obj.device)
    case kAudioDevicePropertyNominalSampleRate,
         kAudioStreamPropertyVirtualFormat,
         kAudioStreamPropertyPhysicalFormat,
         kAudioStreamPropertyIsActive:
        outSettable?.pointee = true
    default:
        outSettable?.pointee = false
    }
    return noErr
}

/// The single source of truth for every property UUMic exposes. Returns `nil`
/// for anything unsupported (which maps to `kAudioHardwareUnknownPropertyError`).
private func value(for object: AudioObjectID,
                   _ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope,
                   qualifier: UnsafeRawPointer?) -> PropertyValue? {
    switch object {
    case Obj.plugIn:
        switch selector {
        case kAudioObjectPropertyBaseClass:    return .uint32(UInt32(kAudioObjectClassID))
        case kAudioObjectPropertyClass:        return .uint32(UInt32(kAudioPlugInClassID))
        case kAudioObjectPropertyOwner:        return .objectID(AudioObjectID(kAudioObjectUnknown))
        case kAudioObjectPropertyManufacturer: return .string(kManufacturer)
        case kAudioObjectPropertyOwnedObjects,
             kAudioPlugInPropertyDeviceList:   return .objectID(Obj.device)
        case kAudioPlugInPropertyTranslateUIDToDevice:
            let uid = qualifier?.load(as: CFString.self)
            let match = uid.map { CFEqual($0, kDeviceUID as CFString) } ?? false
            return .objectID(match ? Obj.device : AudioObjectID(kAudioObjectUnknown))
        case kAudioPlugInPropertyResourceBundle: return .string("")
        default: return nil
        }

    case Obj.device:
        switch selector {
        case kAudioObjectPropertyCustomPropertyInfoList:
            return .customInfo(AudioServerPlugInCustomPropertyInfo(
                mSelector: kAudioPacketSelector,
                mPropertyDataType: kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                mQualifierDataType: kAudioServerPlugInCustomPropertyDataTypeNone))
        case kAudioPacketSelector: return .cfData([])
        case kAudioObjectPropertyBaseClass:    return .uint32(UInt32(kAudioObjectClassID))
        case kAudioObjectPropertyClass:        return .uint32(UInt32(kAudioDeviceClassID))
        case kAudioObjectPropertyOwner:        return .objectID(Obj.plugIn)
        case kAudioObjectPropertyName:         return .string(kDeviceName)
        case kAudioObjectPropertyManufacturer: return .string(kManufacturer)
        case kAudioObjectPropertyOwnedObjects,
             kAudioDevicePropertyStreams:
            return scope == kAudioObjectPropertyScopeOutput ? .empty : .objectID(Obj.streamInput)
        case kAudioDevicePropertyDeviceUID:      return .string(kDeviceUID)
        case kAudioDevicePropertyModelUID:       return .string(kModelUID)
        case kAudioDevicePropertyTransportType:  return .uint32(UInt32(kAudioDeviceTransportTypeVirtual))
        case kAudioDevicePropertyRelatedDevices: return .objectID(Obj.device)
        case kAudioDevicePropertyClockDomain:    return .uint32(0)
        case kAudioDevicePropertyDeviceIsAlive:  return .uint32(1)
        case kAudioDevicePropertyDeviceIsRunning:
            lock(); let running = gIOCount > 0; unlock()
            return .uint32(running ? 1 : 0)
        case kAudioDevicePropertyDeviceCanBeDefaultDevice,
             kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return .uint32(1)
        case kAudioDevicePropertyLatency,
             kAudioDevicePropertySafetyOffset,
             kAudioDevicePropertyIsHidden:       return .uint32(0)
        case kAudioObjectPropertyControlList:    return .empty
        case kAudioDevicePropertyNominalSampleRate: return .float64(kSampleRate)
        case kAudioDevicePropertyAvailableNominalSampleRates:
            return .valueRange(AudioValueRange(mMinimum: kSampleRate, mMaximum: kSampleRate))
        case kAudioDevicePropertyPreferredChannelsForStereo: return .pair(1, 2)
        case kAudioDevicePropertyPreferredChannelLayout:
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            return .channelLayout(layout)
        case kAudioDevicePropertyZeroTimeStampPeriod: return .uint32(kRingBufferSize)
        default: return nil
        }

    case Obj.streamInput:
        switch selector {
        case kAudioObjectPropertyBaseClass:      return .uint32(UInt32(kAudioObjectClassID))
        case kAudioObjectPropertyClass:          return .uint32(UInt32(kAudioStreamClassID))
        case kAudioObjectPropertyOwner:          return .objectID(Obj.device)
        case kAudioObjectPropertyOwnedObjects:   return .empty
        case kAudioStreamPropertyIsActive:       return .uint32(1)
        case kAudioStreamPropertyDirection:      return .uint32(1) // 1 = input
        case kAudioStreamPropertyTerminalType:   return .uint32(UInt32(kAudioStreamTerminalTypeMicrophone))
        case kAudioStreamPropertyStartingChannel: return .uint32(1)
        case kAudioStreamPropertyLatency:        return .uint32(0)
        case kAudioStreamPropertyVirtualFormat,
             kAudioStreamPropertyPhysicalFormat: return .asbd(mockFormat())
        case kAudioStreamPropertyAvailableVirtualFormats,
             kAudioStreamPropertyAvailablePhysicalFormats:
            return .rangedFormat(AudioStreamRangedDescription(
                mFormat: mockFormat(),
                mSampleRateRange: AudioValueRange(mMinimum: kSampleRate, mMaximum: kSampleRate)))
        default: return nil
        }

    default:
        return nil
    }
}

private func UUMicGetPropertyDataSize(_ obj: AudioObjectID,
                                     _ addr: UnsafePointer<AudioObjectPropertyAddress>?,
                                     _ outSize: UnsafeMutablePointer<UInt32>?) -> OSStatus {
    guard let a = addr?.pointee else { return kAudioHardwareBadObjectError }
    guard let v = value(for: obj, a.mSelector, scope: a.mScope, qualifier: nil) else {
        return kAudioHardwareUnknownPropertyError
    }
    outSize?.pointee = v.byteSize
    return noErr
}

private func UUMicGetPropertyData(_ obj: AudioObjectID,
                                 _ addr: UnsafePointer<AudioObjectPropertyAddress>?,
                                 _ qualData: UnsafeRawPointer?,
                                 _ inDataSize: UInt32,
                                 _ outSize: UnsafeMutablePointer<UInt32>?,
                                 _ outData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let a = addr?.pointee else { return kAudioHardwareBadObjectError }
    guard let v = value(for: obj, a.mSelector, scope: a.mScope, qualifier: qualData) else {
        return kAudioHardwareUnknownPropertyError
    }
    // Write only when the client's buffer can hold the whole value (all values
    // UUMic exposes are scalar or single-element, so it's all-or-nothing).
    if let outData, inDataSize >= v.byteSize {
        v.write(to: outData)
        outSize?.pointee = v.byteSize
    } else {
        outSize?.pointee = 0
    }
    return noErr
}

private func UUMicSetPropertyData(_ obj: AudioObjectID,
                                 _ addr: UnsafePointer<AudioObjectPropertyAddress>?,
                                 _ inDataSize: UInt32,
                                 _ inData: UnsafeRawPointer?) -> OSStatus {
    guard let sel = addr?.pointee.mSelector else { return kAudioHardwareBadObjectError }
    if obj == Obj.device && sel == kAudioPacketSelector {
        guard let inData else { return kAudioHardwareIllegalOperationError }
        // Out-of-process Core Audio transports custom properties as a
        // CFPropertyList. The value is a CFDataRef containing Float32 frames.
        if inDataSize == UInt32(MemoryLayout<UnsafeMutableRawPointer>.size) {
            guard let opaque = inData.load(as: UnsafeMutableRawPointer?.self) else {
                return kAudioHardwareIllegalOperationError
            }
            let data = Unmanaged<CFData>.fromOpaque(opaque).takeUnretainedValue()
            let count = CFDataGetLength(data)
            guard count > 0, count <= 131_072,
                  count % Int(kBytesPerFrame) == 0,
                  let bytes = CFDataGetBytePtr(data) else {
                return kAudioHardwareIllegalOperationError
            }
            inject(UnsafeRawPointer(bytes), frames: count / Int(kBytesPerFrame))
            return noErr
        }
        // Also permit direct factory testing without the Core Audio proxy.
        guard inDataSize > 0, inDataSize <= 131_072,
              inDataSize % kBytesPerFrame == 0 else {
            return kAudioHardwareIllegalOperationError
        }
        inject(inData, frames: Int(inDataSize / kBytesPerFrame))
        return noErr
    }
    switch sel {
    case kAudioDevicePropertyNominalSampleRate:
        let rate = inData?.load(as: Float64.self) ?? 0
        return rate == kSampleRate ? noErr : kAudioHardwareIllegalOperationError
    case kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat:
        guard let f = inData?.load(as: AudioStreamBasicDescription.self) else { return kAudioHardwareIllegalOperationError }
        return (f.mSampleRate == kSampleRate && f.mChannelsPerFrame == kChannels) ? noErr : kAudioHardwareIllegalOperationError
    case kAudioStreamPropertyIsActive:
        return noErr
    default:
        return kAudioHardwareUnknownPropertyError
    }
}

// MARK: - IO

private func UUMicStartIO(_ device: AudioObjectID) -> OSStatus {
    guard device == Obj.device else { return kAudioHardwareBadObjectError }
    lock()
    if gIOCount == 0 {
        gReadFrame = gWriteFrame
        gPendingFrames = 0
        gPrimed = false
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let hostClockFrequency = (Float64(tb.denom) / Float64(tb.numer)) * 1.0e9
        gHostTicksPerFrame = hostClockFrequency / kSampleRate
        gNumberTimeStamps = 0
        gAnchorHostTime = mach_absolute_time()
    }
    gIOCount += 1
    unlock()
    return noErr
}

private func UUMicStopIO(_ device: AudioObjectID) -> OSStatus {
    guard device == Obj.device else { return kAudioHardwareBadObjectError }
    lock(); if gIOCount > 0 { gIOCount -= 1 }; unlock()
    return noErr
}

private func UUMicGetZeroTimeStamp(_ device: AudioObjectID,
                                  _ outSampleTime: UnsafeMutablePointer<Float64>?,
                                  _ outHostTime: UnsafeMutablePointer<UInt64>?,
                                  _ outSeed: UnsafeMutablePointer<UInt64>?) -> OSStatus {
    guard device == Obj.device else { return kAudioHardwareBadObjectError }
    lock()
    let currentHostTime = mach_absolute_time()
    let hostTicksPerRingBuffer = gHostTicksPerFrame * Float64(kRingBufferSize)
    let nextTicks = Float64(gNumberTimeStamps + 1) * hostTicksPerRingBuffer
    let nextHostTime = gAnchorHostTime + UInt64(nextTicks)
    if currentHostTime >= nextHostTime { gNumberTimeStamps += 1 }
    outSampleTime?.pointee = Float64(gNumberTimeStamps * UInt64(kRingBufferSize))
    outHostTime?.pointee = gAnchorHostTime + UInt64(Float64(gNumberTimeStamps) * hostTicksPerRingBuffer)
    outSeed?.pointee = 1
    unlock()
    return noErr
}
