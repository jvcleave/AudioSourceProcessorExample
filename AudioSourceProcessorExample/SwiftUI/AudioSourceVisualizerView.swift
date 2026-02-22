//
//  AudioSourceVisualizerView.swift
//  AudioSourceProcessorExample
//
//  Created by Chad Codex on 2/22/26.
//


//Quick and dirty example by Chad. Use Metal for yourself 
import AVFoundation
import Combine
import SwiftUI

struct AudioSourceVisualizerView: View {
    let audioSource: AudioSource
    let playbackURL: URL

    @StateObject private var model = PlaybackVisualizerModel()

    var body: some View {
        GroupBox("Onset Visualizer") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button(model.isPlaying ? "Pause" : "Play") {
                        model.togglePlayback()
                    }
                    .disabled(!model.isReady)

                    Button("Restart") {
                        model.restart()
                    }
                    .disabled(!model.isReady)

                    Spacer()

                    Text("\(formatTime(model.currentTime)) / \(formatTime(model.duration))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                onsetPulse

                thresholdControls

                progressTrack
                    .frame(height: 42)

                if let onset = model.lastTriggeredOnset {
                    Text("Last onset: frame \(onset.frameIndex) at \(formatTime(onset.time))  |  dB \(String(format: "%.1f", onset.dbValue))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("Press Play to preview the file and watch onset hits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Eligible onsets: \(model.eligibleOnsetCount) / \(model.onsets.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(audioSource.id.uuidString)|\(playbackURL.path)") {
            model.configure(audioSource: audioSource, playbackURL: playbackURL)
        }
        .onDisappear {
            model.teardown()
        }
    }

    private var onsetPulse: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isOnsetActive ? Color.red : Color.gray.opacity(0.25))
                .frame(width: 18, height: 18)
                .overlay {
                    Circle()
                        .stroke(Color.red.opacity(model.isOnsetActive ? 0.7 : 0), lineWidth: 6)
                        .scaleEffect(model.isOnsetActive ? 1.45 : 1.0)
                        .animation(.easeOut(duration: 0.18), value: model.onsetPulseID)
                }

            Text(model.isOnsetActive ? "ONSET HIT" : "Waiting for onset")
                .font(.headline)
                .foregroundStyle(model.isOnsetActive ? .red : .secondary)
                .animation(.easeOut(duration: 0.12), value: model.onsetPulseID)
        }
    }

