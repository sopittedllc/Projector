import AVFoundation
func test() async throws {
    let desc = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter,
                                         componentSubType: kAudioUnitSubType_AUConverter,
                                         componentManufacturer: kAudioUnitManufacturer_Apple,
                                         componentFlags: 0,
                                         componentFlagsMask: 0)
    _ = try await AVAudioUnit.instantiate(with: desc, options: [])
}
