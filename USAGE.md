# Command-line reference

Run `SwiftCaptureWorker --help` for the generated reference for the version you
built. This page explains how options fit together and provides stable examples.

## 1. Choose a source

List available displays, windows, audio inputs, processes, and webcams before
capturing:

```bash
SwiftCaptureWorker --list-sources
SwiftCaptureWorker --list-sources --source-kind video
SwiftCaptureWorker --list-sources --source-kind audio
```

Choose one screen or window source:

| Option | Meaning |
| --- | --- |
| `--screen-index <n>` | 1-based display index; defaults to `1`. |
| `--app-name <name>` | Case-insensitive application-name match. |
| `--app-bundle-id <id>` | Exact application bundle identifier. |
| `--source-id <id>` | ID returned by `--list-sources`: `screen:DISPLAY_ID:0` or `window:WINDOW_ID:0`. |
| `--area x:y:width:height` | Display-local crop rectangle; cannot be used with application capture. |

Use either `--app-name` or `--app-bundle-id`, not both. A source ID takes
precedence over the normal screen and bundle-ID selection.

To capture a webcam, use `--capture-webcam`. Select a camera with
`--webcam-device-id`, and optionally set `--webcam-fps`,
`--webcam-width`, and `--webcam-height`. Width and height must be provided
together.

## 2. Choose audio

Audio is opt-in:

| Option | Meaning |
| --- | --- |
| `--capture-system-audio` | Capture system output through ScreenCaptureKit. |
| `--capture-input-audio` | Capture the default microphone or input device. |
| `--input-device-id <id>` | Select an input device listed by `--list-sources`. |
| `--capture-process-audio` | Capture one process's output on macOS 14.2 or later. |
| `--audio-tap-pid <pid>` | Select the process-audio target by PID. |
| `--audio-tap-app <name>` | Select the process-audio target by application name or partial bundle ID. |

Process-audio capture requires exactly one of `--audio-tap-pid` and
`--audio-tap-app`.

For audio-only capture, add `--no-video` and at least one audio capture option.

## 3. Choose an output

Pick one primary media destination.

### File descriptors

This is the default for application integrations that spawn the worker. Video
uses stdout (`--video-fd 1`) by default. Give each additional active stream a
different file descriptor:

```bash
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio --system-audio-fd 3 \
  --capture-input-audio --input-audio-fd 4
```

Related options are `--video-fd`, `--system-audio-fd`, `--input-audio-fd`,
`--process-audio-fd`, and `--webcam-video-fd`. These outputs are SCAP packets,
not raw codec payloads. Read [PROTOCOL.md](PROTOCOL.md) before consuming them.

### Multiplexed IPC

Use a Unix-domain socket or localhost TCP listener when one consumer should
receive every active stream on a single connection:

```bash
# Start your listener before launching the worker.
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --ipc-socket /tmp/swiftcapture.sock
```

```bash
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --ipc-port 9876
```

The worker is the client: it connects to the socket path or to
`127.0.0.1:<port>`. IPC output cannot be combined with per-stream file
descriptors. Packets from all streams are multiplexed using their SCAP
`stream_id`.

### File, SRT, and RTMP

Use one of these destinations for directly usable media output:

```bash
# Write a local MPEG-TS file.
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --duration-ms 10000 \
  --dump-output capture.ts

# Publish MPEG-TS over SRT.
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --srt-url "srt://relay.example.com:9000?streamid=publish/live"

# Publish FLV over RTMP.
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --rtmp-url "rtmp://live.example.com/app/stream-key"
```

`--dump-output`, `--srt-url`, and `--rtmp-url` are mutually exclusive. SRT
also accepts `--srt-latency-ms` and `--srt-stream-id`. `--premux` is an
experimental local pre-mux mode; use `--dump-output` when you need a named,
portable output file.

## 4. Tune video

| Option | Default | Constraints |
| --- | --- | --- |
| `--fps <n>` | `60` | Screen capture accepts `15`, `30`, or `60`. |
| `--bitrate <bps>` | Encoder default | Must be greater than zero. |
| `--keyframe-interval <frames>` | `fps * 2` | Maximum interval between keyframes. |
| `--output-width`, `--output-height` | Source size | Specify both; each must be at least 128. |
| `--show-cursor` | Off | Includes the mouse pointer. |
| `--duration-ms <n>` | Unlimited | At least 100 milliseconds. |

Example: crop, scale, and write a short test recording:

```bash
SwiftCaptureWorker \
  --screen-index 1 \
  --area 0:0:2560:1440 \
  --output-width 1920 --output-height 1080 \
  --fps 30 \
  --duration-ms 10000 \
  --dump-output capture.ts
```

## Discovery and worker registry

These commands print JSON and exit:

```bash
SwiftCaptureWorker --list-workers
SwiftCaptureWorker --info-pid 12345
```

## Validation rules

- `--ipc-socket` and `--ipc-port` cannot be used together.
- A socket or TCP destination cannot be combined with per-stream file
  descriptors.
- All active file descriptors must be distinct.
- System, input, and process audio require a matching file descriptor unless
  IPC, file, SRT, or RTMP output is selected.
- Webcam and input-audio output follows the same rule, with `--premux` also
  accepted for those two streams.
- `--no-video` requires an audio or webcam capture option.
