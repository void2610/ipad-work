import CoreAudio
import Foundation

// Typeless のプロセスがマイクを使っている (聞き取っている) かを読む。聞き取り中なら 1 で終わる
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

var listAddress = address(kAudioHardwarePropertyProcessObjectList)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size)
var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processes)
let isListening = processes.contains { process in
    var bundleAddress = address(kAudioProcessPropertyBundleID)
    var bundle: Unmanaged<CFString>?
    var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr,
          (bundle?.takeRetainedValue() as String?)?.hasPrefix("now.typeless") == true
    else { return false }
    var runningAddress = address(kAudioProcessPropertyIsRunningInput)
    var running: UInt32 = 0
    var runningSize = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running)
    return running != 0
}
print(isListening ? "Typeless が聞き取り中" : "Typeless は聞き取っていない")
exit(isListening ? 1 : 0)