    private var progressTrack: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = model.progress
            let playheadX = width * progress
            let visibleOnsets = model.showOnlyEligibleMarkers
                ? model.onsets.filter(model.passesThresholds)
                : model.onsets

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))

                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: max(6, playheadX))

                ForEach(visibleOnsets) { onset in
                    let x = width * onset.relativePosition(duration: max(model.duration, 0.001))
                    let passesThresholds = model.passesThresholds(onset)
                    let isLastTriggered = onset.id == model.lastTriggeredOnset?.id
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 4))
                        path.addLine(to: CGPoint(x: x, y: proxy.size.height - 4))
                    }
                    .stroke(
                        isLastTriggered ? Color.red : (passesThresholds ? Color.secondary.opacity(0.45) : Color.secondary.opacity(0.16)),
                        lineWidth: isLastTriggered ? 2 : 1
                    )
                }

                Path { path in
                    path.move(to: CGPoint(x: playheadX, y: 0))
                    path.addLine(to: CGPoint(x: playheadX, y: proxy.size.height))
                }
                .stroke(Color.accentColor, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / width, 0), 1)
                        model.seek(toProgress: fraction)
                    }
            )
        }
    }

    private var thresholdControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            thresholdSliderRow(
                title: "Min RMS",
                value: $model.minimumRMSNormalized,
                valueText: "\(Int((model.minimumRMSNormalized * 100).rounded()))%"
            )

            thresholdSliderRow(
                title: "Min Loudness",
                value: $model.minimumLoudnessNormalized,
                valueText: "\(Int((model.minimumLoudnessNormalized * 100).rounded()))% (\(String(format: "%.1f", model.minimumLoudnessDBThreshold)) dB)"
            )

            Toggle("Only show eligible markers", isOn: $model.showOnlyEligibleMarkers)
                .font(.caption)
        }
    }

    private func thresholdSliderRow(
        title: String,
        value: Binding<Double>,
        valueText: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary)

            Slider(value: value, in: 0...1)

            Text(valueText)
                .monospacedDigit()
                .frame(width: 120, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

@MainActor
private final class PlaybackVisualizerModel: ObservableObject {
    struct OnsetMarker: Identifiable, Equatable {
        let id = UUID()
        let time: Double
        let frameIndex: Int
        let dbValue: Float
        let rmsValue: Float
        let rmsNormalized: Float
        let loudnessNormalized: Float
        let descriptor: Float

        func relativePosition(duration: Double) -> Double {
            guard duration > 0 else { return 0 }
            return min(max(time / duration, 0), 1)
        }
    }

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isReady = false
    @Published var lastTriggeredOnset: OnsetMarker?
    @Published var onsets: [OnsetMarker] = []
    @Published var onsetPulseID = 0
    @Published var minimumRMSNormalized: Double = 0
    @Published var minimumLoudnessNormalized: Double = 0
    @Published var showOnlyEligibleMarkers = false

    var isOnsetActive: Bool {
        guard let lastHitDate else { return false }
        return Date().timeIntervalSince(lastHitDate) < 0.16
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var eligibleOnsetCount: Int {
        onsets.reduce(0) { $0 + (passesThresholds($1) ? 1 : 0) }
    }

    var minimumLoudnessDBThreshold: Double {
        -60 + (minimumLoudnessNormalized * 60)
    }

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var lastObservedTime: Double = 0
    private var nextOnsetIndex = 0
    private var lastHitDate: Date?
    private var securedURL: URL?

    func configure(audioSource: AudioSource, playbackURL: URL) {
        teardownPlayerOnly()
        releaseSecurityScope()

        onsets = audioSource.frames.compactMap { frame in
            guard let onset = frame.onset else { return nil }
            return OnsetMarker(
                time: Double(onset.time),
                frameIndex: frame.index,
                dbValue: onset.dbValue,
                rmsValue: onset.rms,
                rmsNormalized: frame.rmsNormalized,
                loudnessNormalized: onset.loudnessNormalized,
                descriptor: onset.descriptorNormalized
            )
        }
        .sorted { $0.time < $1.time }

        currentTime = 0
        duration = max(Double(audioSource.durationSeconds), 0)
        isPlaying = false
        isReady = false
        lastTriggeredOnset = nil
        lastHitDate = nil
        onsetPulseID = 0
        lastObservedTime = 0
        nextOnsetIndex = 0

        let _ = playbackURL.startAccessingSecurityScopedResource()
        securedURL = playbackURL

        let item = AVPlayerItem(url: playbackURL)
        let player = AVPlayer(playerItem: item)
        self.player = player

        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.handlePlayerTimeChange(seconds: time.seconds)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.handlePlayerTimeChange(seconds: self.duration)
            }
        }

        Task {
            let assetDuration = try? await item.asset.load(.duration)
            if let assetDuration, assetDuration.isNumeric {
                self.duration = max(assetDuration.seconds, self.duration)
            }
            self.isReady = true
        }
    }

    func togglePlayback() {
        guard let player, isReady else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func restart() {
        guard let player else { return }
        seek(to: 0)
        player.play()
        isPlaying = true
    }

    func seek(toProgress progress: Double) {
        let clamped = min(max(progress, 0), 1)
        seek(to: clamped * max(duration, 0))
    }

    func teardown() {
        teardownPlayerOnly()
        releaseSecurityScope()
        onsets = []
        currentTime = 0
        duration = 0
        isPlaying = false
        isReady = false
        lastTriggeredOnset = nil
        lastHitDate = nil
        onsetPulseID = 0
        nextOnsetIndex = 0
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let target = max(seconds, 0)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        handlePlayerTimeChange(seconds: target)
    }

    private func handlePlayerTimeChange(seconds rawSeconds: Double) {
        let seconds = rawSeconds.isFinite ? max(rawSeconds, 0) : 0
        currentTime = seconds
        isPlaying = (player?.rate ?? 0) != 0

        let jumpedBackward = seconds + 0.02 < lastObservedTime
        let jumpedForward = (seconds - lastObservedTime) > 0.6
        if jumpedBackward || jumpedForward {
            nextOnsetIndex = firstOnsetIndex(after: seconds)
        }

        while nextOnsetIndex < onsets.count, seconds >= onsets[nextOnsetIndex].time {
            let onset = onsets[nextOnsetIndex]
            if passesThresholds(onset) {
                fireOnset(onset)
            }
            nextOnsetIndex += 1
        }

        if !isOnsetActive, lastTriggeredOnset != nil {
            // Force SwiftUI to refresh the pulse state after the active window expires.
            objectWillChange.send()
        }

        lastObservedTime = seconds
    }

    private func fireOnset(_ onset: OnsetMarker) {
        lastTriggeredOnset = onset
        lastHitDate = Date()
        onsetPulseID &+= 1
    }

    func passesThresholds(_ onset: OnsetMarker) -> Bool {
        Double(onset.rmsNormalized) >= minimumRMSNormalized &&
        Double(onset.loudnessNormalized) >= minimumLoudnessNormalized
    }

    private func firstOnsetIndex(after time: Double) -> Int {
        var low = 0
        var high = onsets.count

        while low < high {
            let mid = (low + high) / 2
            if onsets[mid].time <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return low
    }

    private func teardownPlayerOnly() {
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
    }

    private func releaseSecurityScope() {
        if let securedURL {
            securedURL.stopAccessingSecurityScopedResource()
            self.securedURL = nil
        }
    }
}
