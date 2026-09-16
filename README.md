# SwiftCaptureWorker

SwiftCaptureWorker is a headless macOS capture process for applications that need
screen, window, webcam, system-audio, microphone, or per-process-audio capture.
It encodes video as H.264, emits audio as LPCM or AAC, and can deliver the result
to an IPC consumer, file descriptors, an MPEG-TS file, SRT, or RTMP.

It is intended to be embedded or launched by another application, not used as a
general-purpose screen recorder.

> [!NOTE]
> This project is a specialized fork of [GlennWong/SwiftCapture](https://github.com/GlennWong/SwiftCapture), refactored from an interactive CLI file recorder into a headless, low-latency streaming and IPC capture worker. If you are looking for a standalone CLI tool dedicated to recording directly to video files (`.mov`/`.mp4`) rather than real-time IPC/network streaming, please check out [GlennWong/SwiftCapture](https://github.com/GlennWong/SwiftCapture) instead.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6) to build from source
- Screen Recording permission for display or window capture
- Microphone permission for `--capture-input-audio`
- macOS 14.2 or later for `--capture-process-audio`

Grant permissions to the application that launches the worker. When testing from
Terminal, grant them to Terminal (or the terminal host application).

## Build

Build a release binary using the Swift Package Manager:

```bash
swift build -c release
```

The compiled binary will be located at:

```text
.build/release/SwiftCaptureWorker
```

For development and debugging:

```bash
swift build
# Binary output: .build/debug/SwiftCaptureWorker
```

### Integration & Embedding

When embedding `SwiftCaptureWorker` inside a parent host application (e.g. Electron or native macOS bundle), copy the binary to your app's resources and sign it (ad-hoc or with your Developer ID) with the hardened runtime and camera/microphone entitlements if required:

```bash
codesign --force --options runtime --entitlements path/to/entitlements.plist --sign - .build/release/SwiftCaptureWorker
```

## Quick start

First, inspect the available capture sources:

```bash
.build/release/SwiftCaptureWorker --list-sources
```

Record the primary display and system audio to an MPEG-TS file for five seconds:

```bash
.build/release/SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --fps 30 \
  --duration-ms 5000 \
  --dump-output capture.ts
```

Broadcast a display and system audio over SRT:

```bash
.build/release/SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --srt-url "srt://relay.example.com:9000?streamid=publish/live"
```

For an application integration, start a Unix-domain or localhost TCP listener
first, then launch the worker with `--ipc-socket` or `--ipc-port`. The worker
connects to that listener and writes multiplexed SCAP packets. See
[USAGE.md](USAGE.md) and [PROTOCOL.md](PROTOCOL.md).

## Outputs at a glance

| Output | Use case | Notes |
| --- | --- | --- |
| File descriptors | Parent-process integration | Each active stream is a separate SCAP-framed byte stream. |
| Unix socket or TCP | Multiplexed IPC | The worker connects to an existing listener and sends all streams over one SCAP connection. |
| `--dump-output` | Local inspection or testing | Writes an MPEG-TS file. |
| `--srt-url` | SRT publishing | Muxes media as MPEG-TS. |
| `--rtmp-url` | RTMP publishing | Muxes media as FLV. |

File-descriptor and IPC output use the SCAP protocol; they are not raw H.264 or
AAC streams. Use the protocol document to implement a consumer.

## Capture capabilities

- Displays and application windows through ScreenCaptureKit
- System audio through ScreenCaptureKit
- Input devices through CoreAudio
- Per-process audio taps on macOS 14.2 and later
- Webcams through AVFoundation
- Hardware H.264 encoding through VideoToolbox

`--capture-webcam` captures a webcam stream and can be combined with supported
## Custom Encoders & Architecture (Fragile — Handle With Care)

> [!WARNING]
> The custom hardware encoder pipelines in `H264Encoder.swift` and `AACEncoder.swift` contain low-level VideoToolbox, AudioToolbox, and bitstream manipulation routines that are tightly coupled to hardware constraints and real-time streaming requirements. They are **fragile** and should generally be **left alone** unless fixing a verified hardware-specific bug.

Key invariants and architectural details include:

1. **In-Place SPS/VUI Bitstream Rewriting (`H264Encoder.swift`)**:
   - Standard VideoToolbox output omits required VUI (Video Usability Information) timing and colorimetry parameters.
   - The encoder parses the raw Exponential-Golomb encoded Sequence Parameter Set (SPS) RBSP, strips emulation prevention bytes (`0x00 0x00 0x03`), and directly injects BT.709 color primaries, full/video color range flags, and fixed frame-rate timing before re-inserting emulation prevention bytes.
   - *Risk:* Subtle errors in bit-level RBSP manipulation will corrupt NAL units, crash downstream hardware decoders, or produce washed-out/green video artifacts.

2. **VideoToolbox Lifecycle & Deadlock Constraints**:
   - The encoder uses unmanaged `refcon` pointers (`Unmanaged.passRetained(self)`) with strict manual retain/release semantics.
   - Periodic buffer draining via `flush()` is mandatory: without it, VideoToolbox accumulates intermediate frame metadata in heap memory at ~5–6 MB per minute at 60 fps.
   - `flush()` invokes `VTCompressionSessionCompleteFrames` *outside* the instance lock to drain buffers. Calling `CompleteFrames` while holding the lock causes an immediate deadlock with the asynchronous compression callback.

3. **90 kHz PTS Quantization & Fractional Cadence Self-Calibration**:
   - Video and audio timestamps are quantized onto the standard 90 kHz MPEG-TS/RTMP timescale.
   - Physical displays and webcams often produce fractional frame intervals (e.g. 59.94 Hz or Apple ProMotion variable rates). Using fixed `1/fps` spacing causes severe A/V sync drift over time.
   - `H264Encoder` observes input timestamp deltas over the first 30 frames to calculate the median physical frame duration and locks cadence smoothly.
   - `AACEncoder` uses an exact rational tick accumulator (`1024 * 90_000 / sampleRate`) carrying fractional remainders forward to achieve mathematically zero A/V drift over long sessions.

4. **AVCC to Annex-B Conversion**:
   - VideoToolbox emits length-prefixed AVCC samples in `CMBlockBuffer` memory.
   - The encoder converts AVCC into Annex-B 4-byte start codes (`00 00 00 01`) and ensures valid SPS/PPS parameter sets precede every IDR keyframe.

5. **Audio Priming Delay Compensation (`AACEncoder.swift`)**:
   - Apple's `AudioConverter` introduces hardware priming delays. `AACEncoder` queries `kAudioConverterPrimeInfo` and subtracts priming ticks so audio frames align precisely with video start times.

## Documentation

- [CLI reference and examples](USAGE.md)
- [SCAP wire protocol](PROTOCOL.md)

Run `SwiftCaptureWorker --help` for the command's generated option reference.

## Development

```bash
swift test
```

## Upstream & Acknowledgements

This project originated as a fork of [GlennWong/SwiftCapture](https://github.com/GlennWong/SwiftCapture) by Glenn Wong. For users seeking a dedicated CLI tool to record screen and audio straight to video files on disk instead of real-time streaming pipelines, please visit the upstream repository.

