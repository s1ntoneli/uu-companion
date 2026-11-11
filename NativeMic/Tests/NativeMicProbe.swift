import AudioToolbox
import CoreAudio
import Foundation

// Local-only audio verification helper. Writes a 440Hz synthetic stereo tone
// to the custom HAL device property for 6 seconds, never records to disk.
func getIDs() -> [AudioDeviceID] {
    var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var bytes:UInt32=0
    let system=AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system,&address,0,nil,&bytes)==noErr else{return []}
    var IDs=[AudioDeviceID](repeating:0,count:Int(bytes)/MemoryLayout<AudioDeviceID>.stride)
    let result=IDs.withUnsafeMutableBytes { raw in
        AudioObjectGetPropertyData(system,&address,0,nil,&bytes,raw.baseAddress!)
    }
    return result == noErr ? IDs : []
}
func name(_ dev:AudioDeviceID)->String {
    var address=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var s=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var val:Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(dev,&address,0,nil,&s,&val)==noErr, let val else {return ""}
    return val.takeRetainedValue() as String
}

guard let device=getIDs().first(where:{name($0)=="uu伴侣 Native Mic"}) else{
    print("Native microphone not found")
    exit(2)
}
var addr=AudioObjectPropertyAddress(mSelector:0x7575_6170,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
print("Has uuap property:",AudioObjectHasProperty(device,&addr))
guard AudioObjectHasProperty(device,&addr) else { exit(3) }
var settable=DarwinBoolean(false)
let setStatus=AudioObjectIsPropertySettable(device,&addr,&settable)
print("Can inject PCM:",setStatus,settable.boolValue)
guard setStatus==noErr,settable.boolValue else{exit(4)}
let frequency=440.0, rate=48000.0, samplesPerPacket=480
var successful=0
for b in 0..<600 {
    var pcm=[Float](repeating:0,count:samplesPerPacket*2)
    for i in 0..<samplesPerPacket {
        let t=Double(b*samplesPerPacket+i)/rate
        let sample=Float(0.15*sin(2*Double.pi*frequency*t))
        pcm[2*i]=sample
        pcm[2*i+1]=sample
    }
    var cfData=pcm.withUnsafeBytes { raw -> CFData in
        CFDataCreate(kCFAllocatorDefault, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)!
    }
    let err=withUnsafePointer(to: &cfData) {
        AudioObjectSetPropertyData(device,&addr,0,nil,
                                   UInt32(MemoryLayout<CFData>.size),$0)
    }
    if err != noErr { print("HAL injection error:",err,"batch:",b);exit(5) }
    successful+=1
    usleep(10000)
}
print("Successfully injected",successful,"audio packets into uu伴侣 Native Mic")
