//
//  AudioSourcePlaybackRunner.swift
//  AudioSourceProcessorExample
//
//  Created by Chad Codex on 2/22/26.
//

import AVFoundation
import Foundation

/// Minimal non-UI playback helper that plays an analyzed audio file and prints
/// frame/onset data as playback crosses each analysis frame.
@MainActor
final class AudioSourcePlaybackRunner: NSObject, AVAudioPlayerDelegate {
    let audioSource: AudioSource

    /// Print every analysis frame as playback advances.
    var printsFrames = true

    /// Print onset details when a frame contains an onset.
    var printsOnsets = true

    /// Print a start/finish summary.
    var printsSummary = true

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var nextFrameIndex = 0
    private var securedURL: URL?

    init(audioSource: AudioSource) {
        self.audioSource = audioSource
        super.init()
    }

    func start() throws {
        stop()

        guard let url = audioSource.audioFileURL else {
            throw NSError(
                domain: "AudioSourcePlaybackRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AudioSource.audioFileURL is missing."]
            )
        }

        let _ = url.startAccessingSecurityScopedResource()
        securedURL = url

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        self.nextFrameIndex = 0

        if printsSummary {
            print("[PlaybackRunner] Starting: \(url.lastPathComponent)")
            print("[PlaybackRunner] duration=\(String(format: "%.2f", audioSource.durationSeconds))s fps=\(String(format: "%.1f", audioSource.fps)) frames=\(audioSource.frames.count) avgBPM=\(String(format: "%.1f", audioSource.averageBPM))")
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        player.play()
    }

    func stop() {
        timer?.invalidate()
        timer = nil

        player?.stop()
        player = nil

        nextFrameIndex = 0
        releaseSecurityScope()
    }

    private func tick() {
        guard let player else { return }

        let currentTime = Float(player.currentTime)

        while nextFrameIndex < audioSource.frames.count,
              currentTime >= audioSource.frames[nextFrameIndex].time {
            let frame = audioSource.frames[nextFrameIndex]

            if printsFrames {
                printFrame(frame)
            }

            if printsOnsets, let onset = frame.onset {
                printOnset(onset, frameIndex: frame.index)
            }

            nextFrameIndex += 1
        }

        if !player.isPlaying {
            finishPlayback()
        }
    }

    private func printFrame(_ frame: AudioFrame) {
        print(
            "[Frame \(frame.index)] " +
            "t=\(String(format: "%.3f", frame.time))s " +
            "rms=\(String(format: "%.4f", frame.rms)) " +
            "rmsN=\(String(format: "%.3f", frame.rmsNormalized)) " +
            "dB=\(String(format: "%.1f", frame.loudnessDB)) " +
            "loudN=\(String(format: "%.3f", frame.loudnessNormalized))"
        )
    }

    private func printOnset(_ onset: AudioOnset, frameIndex: Int) {
        print(
            "[ONSET] " +
            "frame=\(frameIndex) " +
            "t=\(String(format: "%.3f", onset.time))s " +
            "db=\(String(format: "%.1f", onset.dbValue)) " +
            "rms=\(String(format: "%.4f", onset.rms)) " +
            "descN=\(String(format: "%.3f", onset.descriptorNormalized))"
        )
    }

    private func finishPlayback() {
        if printsSummary {
            print("[PlaybackRunner] Finished playback")
        }
        stop()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if printsSummary {
            print("[PlaybackRunner] audioPlayerDidFinishPlaying successfully=\(flag)")
        }
        finishPlayback()
    }

    private func releaseSecurityScope() {
        if let securedURL {
            securedURL.stopAccessingSecurityScopedResource()
            self.securedURL = nil
        }
    }
}
