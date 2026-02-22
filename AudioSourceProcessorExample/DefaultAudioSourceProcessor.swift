//
//  DefaultAudioSourceProcessor.swift
//  JVCDataMosh
//
//  Created by jason van cleave on 2/21/26.
//

import Foundation
import AVFoundation
import Accelerate

final class DefaultAudioSourceProcessor: BaseAudioSourceProcessor
{
    // MARK: - Tunable Parameters
    
    private let fftSize = 2048
    private let sensitivity: Float = 1.2
    private let refractorySeconds: Float = 0.06
    private let applyHysteresis = false
    private let hysteresisHighThreshold: Float = 0.24
    private let hysteresisLowThreshold: Float = 0.17
    private let applyMinHitGapFrames = true
    private let minHitGapFrames = 2
    
    /// Half-width of the centered threshold window (frames on each side).
    private let thresholdHalfWindow: Int = 8
    
    // MARK: - Main Entry
    
    override func processURL(
        _ audioURL: URL,
        fps: Double
    ) async throws -> AudioSource?
    {
        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = Float(file.processingFormat.sampleRate)
        let channelCount = file.processingFormat.channelCount
        
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else { return nil }
        
        try file.read(into: buffer)
        
        guard let channelData = buffer.floatChannelData else { return nil }
        
        // Convert to mono
        let totalSamples = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: totalSamples)
        
        if channelCount == 1 {
            mono = Array(UnsafeBufferPointer(start: channelData[0], count: totalSamples))
        } else {
            for c in 0..<Int(channelCount) {
                vDSP_vadd(mono, 1,
                          channelData[c], 1,
                          &mono, 1,
                          vDSP_Length(totalSamples))
            }
            var divisor = Float(channelCount)
            vDSP_vsdiv(mono, 1, &divisor, &mono, 1, vDSP_Length(totalSamples))
        }
        
        if fps <= 0
        {
            print("ExperimentalAudioSourceProcessorAltOnset: invalid fps \(fps)")
            return nil
        }

        // Frame setup aligned to fps
        let hopSize = max(1, Int(sampleRate / Float(fps)))
        let halfFFT = fftSize / 2
        
        let window = vDSP.window(ofType: Float.self,
                                 usingSequence: .hanningDenormalized,
                                 count: fftSize,
                                 isHalfWindow: false)
        
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        
        defer { vDSP_destroy_fftsetup(fftSetup) }
        
        // MARK: - Pre-allocate Buffers
        var windowed    = [Float](repeating: 0, count: fftSize)
        var real        = [Float](repeating: 0, count: halfFFT)
        var imag        = [Float](repeating: 0, count: halfFFT)
        var magnitudes  = [Float](repeating: 0, count: halfFFT)
        var logMag      = [Float](repeating: 0, count: halfFFT)
        var diff        = [Float](repeating: 0, count: halfFFT)  // = logMag - prevLogMag (positive = rising energy)
        var prevLogMag  = [Float](repeating: 0, count: halfFFT)
        
        // High-frequency weighting ramp [0 … 1] across bins
        var hfRamp      = [Float](repeating: 0, count: halfFFT)
        var rampStart: Float = 0
        var rampStep: Float  = 1.0 / Float(halfFFT)
        vDSP_vramp(&rampStart, &rampStep, &hfRamp, 1, vDSP_Length(halfFFT))
        
        var frames:      [AudioFrame] = []
        var descriptors: [Float]      = []
        
        var frameIndex = 0
        var position   = 0
        
