import CoreAudio
import Foundation

let nameNeedle = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !nameNeedle.isEmpty else {print("Usage: select-input DEVICE_NAME");exit(2)}
let system=AudioObjectID(kAudioObjectSystemObject)
func listDevices()->[AudioDeviceID]{
    var addr=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var bytes:UInt32=0
    guard AudioObjectGetPropertyDataSize(system,&addr,0,nil,&bytes)==noErr else {return []}
    var ids=[AudioDeviceID](repeating:0,count:Int(bytes)/MemoryLayout<AudioDeviceID>.stride)
    let result=ids.withUnsafeMutableBytes {raw in
        AudioObjectGetPropertyData(system,&addr,0,nil,&bytes,raw.baseAddress!)
    }
    return result == noErr ? ids : []
}
func name(_ d:AudioDeviceID)->String {
    var a=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var bytes=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var raw:Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(d,&a,0,nil,&bytes,&raw)==noErr,let raw else{return ""}
    return raw.takeRetainedValue() as String
}
guard let device=listDevices().first(where:{name($0)==nameNeedle}) else {print("Device not found:",nameNeedle);exit(3)}
var a=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
var chosen=device
let status=AudioObjectSetPropertyData(system,&a,0,nil,UInt32(MemoryLayout<AudioDeviceID>.size),&chosen)
print("Selected default input:",nameNeedle,"status:",status)
if status != noErr {exit(4)}
