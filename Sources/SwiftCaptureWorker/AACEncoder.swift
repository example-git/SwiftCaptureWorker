import Foundation
import CoreMedia
import AudioToolbox
import AVFoundation

private struct ConverterInputContext {
    var bufferList: UnsafeMutablePointer<AudioBufferList>
    var packetCount: UInt32           // number of PCM frames (= packets) in the buffer
    var consumed: Bool = false
}

private let audioConverterInputProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, _, inUserData in
    guard let contextPtr = inUserData?.assumingMemoryBound(to: ConverterInputContext.self) else {
        return -50
    }

    if contextPtr.pointee.consumed {
        // End of input: return 0 packets with noErr per Apple's "Encoding and decoding audio" sample.
        ioNumberDataPackets.pointee = 0
        ioData.pointee.mNumberBuffers = 0
        return noErr
    }

    let inputBufferList = contextPtr.pointee.bufferList.pointee
    ioData.pointee.mNumberBuffers = 1
    let outBuffers = UnsafeMutableAudioBufferListPointer(ioData)
    outBuffers[0].mNumberChannels = inputBufferList.mBuffers.mNumberChannels
    outBuffers[0].mDataByteSize = inputBufferList.mBuffers.mDataByteSize
    outBuffers[0].mData = inputBufferList.mBuffers.mData

    // Report the number of PCM packets (= frames for PCM) we're providing.
    // ioNumberDataPackets.pointee is IN/OUT: on input the converter's desired count,
    // on output the actual count we're supplying.
    ioNumberDataPackets.pointee = contextPtr.pointee.packetCount

    contextPtr.pointee.consumed = true
    return noErr
}


private func audioConverterInputProcLog(_ audioBufferList: AudioBufferList) {
    fputs("AAC callback: channels=\(audioBufferList.mBuffers.mNumberChannels) bytes=\(audioBufferList.mBuffers.mDataByteSize)\n", stderr)
}


