# AudioSourceProcessorExample

Example macOS app showing how to use `DefaultAudioSourceProcessor` to analyze an audio source (audio file or video file with an audio track), generate an `AudioSource`, and visualize onset hits during playback.

## What This Repo Demonstrates

- Selecting an audio or video file from SwiftUI (`ContentView`)
- Extracting audio from video (`VideoAudioExtractor`) when needed
- Running analysis with `DefaultAudioSourceProcessor`
- Producing an `AudioSource` summary (duration, BPM, loudness, RMS, onsets, etc.)
- Visualizing onset hits during playback with threshold filtering (RMS and loudness)

## Main Types

- `DefaultAudioSourceProcessor`
  - Concrete processor implementation that analyzes audio and detects onsets.
- `BaseAudioSourceProcessor`
  - Base class for custom processors.
- `AudioSource`
  - Output model containing frame-by-frame analysis data and aggregate metrics.
- `AudioFrame`
  - Per-frame analysis values (RMS, loudness, onset metadata).
- `AudioOnset`
  - Onset/transient metadata for detected hits.

## Running the Example

- Open `AudioSourceProcessorExample.xcodeproj` in Xcode.
- Build and run the macOS app.
- Enter an `FPS` value (analysis frame rate).
- Click `Select Audio or Video`.
- Pick a file.
- The app will:
  - extract audio if the file is a video
  - run `DefaultAudioSourceProcessor`
  - show a summary of the generated `AudioSource`
  - show a playback visualizer with onset hit feedback

## Using `DefaultAudioSourceProcessor`

The app currently creates and uses `DefaultAudioSourceProcessor` in `ContentView`:

```swift
private let processor = DefaultAudioSourceProcessor()
```

And then calls:

```swift
let source = try await processor.processURL(audioURL, fps: fps)
```

`processURL(_:fps:)` returns an optional `AudioSource` containing:

- `frames` with per-frame measurements
- onset data (`AudioOnset`) attached to frames where onsets are found
- summary metrics (`averageBPM`, `averageRMS`, `averageLoudnessDB`, etc.)

## Implementing Your Own `BaseAudioSourceProcessor`

Create a subclass of `BaseAudioSourceProcessor` and override `processURL(_:fps:)`.

### Minimal shape

```swift
import AVFoundation

final class MyAudioSourceProcessor: BaseAudioSourceProcessor {
    override func processURL(_ audioURL: URL, fps: Double) async throws -> AudioSource? {
        guard fps > 0 else { return nil }

        let source = AudioSource(fps: fps)
        source.audioFileURL = audioURL

        // Build frames and onsets here...
        // source.frames = [...]
        // source.averageBPM = ...
        // source.averageRMS = ...

        return source
    }
}
```

## What Your Custom Processor Needs To Do

- Read/decode the audio file into sample data (for example with `AVAudioFile`)
- Step through the audio at your chosen analysis rate (`fps`)
- Create an `AudioFrame` for each analysis frame
- Compute the values you care about (RMS, loudness, spectral features, etc.)
- Detect onsets/transients and attach an `AudioOnset` to matching frames
- Fill summary values on `AudioSource` (duration, averages, BPM estimate if desired)

## Recommended Implementation Pattern

- Use `BaseAudioSourceProcessor` as the shared base for processor types
- Keep `processURL(_:fps:)` focused on:
  - audio decode
  - feature extraction
  - onset detection
  - `AudioSource` assembly
- Reuse `VideoAudioExtractor` if your input may be video files
- Keep UI code (`ContentView`, visualizer) independent from your detection logic so you can swap processors easily

## Swapping In Your Custom Processor

In `ContentView`, replace:

```swift
private let processor = DefaultAudioSourceProcessor()
```

with:

```swift
private let processor = MyAudioSourceProcessor()
```

As long as your subclass returns a valid `AudioSource`, the existing summary view and visualizer should continue to work.

## Optional: Override `combineAudioFiles`

`BaseAudioSourceProcessor` also provides `combineAudioFiles(urls:fps:)`, which can be overridden if you want custom behavior for:

- concatenating multiple clips
- custom export formats
- pre-processing before analysis

If you do not need custom behavior, you can inherit the default implementation.
