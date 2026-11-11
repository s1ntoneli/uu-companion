import Foundation
import CoreAudio
func property<T>(_ obj: AudioObjectID,_ selector: AudioObjectPropertySelector,_ scope: AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal) -> [T] {
 var addr=AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
 var size:UInt32=0
 guard AudioObjectGetPropertyDataSize(obj,&addr,0,nil,&size)==noErr,size>0 else {return []}
 let ptr=UnsafeMutableRawPointer.allocate(byteCount:Int(size),alignment:MemoryLayout<T>.alignment)
 defer{ptr.deallocate()}
 guard AudioObjectGetPropertyData(obj,&addr,0,nil,&size,ptr)==noErr else{return []}
 return Array(UnsafeBufferPointer(start:ptr.bindMemory(to:T.self,capacity:Int(size)/MemoryLayout<T>.stride),count:Int(size)/MemoryLayout<T>.stride))
}
func bundle(_ id: AudioObjectID) -> String {
 var addr=AudioObjectPropertyAddress(mSelector:kAudioProcessPropertyBundleID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
 var ptr:Unmanaged<CFString>?
 var size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
 guard AudioObjectGetPropertyData(id,&addr,0,nil,&size,&ptr)==noErr,let v=ptr else{return "n/a"}
 return v.takeRetainedValue() as String
}
let procs:[AudioObjectID]=property(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyProcessObjectList)
let devices:[AudioDeviceID]=property(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDevices)
print("all devices:",devices)
for p in procs {
 let pid:[pid_t]=property(p,kAudioProcessPropertyPID)
 let run:[UInt32]=property(p,kAudioProcessPropertyIsRunningInput)
 guard run.first ?? 0 != 0 else {continue}
 let input:[AudioObjectID]=property(p,kAudioProcessPropertyDevices,kAudioObjectPropertyScopeInput)
 let global:[AudioObjectID]=property(p,kAudioProcessPropertyDevices,kAudioObjectPropertyScopeGlobal)
 let output:[AudioObjectID]=property(p,kAudioProcessPropertyDevices,kAudioObjectPropertyScopeOutput)
 print("rec PID:",pid.first ?? 0,"bundle:",bundle(p),"input:",input,"global:",global,"output:",output, "object:",p)
}
