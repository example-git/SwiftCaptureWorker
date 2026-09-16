# SwiftCaptureWorker

SwiftCaptureWorker is a headless macOS capture process for applications that need
screen, window, webcam, system-audio, microphone, or per-process-audio capture.
It encodes video as H.264, emits audio as LPCM or AAC, and can deliver the result
to an IPC consumer, file descriptors, an MPEG-TS file, SRT, or RTMP.

It is intended to be embedded or launched by another application, not used as a
general-purpose screen recorder.

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
audio sources.

## Documentation

- [CLI reference and examples](USAGE.md)
- [SCAP wire protocol](PROTOCOL.md)

Run `SwiftCaptureWorker --help` for the command's generated option reference.

## Development

```bash
swift test
```
