import AVFoundation
import AudioToolbox
let node = AVAudioMixerNode()
let au = node.auAudioUnit
print("auAudioUnit type: \(type(of: au))")
print("responds channelMap:", au.responds(to: Selector(("channelMap"))))
print("responds setChannelMap:", au.responds(to: Selector(("setChannelMap:"))))
