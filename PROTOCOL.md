# SCAP protocol

SCAP (SwiftCapture Packet) is the binary protocol used by file-descriptor and
IPC output. It carries configuration metadata and media samples for one or more
streams. All integer fields are unsigned and big-endian.

For multiplexed IPC, a consumer must accept the worker's connection, buffer
incoming bytes, and parse complete frames. A read does not necessarily contain a
whole frame.

## Frame format

Each frame has a 24-byte header followed by `length` bytes of payload.

| Offset | Size | Field | Description |
| --- | ---: | --- | --- |
| 0 | 4 | `magic` | ASCII `SCAP` (`0x53 43 41 50`) |
| 4 | 1 | `version` | Protocol version; currently `1` |
| 5 | 1 | `type` | Frame type |
| 6 | 2 | `flags` | Bit 0 is the video-keyframe flag |
| 8 | 8 | `pts` | Presentation timestamp in nanoseconds |
| 16 | 4 | `length` | Payload size in bytes |
| 20 | 1 | `stream_id` | Stream identity in multiplexed IPC |
| 21 | 3 | `reserved` | Always zero; ignore on read |

`pts` values use the host monotonic clock. They have no wall-clock epoch; use
relative timestamps and synchronize streams by PTS.

## Frame types

| Value | Name | Payload |
| ---: | --- | --- |
| `1` | `CONFIG` | UTF-8 JSON stream configuration |
| `2` | `SAMPLE` | Encoded video or audio data |
| `3` | `END_OF_STREAM` | Empty |
| `4` | `ERROR` | UTF-8 error message |

Before sending samples for a stream, the worker sends a `CONFIG` frame. On a
normal stop it sends `END_OF_STREAM` for each active stream.

## Streams

These IDs apply to multiplexed IPC:

| ID | Stream |
| ---: | --- |
| `0` | Screen video |
| `1` | System audio |
| `2` | Input-device audio |
| `3` | Process audio |
| `4` | Webcam video |

In file-descriptor mode, each stream has its own descriptor, so consumers should
use the descriptor to identify the stream. The current writer uses `stream_id`
`0` for those independent streams.

## Configuration payloads

Video configuration is JSON with these fields:

```json
{
  "codec": "h264",
  "width": 1920,
  "height": 1080,
  "fps": 60,
  "bitRate": 8000000,
  "format": "annexb",
  "gstreamerCaps": "video/x-h264,...",
  "hardwareAccelerated": true,
  "parameterSets": ["base64-encoded SPS", "base64-encoded PPS"]
}
```

Audio configuration is JSON with `codec` (`"lpcm"` or `"aac"`), `sampleRate`,
`channels`, `bitsPerChannel`, `bytesPerFrame`, `framesPerPacket`,
`formatFlags`, `gstreamerCaps`, and `isInterleaved`.

## Sample payloads

- Video samples are H.264 Annex-B access units. A keyframe has flag bit 0 set.
- AAC samples are raw AAC frames without ADTS headers.
- LPCM samples are interleaved samples described by the preceding configuration.

Frames are ordered within a stream. There is no ordering guarantee between
streams, so consumers must buffer and synchronize each stream by PTS.

## Minimal parser algorithm

1. Buffer received bytes until at least 24 header bytes are available.
2. Verify the `SCAP` magic and read `length` at offset 16.
3. Wait until `24 + length` bytes are buffered.
4. Extract that frame, dispatch it by `type` and `stream_id`, and repeat.

Reject unsupported versions and impose a maximum accepted payload length before
allocating memory. If the magic does not match, discard bytes until a plausible
header is found or close the malformed connection.

## Transport behavior

The worker connects to an existing Unix-domain socket or to
`127.0.0.1:<port>` for IPC output. On a broken connection it attempts to
reconnect with backoff. Consumers should be prepared to receive configuration
frames again after a reconnection.

For file-descriptor output, writes are blocking. A consumer that stops reading
can stall capture.
