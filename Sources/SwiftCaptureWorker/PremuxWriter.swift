import Foundation
import CoreMedia

/// Writes synchronized video and audio streams to separate files.
/// These can be muxed together post-capture to create a single MP4/MKV file.
final class PremuxWriter {
    private let videoOutputURL: URL
    private let audioOutputURL: URL
    private let videoPTSURL: URL
    private let audioPTSURL: URL
    private let videoHandle: FileHandle
    private let audioHandle: FileHandle
    private let videoPTSHandle: FileHandle
    private let audioPTSHandle: FileHandle
    private let lock = NSLock()
    private var videoFrameCount = 0
    private var audioSampleCount = 0
    private var audioFormatDetected = false
    private var audioSampleRate: Double = 48000
    private var audioChannels: UInt32 = 2
    private var audioBytesPerSample: UInt32 = 4

    private var audioIsNonInterleaved = false
    private var audioIsFloat = false

    init(outputPath: String, width: Int32, height: Int32, fps: Int, sampleRate: Double = 48000, channels: UInt32 = 2) throws {
        let baseURL = URL(fileURLWithPath: outputPath)
        let basePath = baseURL.deletingPathExtension().path

        videoOutputURL = URL(fileURLWithPath: basePath + ".video.h264")
        audioOutputURL = URL(fileURLWithPath: basePath + ".audio.raw")
        videoPTSURL    = URL(fileURLWithPath: basePath + ".video.pts.jsonl")
        audioPTSURL    = URL(fileURLWithPath: basePath + ".audio.pts.jsonl")

        self.audioSampleRate = sampleRate
        self.audioChannels = channels

        // Create files
        FileManager.default.createFile(atPath: videoOutputURL.path, contents: nil, attributes: nil)
        FileManager.default.createFile(atPath: audioOutputURL.path, contents: nil, attributes: nil)
        FileManager.default.createFile(atPath: videoPTSURL.path, contents: nil, attributes: nil)
        FileManager.default.createFile(atPath: audioPTSURL.path, contents: nil, attributes: nil)

        guard let videoHandle = FileHandle(forWritingAtPath: videoOutputURL.path),
              let audioHandle = FileHandle(forWritingAtPath: audioOutputURL.path),
              let videoPTSHandle = FileHandle(forWritingAtPath: videoPTSURL.path),
              let audioPTSHandle = FileHandle(forWritingAtPath: audioPTSURL.path) else {
            throw WorkerError.captureFailed("Failed to open output files for premux")
        }

        self.videoHandle = videoHandle
        self.audioHandle = audioHandle
        self.videoPTSHandle = videoPTSHandle
        self.audioPTSHandle = audioPTSHandle

        // Log the paths
        fputs("[PREMUX] Video: \(videoOutputURL.path)\n", stderr)
        fputs("[PREMUX] Audio: \(audioOutputURL.path)\n", stderr)
        fputs("[PREMUX] Video PTS: \(videoPTSURL.path)\n", stderr)
        fputs("[PREMUX] Audio PTS: \(audioPTSURL.path)\n", stderr)
    }

    /// Write H.264 video payload with timestamp. The PTS sidecar file records
    /// a JSONL entry per frame so the post-capture mux tool can reconstruct
    /// exact frame timing.
    func appendVideo(payload: Data, pts: CMTime, isKeyFrame: Bool) {
        lock.withLock {
            videoFrameCount += 1
            videoHandle.write(payload)

            let ptsTicks = pts.isValid
                ? CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero).value
                : Int64(0)
            let line = "{\"pts_ticks_90k\":\(ptsTicks),\"is_key\":\(isKeyFrame ? "true" : "false"),\"byte_len\":\(payload.count)}\n"
            videoPTSHandle.write(Data(line.utf8))

            if videoFrameCount % 60 == 0 {
                fputs("[PREMUX] Video: \(videoFrameCount) frames, pts=\(pts.seconds)\n", stderr)
            }
        }
    }

    /// Write audio sample buffer.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            audioSampleCount += 1

            // Detect audio format from first sample
            if !audioFormatDetected {
                audioFormatDetected = true
                if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                    if let asbd = asbd?.pointee {
                        audioSampleRate = asbd.mSampleRate
                        audioChannels = asbd.mChannelsPerFrame
                        audioBytesPerSample = asbd.mBytesPerFrame / audioChannels

                        // Detect format flags
                        audioIsNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
                        audioIsFloat = (asbd.mFormatFlags & kLinearPCMFormatFlagIsFloat) != 0

                        fputs("[PREMUX] Audio: \(Int(audioSampleRate))Hz \(audioChannels)ch \(audioBytesPerSample)bytes/sample bytesPerFrame=\(asbd.mBytesPerFrame) isFloat=\(audioIsFloat) isNonInterleaved=\(audioIsNonInterleaved)\n", stderr)
                    }
                }
            }

            // Extract audio data from sample buffer
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                return
            }

            // Get the actual number of samples in this buffer
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            let actualLength = CMBlockBufferGetDataLength(dataBuffer)

            // For first sample, log the details
            if audioSampleCount == 1 {
                fputs("[PREMUX] First audio buffer: \(numSamples) samples, \(actualLength) bytes\n", stderr)
            }

            // Write all the data as-is (don't interleave for now)
            var audioData = Data(count: actualLength)
            audioData.withUnsafeMutableBytes { buffer in
                _ = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: actualLength, destination: buffer.baseAddress!)
            }

            audioHandle.write(audioData)

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsTicks = pts.isValid
                ? CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero).value
                : Int64(0)
            let line = "{\"pts_ticks_90k\":\(ptsTicks),\"byte_len\":\(audioData.count)}\n"
            audioPTSHandle.write(Data(line.utf8))

            if audioSampleCount % 240 == 0 {
                fputs("[PREMUX] Audio: \(audioSampleCount) buffers, pts=\(pts.seconds)\n", stderr)
            }
        }
    }

    func getAudioFormatInfo() -> (sampleRate: Double, channels: UInt32, bytesPerSample: UInt32) {
        lock.withLock {
            return (audioSampleRate, audioChannels, audioBytesPerSample)
        }
    }

    /// Convert non-interleaved float audio to interleaved.
    private func interleaveAudioData(_ data: Data, numSamples: Int) -> Data {
        let bytesPerSample = 4  // F32LE
        let channels = Int(audioChannels)
        let planarLength = numSamples * bytesPerSample

        // Each channel is stored as a contiguous block: [ch0: all samples] [ch1: all samples]
        var interleaved = Data(capacity: data.count)

        for sampleIdx in 0..<numSamples {
            for chIdx in 0..<channels {
                let offset = chIdx * planarLength + sampleIdx * bytesPerSample
                interleaved.append(data.subdata(in: offset..<offset + bytesPerSample))
            }
        }

        return interleaved
    }

    /// Finalize the output files.
    func finish() async {
        lock.withLock {
            videoPTSHandle.synchronizeFile()
            audioPTSHandle.synchronizeFile()
            videoPTSHandle.closeFile()
            audioPTSHandle.closeFile()
            videoHandle.closeFile()
            audioHandle.closeFile()
            fputs("[PREMUX] Finished: \(videoFrameCount) video frames, \(audioSampleCount) audio buffers\n", stderr)
        }
    }

    var outputPath: String { videoOutputURL.deletingPathExtension().path }
}
