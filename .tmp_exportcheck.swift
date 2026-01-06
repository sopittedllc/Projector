import AVFoundation
func test(export: AVAssetExportSession, url: URL) async throws {
    try await export.export(to: url, as: .m4a)
}
