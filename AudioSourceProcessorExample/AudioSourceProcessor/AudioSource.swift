//
//  AudioSource.swift
//  AudioSourceProcessorExample
//
//  Created by jason van cleave on 2/22/26.
//

import AVFAudio
import Foundation

/// Processed analysis output for a single audio file (or extracted audio from video).
/// Contains per-frame measurements plus aggregate summary values.
public class AudioSource: Codable, Identifiable
{
    /// Stable identifier for SwiftUI / persistence use.
    public var id: UUID = UUID()
    /// Audio sample rate in Hz for the analyzed file.
    public var sampleRate: Int = 0
    /// Total analyzed duration in seconds.
    public var durationSeconds: Float = 0
    /// Analysis frame rate used to step through the source.
    public var fps: Float
    /// Per-analysis-frame measurements and onset information.
    public var frames: [AudioFrame] = []
    /// Display tempo estimate derived from onset spacing.
    public var averageBPM: Float = 0
    /// Number of audio channels in the analyzed source.
    public var channelCount: AVAudioChannelCount = 1
    /// Average RMS across all frames.
    public var averageRMS: Float = 0
    /// Average loudness (dB) of detected onsets only.
    public var averageOnsetLoudness: Float = 0
    /// Average per-frame loudness in dB across the full source.
    public var averageLoudnessDB: Float = 0
    /// Loudest per-frame loudness in dB observed in the source.
    public var maxLoudnessDB: Float = 0

    /// URL of the audio file actually analyzed (may be extracted from video).
    public var audioFileURL: URL!

    public init(fps: Double)
    {
        self.fps = Float(fps)
    }

}

/// Analysis measurements for a single frame step at the chosen FPS.
public class AudioFrame: Codable
{
    /// Zero-based analysis frame index.
    public var index: Int = 0
    /// Raw frame samples used for analysis.
    public var samples: [Float] = []
    /// Clean/fixed-size samples prepared for playback-related use.
    public var playbackSamples: [Float] = []

    /// Tempo estimate copied onto each frame for convenience.
    public var bpm: Float = 0
    /// Onset collection for this frame (usually empty or one onset).
    public var onsets: [AudioOnset] = []
    /// Primary onset for this frame, if one was detected.
    public var onset: AudioOnset?
    /// Root-mean-square energy for the frame.
    public var rms: Float = 0
    /// RMS normalized relative to the loudest frame RMS in the source.
    public var rmsNormalized: Float = 0
    /// Absolute loudness in dB for this frame.
    public var loudnessDB: Float = 0
    /// Loudness normalized using a fixed -60...0 dB mapping.
    public var loudnessNormalized: Float = 0
    /// Loudness normalized relative to the source's observed loudest frame.
    public var relativeLoudnessNormalized: Float = 0
    /// Frame timestamp in seconds from the start of the source.
    var time: Float = 0.0

    public init() {}
}

/// Metadata captured when a transient/onset is detected in a frame.
public class AudioOnset: Codable
{
    /// Onset timestamp in seconds.
    public var time: Float = 0.0
    /// Loudness of the onset frame in dB.
    public var dbValue: Float = 0
    /// Linear amplitude/energy-like value captured for the onset.
    public var linearValue: Float = 0
    /// Legacy/alternate level-detection field for downstream consumers.
    public var levelDetection: Float = 0
    /// Frame index where the onset was detected.
    public var frameNum: Int = 0
    /// Raw onset descriptor value used for peak picking.
    public var descriptor: Float = 0
    /// Adaptive threshold value at the onset frame.
    public var thresholded_descriptor: Float = 0
    /// Descriptor normalized across the current source.
    public var descriptorNormalized: Float = 0
    /// Loudness normalized using the processor's fixed dB mapping.
    public var loudnessNormalized: Float = 0
    /// RMS value of the onset frame.
    public var rms: Float = 0
    /// Frame index of the next detected onset (0 if none).
    public var nextOnsetFrameNumber: Int = 0
    /// Distance in analysis frames to the next onset (0 if none).
    public var distanceToNextOnset: Int = 0

    public init() {}
}
