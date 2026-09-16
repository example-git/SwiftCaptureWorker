import Foundation
import CoreMedia
import AVFoundation

final class PCMStreamSource {
    private let writer: PacketStreamWriter
    private var sentConfiguration = false
    private var normalizedTimelineBasePTS: CMTime?
    private var normalizedFrameCount: Int64 = 0
    private var normalizedSampleRate: Double = 48_000

    init(writer: PacketStreamWriter) {
        self.writer = writer
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw WorkerError.captureFailed("Received an audio buffer without a valid format description.")
        }

        let streamDescription = streamDescriptionPointer.pointee
        let isNonInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if !sentConfiguration {
            sentConfiguration = true
            let formatToken = Self.gstreamerAudioFormat(from: streamDescription) ?? ""
            let rate = Int(streamDescription.mSampleRate)
            let channels = Int(streamDescription.mChannelsPerFrame)
            let caps = "audio/x-raw,format=\(formatToken),layout=interleaved,rate=\(rate),channels=\(channels)"
            // Output is always interleaved regardless of the source ASBD layout, so
            // bytesPerFrame must reflect the interleaved stride: (bits/8) × channels.
            // For non-interleaved sources mBytesPerFrame equals bits/8 (one channel),
            // which would be wrong for the output format.
            let interleavedBytesPerFrame = UInt32(streamDescription.mBitsPerChannel / 8)
                * max(streamDescription.mChannelsPerFrame, 1)
            try writer.writeConfiguration(
                AudioStreamConfiguration(
                    codec: streamDescription.mFormatID == kAudioFormatLinearPCM ? "lpcm" : "\(streamDescription.mFormatID)",
                    sampleRate: streamDescription.mSampleRate,
                    channels: streamDescription.mChannelsPerFrame,
                    bitsPerChannel: streamDescription.mBitsPerChannel,
                    bytesPerFrame: interleavedBytesPerFrame,
                    framesPerPacket: streamDescription.mFramesPerPacket,
                    formatFlags: numericCast(streamDescription.mFormatFlags),
                    gstreamerCaps: caps,
                    isInterleaved: true
                )
            )
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw WorkerError.captureFailed("Received an audio buffer without an accessible payload block buffer.")
        }

        var payload = try Data.readingAudio(blockBuffer: blockBuffer)

        if isNonInterleaved {
            let channels = Int(streamDescription.mChannelsPerFrame)
            let bytesPerSample = Int(streamDescription.mBitsPerChannel) / 8
            if channels > 1 && bytesPerSample > 0 {
                payload = Self.interleave(payload, channels: channels, bytesPerSample: bytesPerSample)
            }
        }

        var sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        if sampleCount <= 0 {
            // mBytesPerFrame is 0 for non-interleaved formats, so derive frame count
            // from bytes-per-sample and channel count instead.
            let bytesPerSample = Int(streamDescription.mBitsPerChannel) / 8
            let channels = Int(streamDescription.mChannelsPerFrame)
            let frameBytes = isNonInterleaved
                ? (bytesPerSample > 0 ? bytesPerSample : 1)
                : (streamDescription.mBytesPerFrame > 0 ? Int(streamDescription.mBytesPerFrame) : 1)
            let denominator = isNonInterleaved
                ? frameBytes * max(channels, 1)
                : frameBytes
            sampleCount = denominator > 0 ? payload.count / denominator : 1
        }
        if sampleCount <= 0 {
            sampleCount = 1
        }

        // Use the host clock directly as PTS — same clock domain as video.
        // No frame-counter accumulation needed since the host clock already
        // provides monotonic real-time timestamps.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        try writer.writeSample(payload, ptsNanoseconds: pts.nanosecondsValue)
    }

    private func nextNormalizedPTS(from incomingPTS: CMTime, sampleCount: Int, sampleRate: Double) -> CMTime {
        let basePTS: CMTime
        if let existingBasePTS = normalizedTimelineBasePTS {
            basePTS = existingBasePTS
        } else {
            let incomingSeconds = CMTimeGetSeconds(incomingPTS)
            if incomingPTS.isValid && incomingSeconds.isFinite && incomingSeconds >= 0 {
                basePTS = incomingPTS
            } else {
                basePTS = .zero
            }
            normalizedTimelineBasePTS = basePTS
        }

        let validSampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : normalizedSampleRate
        normalizedSampleRate = validSampleRate
        let preferredTimescale = CMTimeScale(max(1, min(Int32.max, Int32(validSampleRate.rounded()))))

        let frameIndex = normalizedFrameCount
        let frameOffset = CMTime(value: frameIndex, timescale: preferredTimescale)
        let normalizedPTS = CMTimeAdd(basePTS, frameOffset)

        let consumedSamples = Int64(max(sampleCount, 1))
        normalizedFrameCount += consumedSamples
        return normalizedPTS
    }

    // Maps an AudioStreamBasicDescription to a GStreamer audio/x-raw format token.
    // Returns nil for unknown or unsupported combinations.
    private static func gstreamerAudioFormat(from asbd: AudioStreamBasicDescription) -> String? {
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let endian = isBigEndian ? "BE" : "LE"
        let bits = asbd.mBitsPerChannel

        if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
            guard bits == 32 || bits == 64 else { return nil }
            return "F\(bits)\(endian)"
        } else {
            let isSigned = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
            let prefix = isSigned ? "S" : "U"
            guard bits == 8 || bits == 16 || bits == 24 || bits == 32 else { return nil }
            if bits == 8 { return "\(prefix)8" }
            return "\(prefix)\(bits)\(endian)"
        }
    }

    // Converts non-interleaved PCM to interleaved.
    // Input:  [ch0_s0, ch0_s1, ..., ch1_s0, ch1_s1, ...]
    // Output: [ch0_s0, ch1_s0, ch0_s1, ch1_s1, ...]
    private static func interleave(_ data: Data, channels: Int, bytesPerSample: Int) -> Data {
        let samplesPerChannel = data.count / (channels * bytesPerSample)
        var output = Data(count: data.count)
        output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                for frame in 0..<samplesPerChannel {
                    for ch in 0..<channels {
                        let srcOffset = (ch * samplesPerChannel + frame) * bytesPerSample
                        let dstOffset = (frame * channels + ch) * bytesPerSample
                        dstBase.advanced(by: dstOffset)
                            .copyMemory(from: srcBase.advanced(by: srcOffset), byteCount: bytesPerSample)
                    }
                }
            }
        }
        return output
    }
}

private extension Data {
    static func readingAudio(blockBuffer: CMBlockBuffer) throws -> Data {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)

        let status = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }

            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }

        guard status == noErr else {
            throw WorkerError.captureFailed("Failed to copy audio data from a CoreMedia block buffer (status \(status)).")
        }

        return data
    }
}
