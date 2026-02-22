//
//  ContentView.swift
//  AudioSourceProcessorExample
//
//  Created by jason van cleave on 2/22/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isImporterPresented = false
    @State private var isProcessing = false
    @State private var selectedURL: URL?
    @State private var processedAudioURL: URL?
    @State private var audioSource: AudioSource?
    @State private var errorMessage: String?
    @State private var fpsText: String = "30"

    private let processor = DefaultAudioSourceProcessor()
    private let extractor = VideoAudioExtractor()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Source Processor")
                .font(.title2.weight(.semibold))

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text("FPS")
                        .foregroundStyle(.secondary)
                    TextField("30", text: $fpsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                }

                Button("Select Audio or Video") {
                    isImporterPresented = true
                }
                .disabled(isProcessing)

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing…")
                        .foregroundStyle(.secondary)
                }
            }

            if let selectedURL {
                Text("Selected: \(selectedURL.lastPathComponent)")
                    .font(.subheadline)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }

            if let audioSource {
                summaryView(for: audioSource)
                if let playbackURL = selectedURL ?? processedAudioURL ?? audioSource.audioFileURL {
                    AudioSourceVisualizerView(
                        audioSource: audioSource,
                        playbackURL: playbackURL
                    )
                }
            } else if !isProcessing {
                Text("Choose an audio or video file to analyze.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420, alignment: .topLeading)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard let fps = parsedFPS else {
                    errorMessage = "Enter a valid FPS value greater than 0."
                    return
                }
                selectedURL = url
                Task {
                    await processFile(url, fps: fps)
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func summaryView(for source: AudioSource) -> some View {
        let onsetCount = source.frames.reduce(0) { count, frame in
            count + (frame.onset == nil ? 0 : 1)
        }

        GroupBox("Audio Source Summary") {
            VStack(alignment: .leading, spacing: 8) {
                summaryRow("Source file", selectedURL?.lastPathComponent ?? "Unknown")
                summaryRow("Processed audio", processedAudioURL?.lastPathComponent ?? source.audioFileURL?.lastPathComponent ?? "Unknown")
                summaryRow("Duration", String(format: "%.2f s", source.durationSeconds))
                summaryRow("Frames", "\(source.frames.count)")
                summaryRow("Onsets", "\(onsetCount)")
                summaryRow("FPS", String(format: "%.1f", source.fps))
                summaryRow("Sample rate", "\(source.sampleRate) Hz")
                summaryRow("Channels", "\(source.channelCount)")
                summaryRow("Average BPM", String(format: "%.1f", source.averageBPM))
                summaryRow("Average RMS", String(format: "%.4f", source.averageRMS))
                summaryRow("Avg loudness", String(format: "%.2f dB", source.averageLoudnessDB))
                summaryRow("Max loudness", String(format: "%.2f dB", source.maxLoudnessDB))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var parsedFPS: Double? {
        let normalized = fpsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    private func processFile(_ url: URL, fps: Double) async {
        await MainActor.run {
            isProcessing = true
            errorMessage = nil
            audioSource = nil
            processedAudioURL = nil
        }

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let audioURL = try await processableAudioURL(for: url)
            let source = try await processor.processURL(audioURL, fps: fps)

            await MainActor.run {
                processedAudioURL = audioURL
                audioSource = source
                if source == nil {
                    errorMessage = "The file could not be processed."
                }
                isProcessing = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isProcessing = false
            }
        }
    }

    private func processableAudioURL(for url: URL) async throws -> URL {
        if isLikelyVideo(url) {
            guard let extractedAudioURL = try await extractor.extractAudio(url) else {
                throw NSError(
                    domain: "AudioSourceProcessorExample",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No audio track was found in the selected video."]
                )
            }
            return extractedAudioURL
        }

        return url
    }

    private func isLikelyVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }
}

#Preview {
    ContentView()
}