/// AAC audio encoder that converts PCM to ADTS-framed AAC using AudioConverter.
final class AACEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private let outputHandler: @Sendable (EncodedAudioSample) -> Void
    private let fallbackSampleRate: Double
    private let fallbackChannelCount: UInt32
    private let frameSize = 1024
    /// Coordinator closure that translates a raw input PTS into a host-domain,
    /// master-origin-relative CMTime on the 90 kHz grid. When nil, we anchor
    /// to the first input PTS directly (legacy behavior).
    private let hostDomainPTSFor: (@Sendable (CMTime) -> CMTime)?

    private var converter: AudioConverterRef?
    private var inputBuffer = Data()
    private var inputSampleRate: Double = 0
    private var backlogWarningActive = false
    private var framesSubmitted: Int64 = 0
    private var framesEncoded: Int64 = 0
    private let debugLogging = ProcessInfo.processInfo.environment["SCAP_DEBUG_ENCODER"] == "1"
    private var inputChannelCount: UInt32 = 0
    private var inputBytesPerFrame: Int = 0
    private var inputIsNonInterleaved = false
    private var frameDuration: CMTime = .invalid

    // Output PTS is quantized onto a 90 kHz integer grid with a rational
    // ticks-per-frame accumulator: at 48 kHz the spacing is exactly 1920; at
    // 44.1 kHz it is 2089 + 79/441. We carry the fractional remainder forward
    // so long-run drift is exactly zero. AAC emits exactly 1024 PCM samples
    // per frame, so cadence is deterministic — we just need an anchor
    // (provided by SyncCoordinator) and a frame counter.
    private static let ptsTimescale: CMTimeScale = 90_000
    private var anchorTicks: Int64 = 0
    private var hasAnchor: Bool = false
    private var outputFrameIndex: Int64 = 0
    /// Rational spacing per AAC frame: (numerator / denominator) where
    /// denominator = sampleRate, numerator = 1024 * 90_000. Exact integer math.
    private var ticksPerAACFrameNum: Int64 = 0
    private var ticksPerAACFrameDen: Int64 = 1
    /// Accumulated fractional remainder (0..<ticksPerAACFrameDen).
    private var ticksRemainder: Int64 = 0
    /// One-time priming compensation in 90 kHz ticks (from kAudioConverterPrimeInfo).
    private var primingCompensationTicks: Int64 = 0

    init(
        sampleRate: Float64 = 48000,
        channels: UInt32 = 2,
        hostDomainPTSFor: (@Sendable (CMTime) -> CMTime)? = nil,
        outputHandler: @escaping @Sendable (EncodedAudioSample) -> Void
    ) throws {
        self.fallbackSampleRate = sampleRate
        self.fallbackChannelCount = channels
        self.hostDomainPTSFor = hostDomainPTSFor
        self.outputHandler = outputHandler
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer, pts: CMTime) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw WorkerError.encodingFailed("No audio format description in sample buffer")
        }

        let streamDescription = streamDescriptionPointer.pointee
        if converter == nil {
            try initializeConverter(with: streamDescription)
        }

        guard let converter else {
            throw WorkerError.encodingFailed("Audio converter not available")
        }

        let pcmData = try Self.extractPCMData(from: sampleBuffer, streamDescription: streamDescription)

        let chunkByteCount = rawChunkByteCount
        guard chunkByteCount > 0 else {
            throw WorkerError.encodingFailed("Invalid AAC input frame size")
        }

        let submitStats = lock.withLock {
            inputBuffer.append(pcmData)
            framesSubmitted += 1
            return (submitted: framesSubmitted, bufferedBytes: inputBuffer.count)
        }
        if debugLogging && submitStats.submitted == 1 {
            fputs("[AACEncoder] input started rate=\(Int(inputSampleRate))Hz channels=\(inputChannelCount) chunk=\(chunkByteCount)\n", stderr)
        }
        lock.withLock {
            if submitStats.bufferedBytes >= chunkByteCount * 4 && !backlogWarningActive {
                backlogWarningActive = true
                fputs("[AACEncoder] buffering PCM backlog bytes=\(submitStats.bufferedBytes) frames=\(submitStats.submitted)\n", stderr)
            } else if submitStats.bufferedBytes < chunkByteCount * 2 && backlogWarningActive {
                backlogWarningActive = false
                fputs("[AACEncoder] AAC backlog drained bufferedBytes=\(submitStats.bufferedBytes) frames=\(submitStats.submitted)\n", stderr)
            }
        }

        // Anchor the output timeline via SyncCoordinator (preserves host-clock
        // offsets across streams). Fall back to raw PTS if no coordinator.
        if !hasAnchor {
            let anchorCM: CMTime
            if let hostDomainPTSFor {
                anchorCM = hostDomainPTSFor(pts)
            } else {
                anchorCM = pts
            }
            if anchorCM.isValid {
                let baseTicks = CMTimeConvertScale(
                    anchorCM,
                    timescale: Self.ptsTimescale,
                    method: .roundHalfAwayFromZero
                ).value
                // Subtract AAC priming compensation once. Clamp to zero so the
                // first output PTS is never negative — if the priming ever
                // exceeds the anchor position, we just start at zero and emit
                // a diagnostic.
                let compensated = baseTicks - primingCompensationTicks
                if compensated < 0 && primingCompensationTicks > 0 {
                    FileHandle.standardError.write(Data(
                        "[AACEncoder] Priming compensation (\(primingCompensationTicks) ticks) exceeded anchor (\(baseTicks)); clamping to 0.\n".utf8
                    ))
                    anchorTicks = 0
                } else {
                    anchorTicks = max(0, compensated)
                }
            } else {
                anchorTicks = 0
            }
            hasAnchor = true
        }

        while inputBuffer.count >= chunkByteCount {
            let frameData = Data(inputBuffer.prefix(chunkByteCount))
            // removeFirst() doesn't shrink capacity — it just shifts data. This causes
            // MALLOC_REALLOC growth as the buffer's capacity ratchets up via append()
            // but never releases. Replace with a fresh Data copy to free excess capacity.
            inputBuffer = Data(inputBuffer.dropFirst(chunkByteCount))

            let encodedData = try encodeFrame(frameData, converter: converter)

            let encodeStats = lock.withLock {
                framesEncoded += 1
                return (encoded: framesEncoded, submitted: framesSubmitted, bufferedBytes: inputBuffer.count)
            }
            if debugLogging && encodeStats.encoded == 1 {
                fputs("[AACEncoder] output started sampleRate=\(Int(inputSampleRate))Hz channels=\(inputChannelCount)\n", stderr)
            }

            // Compute frame PTS using a rational accumulator so non-48 kHz
            // rates (e.g. 44.1 kHz) do not accumulate rounding drift over
            // long captures. We emit floor(num*N + remainder0, den) and
            // carry the remainder forward.
            let num = ticksPerAACFrameNum
            let den = ticksPerAACFrameDen
            let totalNumerator = num * outputFrameIndex
            let frameOffsetTicks = totalNumerator / den
            // (`ticksRemainder` is unused — the floor division on every frame
            // implicitly handles the accumulator. Kept for clarity/future use.)
            let frameTicks = anchorTicks + frameOffsetTicks
            outputFrameIndex += 1
            let framePTS = CMTime(value: frameTicks, timescale: Self.ptsTimescale)

            outputHandler(
                EncodedAudioSample(
                    payload: encodedData,
                    pts: framePTS,
                    ptsNanoseconds: framePTS.nanosecondsValue
                )
            )
        }
    }

    private func initializeConverter(with streamDescription: AudioStreamBasicDescription) throws {
        var inputFormat = streamDescription

        inputSampleRate = inputFormat.mSampleRate > 0 ? inputFormat.mSampleRate : fallbackSampleRate
        inputChannelCount = max(inputFormat.mChannelsPerFrame, 1)
        inputIsNonInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        // We interleave the PCM data before encoding, so set up converter for interleaved input
        if inputIsNonInterleaved {
            inputFormat.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
            let bytesPerSample = max(1, Int(inputFormat.mBitsPerChannel) / 8)
            inputFormat.mBytesPerFrame = UInt32(bytesPerSample * Int(inputChannelCount))
            inputFormat.mBytesPerPacket = inputFormat.mBytesPerFrame * inputFormat.mFramesPerPacket
        }

        inputBytesPerFrame = Int(inputFormat.mBytesPerFrame)
        frameDuration = CMTime(seconds: Double(frameSize) / inputSampleRate, preferredTimescale: 90_000)
        // Rational ticks-per-AAC-frame on the 90 kHz MPEG-TS grid.
        //   num / den = frameSize * 90_000 / sampleRate
        // For 48 kHz this reduces to 1920/1 (exact). For 44.1 kHz this is
        // 1024*90000/44100 = 92160000/44100 = 2089 + (3900/44100) — we keep
        // numerator and denominator as integers and floor-divide per frame so
        // the cumulative drift is zero.
        let sampleRateInt = Int64(inputSampleRate.rounded())
        if sampleRateInt > 0 {
            ticksPerAACFrameNum = Int64(frameSize) * Int64(Self.ptsTimescale)
            ticksPerAACFrameDen = sampleRateInt
        } else {
            ticksPerAACFrameNum = 1920
            ticksPerAACFrameDen = 1
        }
        ticksRemainder = 0

        // Per Apple's "Encoding and decoding audio" sample:
        //   outputDescription.mFormatID = kAudioFormatMPEG4AAC
        //   outputDescription.mFormatFlags = kAudioFormatFlagsAreAllClear
        //   outputDescription.mFramesPerPacket = 1024
        // All other ASBD fields (mBytesPerPacket, mBytesPerFrame, mBitsPerChannel) must be 0
        // because AAC is a variable-bitrate format — leave them zero and let the converter fill them.
        var outputFormat = AudioStreamBasicDescription()
        outputFormat.mSampleRate = inputSampleRate
        outputFormat.mFormatID = kAudioFormatMPEG4AAC
        outputFormat.mFormatFlags = 0  // kAudioFormatFlagsAreAllClear per Apple docs
        outputFormat.mChannelsPerFrame = inputChannelCount
        outputFormat.mFramesPerPacket = 1024

        // Use the canonicalized output channel count for ADTS headers
        inputChannelCount = outputFormat.mChannelsPerFrame

        var converterRef: AudioConverterRef?
        let converterStatus = AudioConverterNew(&inputFormat, &outputFormat, &converterRef)
        guard converterStatus == noErr, let converterRef else {
            throw WorkerError.encodingFailed("Failed to create AAC converter (status \(converterStatus))")
        }

        converter = converterRef

        // Compute the one-time AAC priming-delay compensation. AAC-LC starts
        // with 2048 PCM frames of leading silence that are not carried in the
        // PCM stream but ARE implicit in the decoder's output. Querying
        // kAudioConverterPrimeInfo gives the authoritative leadingFrames value
        // for this converter instance; fall back to 2048 if querying fails.
        var primeInfo = AudioConverterPrimeInfo(leadingFrames: 0, trailingFrames: 0)
        var primeInfoSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        let primeStatus = AudioConverterGetProperty(
            converterRef,
            kAudioConverterPrimeInfo,
            &primeInfoSize,
            &primeInfo
        )
        let leadingFrames: Int64 = (primeStatus == noErr && primeInfo.leadingFrames > 0)
            ? Int64(primeInfo.leadingFrames)
            : 2048
        // Convert leadingFrames (in PCM samples) to 90 kHz ticks.
        if inputSampleRate > 0 {
            primingCompensationTicks = Int64((Double(leadingFrames) * Double(Self.ptsTimescale) / inputSampleRate).rounded())
        } else {
            primingCompensationTicks = 0
        }
    }

    private var rawChunkByteCount: Int {
        frameSize * inputBytesPerFrame
    }

    private func encodeFrame(_ pcmData: Data, converter: AudioConverterRef) throws -> Data {
        let maxOutputSize = 4096
        var aacBuffer = Data(count: maxOutputSize)
        var aacBytes = 0

        try pcmData.withUnsafeBytes { pcmBytes in
            guard let pcmBase = pcmBytes.baseAddress else {
                throw WorkerError.encodingFailed("Failed to access PCM data")
            }

            var inBuffer = AudioBuffer()
            inBuffer.mNumberChannels = inputChannelCount
            inBuffer.mDataByteSize = UInt32(pcmData.count)
            inBuffer.mData = UnsafeMutableRawPointer(mutating: pcmBase)

            var inBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: inBuffer)

            try withUnsafeMutablePointer(to: &inBufferList) { bufferListPtr in
                var inputContext = ConverterInputContext(
                    bufferList: bufferListPtr,
                    packetCount: UInt32(frameSize),  // 1024 PCM frames = 1024 packets
                    consumed: false
                )

                try aacBuffer.withUnsafeMutableBytes { outputBufferPtr in
                    guard let outputBase = outputBufferPtr.baseAddress else {
                        throw WorkerError.encodingFailed("Failed to allocate AAC output buffer")
                    }

                    var outBuffer = AudioBuffer()
                    outBuffer.mNumberChannels = inputChannelCount
                    outBuffer.mDataByteSize = UInt32(maxOutputSize)
                    outBuffer.mData = outputBase

                    var outBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: outBuffer)
                    var outputPacketCount: UInt32 = 1
                    // Per Apple docs: when encoding (PCM->AAC), packetDescriptions must be provided
                    // so the converter can report the actual byte size of each variable-size output packet.
                    var packetDescription = AudioStreamPacketDescription()
                    let status = AudioConverterFillComplexBuffer(
                        converter,
                        audioConverterInputProc,
                        &inputContext,
                        &outputPacketCount,
                        &outBufferList,
                        &packetDescription
                    )
                    guard status == noErr else {
                        throw WorkerError.encodingFailed("AAC encoding failed (status \(status))")
                    }

                    // Use the authoritative size reported by the packet description.
                    aacBytes = outputPacketCount > 0
                        ? Int(packetDescription.mDataByteSize)
                        : Int(outBufferList.mBuffers.mDataByteSize)
                }
            }
        }

        return createADTSFrame(aacData: Data(aacBuffer.prefix(aacBytes)))
    }

    private static func extractPCMData(
        from sampleBuffer: CMSampleBuffer,
        streamDescription: AudioStreamBasicDescription
    ) throws -> Data {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            throw WorkerError.encodingFailed("Audio sample buffer is not ready")
        }

        let sampleCount = max(CMSampleBufferGetNumSamples(sampleBuffer), 0)
        let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)
        let bytesPerSample = max(1, Int(streamDescription.mBitsPerChannel) / 8)
        let isNonInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bufferCount = isNonInterleaved ? channelCount : 1
        let ablSize = MemoryLayout<AudioBufferList>.size + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size

        guard let rawABL = malloc(ablSize) else {
            throw WorkerError.encodingFailed("Failed to allocate audio buffer list")
        }
        defer { free(rawABL) }

        memset(rawABL, 0, ablSize)
        let bufferList = rawABL.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            throw WorkerError.encodingFailed("Failed to extract PCM audio buffer list (status \(status))")
        }

        // Keep blockBuffer alive until scope exit — the raw pointers in bufferList
        // point into its memory, and ARC would otherwise be free to release it
        // right after the call above (it is never read again). withExtendedLifetime
        // is the guaranteed way to pin it; `_ = x` is not optimizer-proof.
        // Note: ARC owns the +1 retain from the "...Retained..." API and releases
        // it automatically — this is a lifetime fix, not a leak fix.
        defer { withExtendedLifetime(blockBuffer) {} }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard !buffers.isEmpty else {
            return Data()
        }

        if !isNonInterleaved || buffers.count == 1 {
            let sourceBuffer = buffers[0]
            guard let sourceData = sourceBuffer.mData else {
                return Data()
            }
            let length = Int(sourceBuffer.mDataByteSize)
            return Data(bytes: sourceData, count: length)
        }

        let frameCount = sampleCount > 0
            ? sampleCount
            : Int(buffers[0].mDataByteSize) / bytesPerSample
        let outputBytes = frameCount * channelCount * bytesPerSample
        var output = Data(count: outputBytes)

        output.withUnsafeMutableBytes { dstBuffer in
            guard let dstBase = dstBuffer.baseAddress else { return }
            for channelIndex in 0..<buffers.count {
                guard let srcBase = buffers[channelIndex].mData?.assumingMemoryBound(to: UInt8.self) else {
                    continue
                }
                for sampleIndex in 0..<frameCount {
                    let srcOffset = sampleIndex * bytesPerSample
                    let dstOffset = (sampleIndex * channelCount + channelIndex) * bytesPerSample
                    dstBase.advanced(by: dstOffset).copyMemory(
                        from: srcBase.advanced(by: srcOffset),
                        byteCount: bytesPerSample
                    )
                }
            }
        }

        return output
    }

    private func createADTSFrame(aacData: Data) -> Data {
        var frame = Data()
        let sampleRate = inputSampleRate > 0 ? inputSampleRate : fallbackSampleRate
        let channelCount = min(max(Int(inputChannelCount == 0 ? fallbackChannelCount : inputChannelCount), 1), 7)
        let sampleRateIndex = Self.adtsSampleRateIndex(for: sampleRate)
        let profile: UInt8 = 1 // AAC LC


        let frameLength = aacData.count + 7

        frame.append(0xFF)
        frame.append(0xF1)
        frame.append((profile << 6) | (sampleRateIndex << 2) | UInt8(channelCount >> 2))
        frame.append((UInt8(channelCount & 3) << 6) | UInt8((frameLength >> 11) & 0x03))
        frame.append(UInt8((frameLength >> 3) & 0xFF))
        frame.append(UInt8(((frameLength & 0x07) << 5) | 0x1F))
        frame.append(0xFC)
        frame.append(aacData)
        return frame
    }

    private static func adtsSampleRateIndex(for sampleRate: Double) -> UInt8 {
        switch Int(sampleRate.rounded()) {
        case 96_000: return 0
        case 88_200: return 1
        case 64_000: return 2
        case 48_000: return 3
        case 44_100: return 4
        case 32_000: return 5
        case 24_000: return 6
        case 22_050: return 7
        case 16_000: return 8
        case 12_000: return 9
        case 11_025: return 10
        case 8_000: return 11
        default: return 3
        }
    }
}

struct EncodedAudioSample: Sendable {
    let payload: Data
    /// PTS on a 90 kHz MPEG-TS grid. Preserved precisely for muxer consumers.
    let pts: CMTime
    /// Convenience — derived from `pts`. Prefer `pts` when routing into the muxer
    /// to avoid round-trip precision loss via seconds/nanoseconds.
    let ptsNanoseconds: UInt64
}
