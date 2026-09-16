# SCAP Wire Protocol (SwiftCapture Packet)

`SCAP` is the binary framing protocol used by `SwiftCaptureWorker` for file-descriptor outputs and multiplexed IPC (Unix Domain Socket / TCP). It delivers stream configuration metadata, raw media samples, error notices, and lifecycle markers for one or more concurrent streams.

All multi-byte integer fields are **unsigned** and serialized in **network byte order (Big-Endian)**.

---

## 1. Frame Layout

Every SCAP frame consists of a fixed **24-byte header** immediately followed by `length` bytes of payload:

```text
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      magic ('SCAP')                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|    version    |     type      |             flags             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                    pts (nanoseconds, 64-bit)                  +
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            length                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   stream_id   |                    reserved                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       payload (length bytes)...               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### Header Fields

| Offset | Type | Field | Description |
| :---: | :---: | :--- | :--- |
| `0..3` | `[UInt8; 4]` | `magic` | Constant ASCII `SCAP` (`0x53 0x43 0x41 0x50`). |
| `4` | `UInt8` | `version` | Protocol version; currently `1` (`0x01`). |
| `5` | `UInt8` | `type` | Frame type identifier (see table below). |
| `6..7` | `UInt16` | `flags` | Bit 0 (`0x0001`): Keyframe indicator (for video streams). Other bits reserved. |
| `8..15` | `UInt64` | `pts` | Presentation timestamp in **nanoseconds** using host monotonic clock. |
| `16..19` | `UInt32` | `length` | Byte size of the trailing payload (`0` to `4,294,967,295`). |
| `20` | `UInt8` | `stream_id` | Identifies which logical stream this packet belongs to. |
| `21..23` | `[UInt8; 3]` | `reserved` | Reserved for future alignment (always zero; ignore on read). |

> [!NOTE]
> **PTS Timestamps**: `pts` values have no wall-clock epoch. Use relative differences between frames and align audio/video streams by their shared monotonic PTS nanosecond timeline.

---

## 2. Frame Types (`type`)

| Value | Identifier | Payload Description |
| :---: | :--- | :--- |
| `1` | `CONFIG` | UTF-8 encoded JSON stream configuration payload. |
| `2` | `SAMPLE` | Encoded video NAL units or audio frame data. |
| `3` | `END_OF_STREAM`| Empty payload (`length = 0`). Indicates orderly shutdown of the stream. |
| `4` | `ERROR` | UTF-8 encoded error message string. |

Before transmitting any `SAMPLE` packets for a stream, the worker emits a `CONFIG` frame describing the stream parameters. Upon stop, the worker emits an `END_OF_STREAM` frame for each active stream.

---

## 3. Stream Identifiers (`stream_id`)

In multiplexed IPC mode (Unix domain socket or TCP), `stream_id` multiplexes all streams across the single connection:

| `stream_id` | Stream Name | Media / Codec |
| :---: | :--- | :--- |
| `0` | Screen Video | H.264 Annex-B (ScreenCaptureKit) |
| `1` | System Audio | AAC / LPCM (ScreenCaptureKit) |
| `2` | Input Audio | AAC / LPCM (CoreAudio microphone/line-in) |
| `3` | Process Audio | AAC / LPCM (macOS 14.2+ process tap) |
| `4` | Webcam Video | H.264 Annex-B (AVFoundation camera) |

*Note: In dedicated file-descriptor mode, each stream uses an independent file descriptor and writes `stream_id = 0`.*

---

## 4. Configuration Payloads (`type = 1`)

### Video Configuration (Screen & Webcam)
```json
{
  "codec": "h264",
  "width": 1920,
  "height": 1080,
  "fps": 60,
  "bitRate": 6000000,
  "format": "annexb",
  "hardwareAccelerated": true,
  "gstreamerCaps": "video/x-h264,stream-format=byte-stream,alignment=au,width=1920,height=1080,framerate=60/1",
  "parameterSets": [
    "Z01AH42NQDwBE/LgAM7e/gA8EA==",
    "aO48sA=="
  ]
}
```
- `parameterSets`: Base64-encoded H.264 Sequence Parameter Set (SPS) and Picture Parameter Set (PPS).

### Audio Configuration (System, Microphone, Process)
```json
{
  "codec": "aac",
  "sampleRate": 48000.0,
  "channels": 2,
  "bitsPerChannel": 16,
  "bytesPerFrame": 4,
  "framesPerPacket": 1024,
  "formatFlags": 0,
  "gstreamerCaps": "audio/mpeg,mpegversion=4,stream-format=raw,rate=48000,channels=2",
  "isInterleaved": true
}
```

---

## 5. Sample Payloads (`type = 2`)

- **Video Samples (H.264)**: Emitted as Annex-B access units prefixed with start codes (`00 00 00 01`). If the frame is an IDR keyframe, `flags & 0x0001` will be non-zero.
- **Audio Samples (AAC)**: Raw AAC frames (typically 1024 PCM samples per frame) without ADTS headers.
- **Audio Samples (LPCM)**: Raw interleaved uncompressed PCM data matching the audio configuration.

---

## 6. Interactive Control Protocol (`--control-fd`)

When `--control-fd` is supplied, the worker listens for master commands over that descriptor:
- **Stop Command (Plain text)**: `"stop\n"`
- **Stop Command (JSON)**: `{"command": "stop"}\n`
- **EOF**: Closing the descriptor will trigger a graceful termination of all capture sessions.

---

## 7. Reference Consumer Implementation

### Node.js Stream Parser
```javascript
class SCAPParser {
  constructor(onFrame) {
    this.buffer = Buffer.alloc(0);
    this.onFrame = onFrame;
  }

  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);

    while (this.buffer.length >= 24) {
      if (this.buffer.toString('ascii', 0, 4) !== 'SCAP') {
        throw new Error('Invalid SCAP magic header');
      }

      const version = this.buffer.readUInt8(4);
      const type = this.buffer.readUInt8(5);
      const flags = this.buffer.readUInt16BE(6);
      const pts = this.buffer.readBigUInt64BE(8);
      const length = this.buffer.readUInt32BE(16);
      const streamId = this.buffer.readUInt8(20);

      const totalFrameSize = 24 + length;
      if (this.buffer.length < totalFrameSize) {
        break; // Wait for full payload
      }

      const payload = this.buffer.subarray(24, totalFrameSize);
      this.buffer = this.buffer.subarray(totalFrameSize);

      this.onFrame({
        version,
        type,
        isKeyframe: Boolean(flags & 0x01),
        pts,
        streamId,
        payload
      });
    }
  }
}
```

