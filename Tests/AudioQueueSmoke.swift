import AudioToolbox
import CoreAudio
import Foundation
setvbuf(stdout,nil,_IOLBF,0)
let sys=AudioObjectID(kAudioObjectSystemObject)
func prop<T>(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector)->[T]{
    var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var s:UInt32=0
    guard AudioObjectGetPropertyDataSize(object,&a,0,nil,&s)==noErr,s>0 else{return []}
    let p=UnsafeMutableRawPointer.allocate(byteCount:Int(s),alignment:MemoryLayout<T>.alignment)
    defer{p.deallocate()}
    guard AudioObjectGetPropertyData(object,&a,0,nil,&s,p)==noErr else {return []}
    return Array(UnsafeBufferPointer(start:p.bindMemory(to:T.self,capacity:Int(s)/MemoryLayout<T>.stride),count:Int(s)/MemoryLayout<T>.stride))
}
let ids:[AudioDeviceID]=prop(sys,kAudioHardwarePropertyDevices)
guard let black=ids.last else{exit(2)}
var addr=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceUID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
var managed:Unmanaged<CFString>?
var size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
let uidStatus=AudioObjectGetPropertyData(black,&addr,0,nil,&size,&managed)
guard uidStatus==noErr, let managed else {print("no device UID",uidStatus);exit(3)}
var uid=managed.takeRetainedValue()
print("BlackHole UID",uid)
var format=AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
var queue:AudioQueueRef?
print("creating AudioQueue")
let st=AudioQueueNewOutput(&format,{ _, queue, buffer in
    buffer.pointee.mAudioDataByteSize=buffer.pointee.mAudioDataBytesCapacity
    memset(buffer.pointee.mAudioData,0,Int(buffer.pointee.mAudioDataByteSize))
    AudioQueueEnqueueBuffer(queue,buffer,0,nil)
},nil,nil,nil,0,&queue)
print("newOutput result",st)
guard st == noErr, let q=queue else {exit(4)}
print("setting current audio output device")
let result=withUnsafePointer(to:&uid){p in
    AudioQueueSetProperty(q,kAudioQueueProperty_CurrentDevice,p,UInt32(MemoryLayout<CFString>.size))
}
print("setDevice result",result)
for _ in 0..<3 {
    var buffer:AudioQueueBufferRef?
    let a=AudioQueueAllocateBuffer(q, 2048*8, &buffer)
    print("alloc result",a)
    guard let buffer else {continue}
    buffer.pointee.mAudioDataByteSize=buffer.pointee.mAudioDataBytesCapacity
    memset(buffer.pointee.mAudioData,0,Int(buffer.pointee.mAudioDataByteSize))
    print("enqueue result",AudioQueueEnqueueBuffer(q,buffer,0,nil))
}
print("starting")
print("start status",AudioQueueStart(q,nil))
Thread.sleep(forTimeInterval:2)
print("stopping")
AudioQueueStop(q,true)
AudioQueueDispose(q,true)
print("OK")
