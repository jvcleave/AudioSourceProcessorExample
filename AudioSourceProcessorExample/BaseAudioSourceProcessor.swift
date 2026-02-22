//
//  BaseAudioSourceProcessor.swift
//  AudioSourceProcessorExample
//
//  Created by jason van cleave on 2/22/26.
//
 import AVFoundation

class BaseAudioSourceProcessor: AudioSourceProcessing
{
    init() {}

    func processURL(
        _ audioURL: URL,
        fps: Double
    ) async throws -> AudioSource?
    {
        fatalError("Subclasses must override processURL(_:fps:)")
    }

    func combineAudioFiles(
        urls: [URL],
        fps: Double
    ) async throws -> URL?
    {
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else
        {
            throw NSError(domain: "AudioSourceProcessor", code: 100, userInfo: [NSLocalizedDescriptionKey: "Unable to create audio track"])
        }

        var currentTime = CMTime.zero

        for url in urls
        {
            let audioURL: URL
            let ext = url.pathExtension.lowercased()
            if ext == "mov" || ext == "mp4"
            {
                let videoAudioExtractor = VideoAudioExtractor()
                if let extracted = try await videoAudioExtractor.extractAudio(url)
                {
                    audioURL = extracted
                }
                else
                {
                    continue
                }
            }
            else
            {
                audioURL = url
            }

            let asset = AVURLAsset(url: audioURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { continue }
            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            try compositionTrack.insertTimeRange(timeRange, of: track, at: currentTime)
            currentTime = CMTimeAdd(currentTime, duration)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else
        {
            throw NSError(domain: "AudioSourceProcessor", code: 101, userInfo: [NSLocalizedDescriptionKey: "Unable to create AVAssetExportSession"])
        }

        var fileName = ""
        for url in urls
        {
            fileName += url.deletingPathExtension().lastPathComponent
        }
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CombinedAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let outputURL = tempDir.appendingPathComponent(fileName + ".m4a")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        try await exportSession.export(to: outputURL, as: .m4a)

        return outputURL
    }
}
