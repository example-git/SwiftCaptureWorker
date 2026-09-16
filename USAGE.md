# Command-Line & Integration Reference

`SwiftCaptureWorker` is a headless macOS capture worker process designed to be embedded in host applications (e.g. Electron, Node.js, Python, or native macOS applications) or used for low-latency network streaming.

Run `SwiftCaptureWorker --help` for the auto-generated flag listing.

> [!NOTE]
> For a standalone CLI tool dedicated to recording directly to local video files (`.mov`/`.mp4`), refer to upstream [GlennWong/SwiftCapture](https://github.com/GlennWong/SwiftCapture).

---

## 1. Source Discovery & Registry Queries

`SwiftCaptureWorker` provides built-in discovery options that output JSON and immediately exit.

### Listing Sources
```bash
# List all video, audio, and webcam sources
SwiftCaptureWorker --list-sources

# Filter by category
SwiftCaptureWorker --list-sources --source-kind video
SwiftCaptureWorker --list-sources --source-kind audio
```

The returned JSON structure:
```json
{
  "video": {
    "displays": [
      {
        "index": 1,
        "displayID": 1,
        "electronSourceId": "screen:1:0",
        "name": "Built-in Retina Display",
        "isPrimary": true,
        "frame": { "x": 0, "y": 0, "width": 1728, "height": 1117 },
        "scaleFactor": 2.0
      }
    ],
    "applications": [
      {
        "name": "Safari",
        "bundleIdentifier": "com.apple.Safari",
        "processID": 1234,
        "windows": [
          {
            "windowID": 5678,
            "electronSourceId": "window:5678:0",
            "title": "GitHub — SwiftCaptureWorker",
            "frame": { "x": 100, "y": 100, "width": 1200, "height": 800 },
            "isOnScreen": true
          }
        ]
      }
    ]
  },
  "audio": {
    "systemAudioSupported": true,
    "inputDevices": [
      {
        "name": "MacBook Pro Microphone",
        "uniqueID": "BuiltInMicrophoneDevice",
        "modelID": "AppleHDAEngineInput:1",
        "connected": true
      }
    ],
    "processes": [
      {
        "name": "Music",
        "bundleIdentifier": "com.apple.Music",
        "processID": 2345,
        "processIDs": [2345],
        "bundleIdentifiers": ["com.apple.Music"],
        "processObjectCount": 1
      }
    ]
  },
  "webcams": [
    {
      "name": "FaceTime HD Camera",
      "uniqueID": "0x1410000005ac8514",
      "modelID": "Apple Camera",
      "connected": true,
      "formats": [
        { "width": 1920, "height": 1080, "minFPS": 1.0, "maxFPS": 60.0 }
      ]
    }
  ]
}
```

### Worker Process Registry Queries
Active workers automatically register themselves in `/tmp/swiftcapture-registry-<pid>.json`:
```bash
# List all active workers on the machine
SwiftCaptureWorker --list-workers

# Query snapshot details of a specific worker by PID
SwiftCaptureWorker --info-pid <pid>
```

---

## 2. Choosing Video & Audio Sources

### Display & Window Capture
| Option | Description |
| :--- | :--- |
| `--screen-index <n>` | 1-based display index (default: `1`). |
| `--app-name <name>` | Case-insensitive application name match for window capture. |
| `--app-bundle-id <id>` | Exact bundle identifier (e.g. `com.apple.Safari`). |
| `--source-id <id>` | Electron-compatible source ID (`screen:DISPLAY_ID:0` or `window:WINDOW_ID:0`). Supersedes `--screen-index` and `--app-bundle-id`. |
| `--area x:y:w:h` | Display-relative crop rectangle (cannot be used with application capture). |
| `--show-cursor` | Include cursor pointer in screen capture. |
| `--no-video` | Disables screen capture (must be used with audio or webcam capture). |

### Webcam Capture (AVFoundation)
| Option | Description |
| :--- | :--- |
| `--capture-webcam` | Captures webcam video as a secondary H.264 stream (`stream_id 4`). |
| `--webcam-device-id <id>` | Specific webcam unique ID from `--list-sources`. |
| `--webcam-fps <fps>` | Target FPS for webcam capture (default: `60`). |
| `--webcam-width <w>`, `--webcam-height <h>` | Dimensions for webcam capture (must specify both). |

### Audio Capture
Audio is strictly opt-in:
| Option | Description |
| :--- | :--- |
| `--capture-system-audio` | Capture system audio output through ScreenCaptureKit. |
| `--capture-input-audio` | Capture microphone or line-in via CoreAudio. |
| `--input-device-id <id>` | Select specific microphone device by unique ID. |
| `--capture-process-audio` | Tap specific application audio (macOS 14.2+). |
| `--audio-tap-pid <pid>` | Target process by numeric PID. |
| `--audio-tap-app <name>` | Target process by application name or partial bundle ID. |

---

## 3. Output Transports

### Mode A: Dedicated File Descriptors
Best for parent processes spawning `SwiftCaptureWorker` via pipes. Each stream writes framing packets adhering to the [SCAP protocol](PROTOCOL.md).

```bash
SwiftCaptureWorker \
  --screen-index 1 \
  --video-fd 1 \
  --capture-system-audio --system-audio-fd 3 \
  --capture-input-audio --input-audio-fd 4 \
  --control-fd 5
```

- `--video-fd <fd>`: Screen video stream (`stream_id 0`, default: `1` / stdout).
- `--system-audio-fd <fd>`: System audio stream (`stream_id 1`).
- `--input-audio-fd <fd>`: Input device/microphone stream (`stream_id 2`).
- `--process-audio-fd <fd>`: Per-process audio tap stream (`stream_id 3`).
- `--webcam-video-fd <fd>`: Webcam video stream (`stream_id 4`).
- `--control-fd <fd>`: Inbound control channel for master stop commands.

#### Interactive Control Channel (`--control-fd`)
The parent process can pass a dedicated file descriptor to gracefully control the worker:
- Write `"stop\n"` or `{"command": "stop"}\n` to the control FD to initiate graceful shutdown.
- Closing the control FD also signals the worker to cleanly terminate.

### Mode B: Multiplexed IPC (Socket or TCP)
When a single connection is preferred, the worker acts as a client and connects to a pre-existing Unix Domain Socket or TCP listener. All streams are multiplexed across the single connection using SCAP headers.

```bash
# Connect to Unix domain socket
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --ipc-socket /tmp/swiftcapture.sock

# Connect to localhost TCP port
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --ipc-port 9876
```

### Mode C: Native Broadcast (SRT / RTMP)
Broadcast directly to media servers without needing external relay software:

```bash
# Native SRT Broadcast (muxed into MPEG-TS container)
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --srt-url "srt://live.example.com:9000?streamid=publish/stream1" \
  --srt-latency-ms 120

# Native RTMP Broadcast (muxed into FLV tags)
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --rtmp-url "rtmp://live.example.com/live/stream-key"
```

### Mode D: Local MPEG-TS Dump (Inspection)
```bash
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --duration-ms 5000 \
  --dump-output test-recording.ts
```

---

## 4. Video & Encoder Tuning

| Option | Default | Description |
| :--- | :--- | :--- |
| `--fps <n>` | `60` | Frame rate for screen capture (`15`, `30`, or `60`). |
| `--bitrate <bps>` | Hardware default | Target H.264 video bitrate in bits per second (e.g. `6000000` for 6 Mbps). |
| `--keyframe-interval <n>`| `fps * 2` | Maximum keyframe interval in frames. |
| `--output-width <w>`, `--output-height <h>` | Source resolution | Downscales video hardware encoder output. Both must be provided and >= 128. |
| `--duration-ms <ms>` | Unlimited | Stop automatically after the specified time in milliseconds. |

---

## 5. Consumer Integration Examples

### Node.js / Electron Parent Integration (File Descriptors)
```javascript
import { spawn } from 'child_process';

const worker = spawn('./SwiftCaptureWorker', [
  '--screen-index', '1',
  '--video-fd', '1',
  '--capture-system-audio',
  '--system-audio-fd', '3',
  '--control-fd', '4'
], {
  stdio: [
    'ignore',    // stdin
    'pipe',      // stdout (fd 1: video SCAP packets)
    'inherit',   // stderr (worker logs)
    'pipe',      // fd 3: audio SCAP packets
    'pipe'       // fd 4: control channel
  ]
});

// To stop worker gracefully:
worker.stdio[4].write('stop\n');
```

### Inspecting MPEG-TS Stream via ffplay
```bash
SwiftCaptureWorker \
  --screen-index 1 \
  --capture-system-audio \
  --dump-output - | ffplay -
```
