//
//  VideoAudioExtractor.swift
//  AudioSourceProcessorExample
//
//  Created by jason van cleave on 2/22/26.
//


import AVFoundation

class VideoAudioExtractor
{
    func extractAudio(_ url: URL) async throws -> URL?
    {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ExtractedAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileName = url.deletingPathExtension().lastPathComponent + ".m4a"
        let copyTargetURL = tempDir.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: copyTargetURL.path) {
            try? FileManager.default.removeItem(at: copyTargetURL)
        }

        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty
        else
        {
            print("❌ No audio tracks found in: \(url.lastPathComponent)")
            return nil
        }

        for track in audioTracks
        {
            let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )

            let timeRange = try await track.load(.timeRange)
            try compositionTrack?.insertTimeRange(timeRange, of: track, at: timeRange.start)

            let transform = try await track.load(.preferredTransform)
            compositionTrack?.preferredTransform = transform
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else
        {
            print("❌ Failed to create export session")
            return nil
        }

        exportSession.outputFileType = .m4a
        exportSession.outputURL = copyTargetURL

        Task.detached
        {
            for await state in exportSession.states(updateInterval: 0.1)
            {
                if case let .exporting(progress) = state
                {
                    print("⏳ Exporting... \(Int(progress.fractionCompleted * 100))%")
                }
            }
        }

        try await exportSession.export(to: copyTargetURL, as: .m4a)
        print("✅ Export completed: \(copyTargetURL.lastPathComponent)")
        return copyTargetURL
    }
}

