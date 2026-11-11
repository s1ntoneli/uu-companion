import CoreAudio
import Foundation
let system = AudioObjectID(kAudioObjectSystemObject)
func get<T>(_ selector: AudioObjectPropertySelector, object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject)) -> [T] {
    var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var s:UInt32=0
    guard AudioObjectGetPropertyDataSize(object,&a,0,nil,&s)==noErr,s>0 else{return []}
    let ptr=UnsafeMutableRawPointer.allocate(byteCount:Int(s),alignment:MemoryLayout<T>.alignment);defer{ptr.deallocate()}
    guard AudioObjectGetPropertyData(object,&a,0,nil,&s,ptr)==noErr else{return []}
    return Array(UnsafeBufferPointer(start:ptr.bindMemory(to:T.self,capacity:Int(s)/MemoryLayout<T>.stride),count:Int(s)/MemoryLayout<T>.stride))
}
func name(_ id: AudioDeviceID) -> String {
    var a=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var n:Unmanaged<CFString>?;var s=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id,&a,0,nil,&s,&n)==noErr,let v=n else{return ""}
    return v.takeRetainedValue() as String
}
func select(_ prop: AudioObjectPropertySelector, _ id:AudioDeviceID) {
    var v=id
    var a=AudioObjectPropertyAddress(mSelector:prop,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    let code=AudioObjectSetPropertyData(system,&a,0,nil,UInt32(MemoryLayout<AudioDeviceID>.size),&v)
    print("set \(prop) -> \(id) \(name(id)): \(code)")
}
let dev:[AudioDeviceID]=get(kAudioHardwarePropertyDevices)
let beforeInput:[AudioDeviceID]=get(kAudioHardwarePropertyDefaultInputDevice)
let beforeOutput:[AudioDeviceID]=get(kAudioHardwarePropertyDefaultOutputDevice)
let beforeSystem:[AudioDeviceID]=get(kAudioHardwarePropertyDefaultSystemOutputDevice)
print("devices:",dev.map{"\($0) \(name($0))"})
print("before input:",beforeInput.map(name),"output:",beforeOutput.map(name),"system:",beforeSystem.map(name))
guard let speakers=dev.first(where:{name($0)=="Mac mini Speakers"}) else {fatalError("No built-in speakers")}
if beforeOutput.first != speakers { select(kAudioHardwarePropertyDefaultOutputDevice,speakers) }
if beforeSystem.first != speakers { select(kAudioHardwarePropertyDefaultSystemOutputDevice,speakers) }
let afterInput:[AudioDeviceID]=get(kAudioHardwarePropertyDefaultInputDevice)
let afterOutput:[AudioDeviceID]=get(kAudioHardwarePropertyDefaultOutputDevice)
let afterSystem:[AudioDeviceID]=get(kAudioHardwarePropertyDefaultSystemOutputDevice)
print("after input:",afterInput.map(name),"output:",afterOutput.map(name),"system:",afterSystem.map(name))