        // MARK: - Pass 1: Extract Features
        while position < totalSamples {
            
            let endPosition    = min(position + fftSize, totalSamples)
            var frameSamples   = Array(mono[position..<endPosition])
            
            let hopEndPosition    = min(position + hopSize, totalSamples)
            let exactFrameSamples = Array(mono[position..<hopEndPosition])
            
            if frameSamples.count < fftSize {
                frameSamples.append(contentsOf: [Float](repeating: 0, count: fftSize - frameSamples.count))
            }
            
            vDSP.multiply(frameSamples, window, result: &windowed)
            
            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    windowed.withUnsafeMutableBufferPointer { winPtr in
                        
                        var splitComplex = DSPSplitComplex(
                            realp: realPtr.baseAddress!,
                            imagp: imagPtr.baseAddress!
                        )
                        
                        winPtr.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self,
                            capacity: halfFFT
                        ) { complexPtr in
                            vDSP_ctoz(complexPtr, 2,
                                      &splitComplex, 1,
                                      vDSP_Length(halfFFT))
                        }
                        
                        vDSP_fft_zrip(fftSetup,
                                      &splitComplex,
                                      1,
                                      log2n,
                                      FFTDirection(FFT_FORWARD))
                        
                        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfFFT))
                    }
                }
            }
            
            // log(mag + 1) — avoids log(0), compresses dynamic range
            var one: Float = 1
            vDSP_vsadd(magnitudes, 1, &one, &magnitudes, 1, vDSP_Length(halfFFT))
            var logElementCount = Int32(halfFFT)
            vvlogf(&logMag, magnitudes, &logElementCount)
            
            // diff = logMag - prevLogMag  (note: vDSP_vsub computes C = B - A)
            vDSP_vsub(prevLogMag, 1,
                      logMag, 1,
                      &diff, 1,
                      vDSP_Length(halfFFT))
            
            // Half-wave rectify: keep only rising spectral energy
            var zero: Float = 0
            vDSP_vthr(diff, 1, &zero, &diff, 1, vDSP_Length(halfFFT))
            
            // High-frequency weighting — emphasises transient content
            vDSP_vmul(diff, 1, hfRamp, 1, &diff, 1, vDSP_Length(halfFFT))
            
            var descriptor: Float = 0
            vDSP_sve(diff, 1, &descriptor, vDSP_Length(halfFFT))
            
            descriptors.append(descriptor)
            prevLogMag = logMag
            
            var rms: Float = 0
            vDSP_rmsqv(exactFrameSamples, 1, &rms, vDSP_Length(exactFrameSamples.count))
            let db = rms > 1e-7 ? 20.0 * log10f(rms) : -140.0
            
            let frame = AudioFrame()
            frame.index                    = frameIndex
            frame.samples                  = exactFrameSamples
            frame.playbackSamples          = exactFrameSamples
            frame.bpm                      = 0
            frame.rms                      = rms
            frame.rmsNormalized            = 0
            frame.loudnessDB               = db
            frame.loudnessNormalized       = 0
            frame.relativeLoudnessNormalized = 0
            frame.time                     = Float(position) / sampleRate
            
            frames.append(frame)
            frameIndex += 1
            position   += hopSize
        }
        
        // MARK: - Pass 2: Peak Picking (centered adaptive threshold)
        //
        // Use a centered local window (±thresholdHalfWindow) to compute the
        // adaptive threshold for each descriptor sample. This keeps the
        // threshold aligned with local energy changes instead of only looking
        // backward.
        //
        // If the descriptor is flat (silence, steady tone, etc.), return a
        // valid AudioSource with frames but no onsets instead of failing.
        
        let descriptorRange: Float
        if let minD = descriptors.min(), let maxD = descriptors.max(), maxD > minD {
            descriptorRange = maxD - minD
        } else {
            // Flat signal — build a valid source with no onsets and return it.
            return buildAudioSource(
                url: audioURL,
                sampleRate: sampleRate,
                channelCount: channelCount,
                totalSamples: totalSamples,
                fps: fps,
                frames: frames,
                averageBPM: 0
            )
        }
        
        let minD = descriptors.min()!
        var lastOnsetFrame  = -1000
        let refractoryFrames = Int(refractorySeconds * Float(fps))
        var onsetFrameIndices: [Int] = []   // collected for BPM + linking pass
        
        for i in 1..<descriptors.count - 1 {
            
            let norm = (descriptors[i] - minD) / descriptorRange
            
            // Centered window (excluding the center sample for unbiased local mean)
            let windowStart = max(0, i - thresholdHalfWindow)
            let windowEnd   = min(descriptors.count, i + thresholdHalfWindow + 1)
            let windowSlice = descriptors[windowStart..<windowEnd]
            let windowSum = windowSlice.reduce(0, +)
            let windowCount = max(windowSlice.count - 1, 1)
            let windowMean  = (windowSum - descriptors[i]) / Float(windowCount)
            let threshold   = windowMean * sensitivity
            
            let isPeak =
            descriptors[i] > threshold &&
            descriptors[i] > descriptors[i - 1] &&
            descriptors[i] > descriptors[i + 1] &&
            (i - lastOnsetFrame) > refractoryFrames
            
            if isPeak {
                lastOnsetFrame = i
                onsetFrameIndices.append(i)
                
                let onset = AudioOnset()
                onset.time                  = frames[i].time
                onset.dbValue               = frames[i].loudnessDB
                onset.linearValue           = frames[i].rms
                onset.levelDetection        = descriptors[i]
                onset.frameNum              = i
                onset.descriptor            = descriptors[i]
                onset.thresholded_descriptor = threshold
                onset.descriptorNormalized  = norm
                onset.loudnessNormalized    = ofMap(
                    value:     frames[i].loudnessDB,
                    inputMin:  -60,
                    inputMax:  0,
                    outputMin: Float(0),
                    outputMax: Float(1),
                    clamp:     true
                )
                onset.rms                   = frames[i].rms
                onset.nextOnsetFrameNumber  = 0   // linked below
                onset.distanceToNextOnset   = 0   // linked below
                
                frames[i].onset  = onset
                frames[i].onsets.append(onset)
            }
        }
        
        // MARK: - Pass 3: Optional Hysteresis Filter
        //
        // Uses a Schmitt-trigger style filter to prevent chattery onset trains.
        // New onset runs start above high threshold and continue until below low threshold.
        if applyHysteresis
        {
            let hysteresisHigh = max(
                hysteresisHighThreshold,
                hysteresisLowThreshold + 0.01
            )
            let hysteresisLow = min(
                hysteresisLowThreshold,
                hysteresisHigh - 0.01
            )

            var filteredOnsetFrameIndices: [Int] = []
            filteredOnsetFrameIndices.reserveCapacity(onsetFrameIndices.count)

            var gateOpen = false
            for onsetFrameIndex in onsetFrameIndices
            {
                if let onset = frames[onsetFrameIndex].onset
                {
                    let descriptorNormalized = onset.descriptorNormalized
                    if gateOpen
                    {
                        if descriptorNormalized < hysteresisLow
                        {
                            gateOpen = false
                            frames[onsetFrameIndex].onset = nil
                            frames[onsetFrameIndex].onsets.removeAll()
                            continue
                        }

                        filteredOnsetFrameIndices.append(onsetFrameIndex)
                    }
                    else
                    {
                        if descriptorNormalized >= hysteresisHigh
                        {
                            gateOpen = true
                            filteredOnsetFrameIndices.append(onsetFrameIndex)
                        }
                        else
                        {
                            frames[onsetFrameIndex].onset = nil
                            frames[onsetFrameIndex].onsets.removeAll()
                        }
                    }
                }
            }

            onsetFrameIndices = filteredOnsetFrameIndices
        }

        // MARK: - Pass 4: Optional Min Gap Filter
        //
        // Enforces a minimum frame gap between kept onsets.
        // If two candidates are too close, keep the stronger one.
        if applyMinHitGapFrames
        {
            let requiredFrameGap = max(minHitGapFrames, 0)
            if requiredFrameGap > 0
            {
                var filteredOnsetFrameIndices: [Int] = []
                filteredOnsetFrameIndices.reserveCapacity(onsetFrameIndices.count)

                for onsetFrameIndex in onsetFrameIndices
                {
                    if let lastKeptFrameIndex = filteredOnsetFrameIndices.last
                    {
                        let frameDistance = onsetFrameIndex - lastKeptFrameIndex
                        if frameDistance < requiredFrameGap
                        {
                            let lastStrength = frames[lastKeptFrameIndex].onset?.descriptorNormalized ?? 0
                            let currentStrength = frames[onsetFrameIndex].onset?.descriptorNormalized ?? 0

                            if currentStrength > lastStrength
                            {
                                frames[lastKeptFrameIndex].onset = nil
                                frames[lastKeptFrameIndex].onsets.removeAll()
                                filteredOnsetFrameIndices[filteredOnsetFrameIndices.count - 1] = onsetFrameIndex
                            }
                            else
                            {
                                frames[onsetFrameIndex].onset = nil
                                frames[onsetFrameIndex].onsets.removeAll()
                            }
                            continue
                        }
                    }
                    filteredOnsetFrameIndices.append(onsetFrameIndex)
                }

                onsetFrameIndices = filteredOnsetFrameIndices
            }
        }

        // MARK: - Pass 5: BPM from inter-onset intervals
        //
        // Estimate tempo from the median inter-onset interval (IOI) and
        // normalize the result into a practical display range.
        let averageBPM = bpm(fromOnsetFrameIndices: onsetFrameIndices, fps: Float(fps))
        
        // Stamp BPM onto every frame
        for frame in frames { frame.bpm = averageBPM }
        
        // MARK: - Pass 6: Link next-onset references
        //
        // Populate each onset with the next detected onset frame and the frame
        // distance to that next onset for downstream timing-based logic.
        for (pos, frameIdx) in onsetFrameIndices.enumerated() {
            guard pos + 1 < onsetFrameIndices.count else { break }
            let nextFrameIdx = onsetFrameIndices[pos + 1]
            let distance     = nextFrameIdx - frameIdx
            
            if let onset = frames[frameIdx].onset {
                onset.nextOnsetFrameNumber = nextFrameIdx
                onset.distanceToNextOnset  = distance
            }
            for onset in frames[frameIdx].onsets {
                onset.nextOnsetFrameNumber = nextFrameIdx
                onset.distanceToNextOnset  = distance
            }
        }
        
        // MARK: - Pass 7: Normalise loudness across all frames
        return buildAudioSource(
            url:          audioURL,
            sampleRate:   sampleRate,
            channelCount: channelCount,
            totalSamples: totalSamples,
            fps:          fps,
            frames:       frames,
            averageBPM:   averageBPM
        )
    }
    
    // MARK: - BPM Helper
    
    /// Median inter-onset interval → BPM.
    ///
    /// Consecutive onsets often represent subdivisions (e.g. 8ths/16ths), so the
    /// raw onset-rate estimate can be 2x or 4x the musical tempo. We octave-normalize
    /// the estimate into a practical range for display.
    private func bpm(fromOnsetFrameIndices indices: [Int], fps: Float) -> Float {
        guard indices.count > 1 else { return 0 }
        guard fps > 0 else { return 0 }

        let minPlausibleBPM: Float = 60
        let maxPlausibleBPM: Float = 180
        let minIOISeconds: Float = 60.0 / 300.0  // ignore implausibly fast transient chatter

        var ioi: [Float] = []
        ioi.reserveCapacity(max(indices.count - 1, 0))

        for (a, b) in zip(indices, indices.dropFirst()) {
            let interval = Float(b - a) / fps
            if interval.isFinite, interval >= minIOISeconds {
                ioi.append(interval)
            }
        }

        guard !ioi.isEmpty else { return 0 }

        ioi.sort()
        let median = ioi[ioi.count / 2]
        guard median > 0 else { return 0 }

        var bpm = 60.0 / median
        while bpm > maxPlausibleBPM { bpm *= 0.5 }
        while bpm < minPlausibleBPM { bpm *= 2.0 }

        return bpm.isFinite ? bpm : 0
    }
    
    // MARK: - AudioSource Assembly
    
    /// Shared assembly so both the normal and flat-signal paths produce a consistent object.
    private func buildAudioSource(
        url:          URL,
        sampleRate:   Float,
        channelCount: AVAudioChannelCount,
        totalSamples: Int,
        fps:          Double,
        frames:       [AudioFrame],
        averageBPM:   Float
    ) -> AudioSource {
        
        var maximumRMS:       Float = 0
        var maximumLoudnessDB: Float = -140.0
        var rmsSum:            Float = 0
        var loudnessSum:       Float = 0
        var onsetLoudnessSum:  Float = 0
        var onsetCount               = 0
        
        for frame in frames {
            if frame.rms       > maximumRMS       { maximumRMS       = frame.rms       }
            if frame.loudnessDB > maximumLoudnessDB { maximumLoudnessDB = frame.loudnessDB }
            rmsSum      += frame.rms
            loudnessSum += frame.loudnessDB
            if let onset = frame.onset {
                onsetLoudnessSum += onset.dbValue
                onsetCount       += 1
            }
        }
        
        for frame in frames {
            frame.rmsNormalized = maximumRMS > 0 ? frame.rms / maximumRMS : 0
            
            frame.loudnessNormalized = ofMap(
                value:     frame.loudnessDB,
                inputMin:  -60,
                inputMax:  0,
                outputMin: Float(0),
                outputMax: Float(1),
                clamp:     true
            )
            
            let volRange = maximumLoudnessDB - (-140.0)
            let currentVal = frame.loudnessDB - (-140.0)
            frame.relativeLoudnessNormalized = volRange > 0 ? currentVal / volRange : 0
        }
        
        let audioSource              = AudioSource(fps: fps)
        audioSource.id               = UUID()
        audioSource.sampleRate       = Int(sampleRate)
        audioSource.durationSeconds  = Float(totalSamples) / sampleRate
        audioSource.frames           = frames
        audioSource.averageBPM       = averageBPM
        audioSource.channelCount     = channelCount
        audioSource.audioFileURL     = url
        
        if frames.isEmpty {
            audioSource.averageRMS          = 0
            audioSource.averageLoudnessDB   = -140.0
            audioSource.maxLoudnessDB       = -140.0
            audioSource.averageOnsetLoudness = 0
        } else {
            audioSource.averageRMS          = rmsSum / Float(frames.count)
            audioSource.averageLoudnessDB   = loudnessSum / Float(frames.count)
            audioSource.maxLoudnessDB       = maximumLoudnessDB
            audioSource.averageOnsetLoudness = onsetCount > 0
            ? onsetLoudnessSum / Float(onsetCount)
            : 0
        }
        
        return audioSource
    }
}
func ofMap<T: BinaryFloatingPoint>(
    value: T,
    inputMin: T,
    inputMax: T,
    outputMin: T,
    outputMax: T,
    clamp: Bool = false
) -> T
{
    let epsilon = T.ulpOfOne
    
    guard abs(inputMin - inputMax) > epsilon
    else
    {
        return outputMin
    }
    
    var outVal = ((value - inputMin) / (inputMax - inputMin)) * (outputMax - outputMin) + outputMin
    
    if clamp
    {
        if outputMax < outputMin
        {
            outVal = min(max(outVal, outputMax), outputMin)
        }
        else
        {
            outVal = max(min(outVal, outputMax), outputMin)
        }
    }
    
    return outVal
}
