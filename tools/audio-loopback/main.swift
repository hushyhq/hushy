import Foundation
import AVFoundation
import CoreAudio
// Synthetic playback/capture utility. Selects an explicit device on this engine only;
// it never changes system default input/output and never reads the real microphone.
guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
 fputs("Usage: audio-loopback AUDIO_FILE [NEW_CAPTURE_WAV]\n", stderr)
 exit(2)
}
if CommandLine.arguments.count == 3, FileManager.default.fileExists(atPath:CommandLine.arguments[2]) {
 fputs("Refusing to overwrite existing capture\n", stderr)
 exit(2)
}
var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
precondition(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr)
var ids = [AudioDeviceID](repeating:0, count:Int(size)/MemoryLayout<AudioDeviceID>.size)
precondition(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr)
var chosen: AudioDeviceID?
var impostor = false
func isVirtualTransport(_ id: AudioDeviceID) -> Bool {
 var a = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyTransportType,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
 var transport: UInt32 = 0
 var n = UInt32(MemoryLayout<UInt32>.size)
 return AudioObjectGetPropertyData(id,&a,0,nil,&n,&transport)==noErr && transport == kAudioDeviceTransportTypeVirtual
}
for id in ids {
 var a = AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
 var name: Unmanaged<CFString>?
 var n=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
 if AudioObjectGetPropertyData(id,&a,0,nil,&n,&name)==noErr, let name, name.takeRetainedValue() as String == "BlackHole 2ch" {
  // A device only named BlackHole (for example a real interface renamed) is never played into.
  if isVirtualTransport(id) { chosen=id } else { impostor=true }
 }
}
if chosen == nil, impostor {
 fputs("Refusing: a device named BlackHole 2ch is present but is not a virtual transport\n", stderr)
 exit(3)
}
guard var device=chosen else { fatalError("BlackHole missing") }
let engine=AVAudioEngine(), player=AVAudioPlayerNode()
engine.attach(player)
engine.connect(player,to:engine.mainMixerNode,format:nil)
guard let unit=engine.outputNode.audioUnit else { fatalError("Output unit missing") }
let status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,UInt32(MemoryLayout<AudioDeviceID>.size))
guard status==noErr else { fatalError("Device selection failed: \(status)") }
let capturePath=CommandLine.arguments.count>2 ? CommandLine.arguments[2] : nil
let lock=NSLock(); var chunks:[[Float]]=[]; var captureRate:Double=0
if capturePath != nil {
 guard let inputUnit=engine.inputNode.audioUnit else { fatalError("Input unit missing") }
 let result=AudioUnitSetProperty(inputUnit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,UInt32(MemoryLayout<AudioDeviceID>.size))
 guard result==noErr else { fatalError("Input selection failed: \(result)") }
 let fmt=engine.inputNode.outputFormat(forBus:0)
 captureRate=fmt.sampleRate
 guard fmt.channelCount>0, captureRate>0 else { fatalError("Invalid input format") }
 print("Capturing selected BlackHole input: \(fmt)")
 engine.inputNode.installTap(onBus:0,bufferSize:512,format:fmt) { buffer,_ in
  guard let channels=buffer.floatChannelData else { return }
  let copy=Array(UnsafeBufferPointer(start:channels[0],count:Int(buffer.frameLength)))
  lock.lock();chunks.append(copy);lock.unlock()
 }
}
let file=try AVAudioFile(forReading:URL(fileURLWithPath:CommandLine.arguments[1]))
engine.disconnectNodeOutput(player)
engine.connect(player,to:engine.mainMixerNode,format:file.processingFormat)
try engine.start()
let done=DispatchSemaphore(value:0)
player.scheduleFile(file,at:nil,completionCallbackType:.dataPlayedBack) { _ in done.signal() }
player.play()
// The file's own length plus a margin, so a 60-minute synthetic meeting plays to its end.
let playSeconds=Double(file.length)/file.processingFormat.sampleRate
print("playing \(Int(playSeconds)) s"); fflush(stdout)
guard done.wait(timeout:.now()+max(60, playSeconds+30)) == .success else { fatalError("Playback timed out") }
if let capturePath {
 Thread.sleep(forTimeInterval:0.3)
 engine.inputNode.removeTap(onBus:0)
 lock.lock();let samples=chunks.flatMap{$0};lock.unlock()
 guard !samples.isEmpty, samples.count <= Int(UInt32.max),
       let fmt=AVAudioFormat(standardFormatWithSampleRate:captureRate,channels:1),
       let buf=AVAudioPCMBuffer(pcmFormat:fmt,frameCapacity:AVAudioFrameCount(samples.count)),
       let channel=buf.floatChannelData?[0] else { fatalError("Empty or invalid capture") }
 buf.frameLength=AVAudioFrameCount(samples.count)
 samples.withUnsafeBufferPointer { ptr in
  if let base=ptr.baseAddress { channel.update(from:base,count:samples.count) }
 }
 let recorded=try AVAudioFile(forWriting:URL(fileURLWithPath:capturePath),settings:fmt.settings)
 try recorded.write(from:buf)
 print("Captured \(samples.count) native frames")
}
engine.stop()
print("Played to BlackHole 2ch: \(file.length) frames at \(file.processingFormat.sampleRate) Hz")
