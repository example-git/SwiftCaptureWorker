import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

final class H264Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private let fps: Int
    private let bitRate: Int
    private let frameDuration: CMTime
    private var isHWAccelerated: Bool = false
    private let outputHandler: @Sendable (EncodedVideoSample) -> Void
    /// Coordinator closure that translates a raw input PTS (on whatever clock
    /// the sample came from) into a host-domain, master-origin-relative CMTime
    /// on the 90 kHz grid. Provided by SyncCoordinator. If nil, we behave
    /// like the pre-sync code and anchor to the first raw PTS ourselves.
    private let hostDomainPTSFor: (@Sendable (CMTime) -> CMTime)?
    private var streamConfigurationSent = false
    private var cachedParameterSets: [Data]?
    private var framesSubmitted: Int64 = 0
    private var framesEncoded: Int64 = 0
    private var keyFramesEncoded: Int64 = 0
    private var backlogWarningActive = false
    private var backlogHighWatermark: Int64 = 0
    /// Set to true when cadence locks AFTER an SPS has already been emitted.
    /// On the next keyframe we refresh the SPS so VUI reflects the true cadence.
    private var pendingSPSRefresh = false

    // === PTS normalization ===
    //
    // Output PTS is quantized onto a 90 kHz grid (the MPEG-TS standard timescale)
    // with frame spacing derived from the camera's *real* cadence, which may be
    // fractional (e.g. 59.94 or 59.9997 fps). We cannot use a fixed 1/fps spacing
    // because that drifts against wall-clock audio over time.
    //
    // Strategy: prefer the authoritative `realFrameDuration` supplied by the caller
    // (from AVCaptureDevice.activeFormat), falling back to 1/fps. Output PTS is then
    //   outputPTS = anchorTicks + frameIndex * ticksPerFrame  (on the 90 kHz grid)
    // The anchor is provided by SyncCoordinator for the very first frame — this
    // preserves the real wall-clock offset between the video and audio streams.
    // If no authoritative duration is supplied, we self-calibrate by measuring the
    // median of the first N input-PTS deltas and lock-in once per session.
    private static let ptsTimescale: CMTimeScale = 90_000
    private static let calibrationFrameCount = 30
    private var observedDeltaSeconds: [Double] = []
    private var measuredFrameDurationSeconds: Double
    private var isFrameDurationLocked: Bool
    private let usesAuthoritativeInputPTS: Bool
    /// Frame-duration value used when the currently-cached SPS was generated.
    /// Triggers SPS re-emit if it drifts materially after calibration locks.
    private var frameDurationAtSPSEmit: Double = 0
    private var outputFrameIndex: Int64 = 0
    private var lastEmittedOutputPTSValue: Int64 = -1
    /// Set from the first incoming raw PTS via the coordinator closure.
    /// Subsequent output PTS is computed as anchorTicks + frameIndex * ticksPerFrame.
    private var anchorTicks: Int64? = nil
    /// True if source pixel format is full-range (0-255), false for video-range (16-235) or BGRA.
    private let isFullRange: Bool

    private let lock = NSLock()
    private let debugLogging = ProcessInfo.processInfo.environment["SCAP_DEBUG_ENCODER"] == "1"
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    init(
        width: Int32,
        height: Int32,
        fps: Int,
        bitRate: Int?,
        keyFrameInterval: Int?,
        realFrameDuration: CMTime? = nil,
        pixelFormat: OSType? = nil,
        hostDomainPTSFor: (@Sendable (CMTime) -> CMTime)? = nil,
        outputHandler: @escaping @Sendable (EncodedVideoSample) -> Void
    ) throws {
        self.fps = fps
        self.bitRate = bitRate ?? Self.defaultBitRate(width: width, height: height, fps: fps)
        self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        self.hostDomainPTSFor = hostDomainPTSFor
        self.outputHandler = outputHandler
        // Determine if pixel format is full-range. Capture cards typically use video-range;
        // modern webcams prefer full-range. BGRA is treated as full-range (computer graphics).
        if let pixelFormat {
            self.isFullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                            || pixelFormat == kCVPixelFormatType_32BGRA
        } else {
            // Default to full-range if unknown (BGRA fallback behavior)
            self.isFullRange = true
        }

        // If the caller supplies the device's actual frame duration (e.g. from
        // AVCaptureDevice.activeVideoMinFrameDuration), trust it — it's the real
        // cadence (possibly fractional, e.g. 1001/60000 for 59.94). Otherwise
        // seed from integer fps and self-calibrate by observing input deltas.
        if let realFrameDuration, realFrameDuration.isValid {
            let seconds = CMTimeGetSeconds(realFrameDuration)
            if seconds.isFinite && seconds > 0 {
                self.measuredFrameDurationSeconds = seconds
                self.isFrameDurationLocked = true
                self.usesAuthoritativeInputPTS = true
            } else {
                self.measuredFrameDurationSeconds = 1.0 / Double(max(fps, 1))
                self.isFrameDurationLocked = false
                self.usesAuthoritativeInputPTS = false
            }
        } else {
            self.measuredFrameDurationSeconds = 1.0 / Double(max(fps, 1))
            self.isFrameDurationLocked = false
            self.usesAuthoritativeInputPTS = false
        }

        let encoderSpecification: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ] as CFDictionary

        var createdSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionCallback,
            refcon: Unmanaged.passRetained(self).toOpaque(),
            compressionSessionOut: &createdSession
        )

        guard status == noErr, let createdSession else {
            throw WorkerError.encodingFailed("Failed to create a hardware H.264 encoder session (status \(status)).")
        }

        session = createdSession
        try setProperty(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        try setProperty(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        if VTSessionSetProperty(createdSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel) != noErr {
            if VTSessionSetProperty(createdSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel) != noErr {
                try setProperty(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
            }
        }

        setOptionalProperty(kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFTypeRef)
        setOptionalProperty(kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        setOptionalProperty(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanFalse)
        try setProperty(kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFTypeRef)
        try setProperty(kVTCompressionPropertyKey_AverageBitRate, value: self.bitRate as CFTypeRef)

        // Hard limit bitrate to 1.2x target over any 1-second window to prevent RTMP buffer overflows
        let maxBytes = Int(Double(self.bitRate) * 1.2 / 8.0)
        let dataRateLimits: CFArray = [maxBytes as CFNumber, 1.0 as CFNumber] as CFArray
        setOptionalProperty(kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

        // Inform encoder of peak frame rate for burst handling (macOS 15.0+)
        setOptionalProperty(kVTCompressionPropertyKey_MaximumRealTimeFrameRate, value: fps as CFTypeRef)

        try setProperty(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (keyFrameInterval ?? fps * 2) as CFTypeRef)
        VTCompressionSessionPrepareToEncodeFrames(createdSession)
        self.isHWAccelerated = Self.isHardwareAccelerated(createdSession)
    }

    deinit {
        // CRITICAL: finish() or invalidate() MUST be called before deallocation to
        // release the passRetained refcon and free internal VT buffers. Calling
        // invalidate() here can deadlock when SCStream is still delivering frames.
        //
        // If this warning fires, it indicates a leaked H264Encoder instance (~1-2KB)
        // plus accumulated VT internal state (~5-10MB depending on duration).
        if session != nil {
            let data = "[H264Encoder] LEAK WARNING: encoder deallocated without calling finish()/invalidate() — VT session and refcon leaked\n".data(using: .utf8)!
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }

    func encode(_ imageBuffer: CVImageBuffer, pts: CMTime, forceKeyFrame: Bool = false) throws {
        guard let session else {
            throw WorkerError.encodingFailed("Video encoder session is unavailable.")
        }

        let frameIndex = lock.withLock {
            framesSubmitted += 1
            return framesSubmitted
        }
        if debugLogging && frameIndex == 1 {
            Self.log("[H264Encoder] input started fps=\(fps) bitrate=\(bitRate) hw=\(isHWAccelerated ? "yes" : "no")")
        }
        let frameProperties: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: frameDuration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        guard status == noErr else {
            throw WorkerError.encodingFailed("Failed to encode H.264 frame (status \(status)).")
        }
    }

    /// Flush pending frames without invalidating. Called periodically during capture
    /// to keep VT's output pipeline drained so shutdown CompleteFrames is fast.
    ///
    /// **CRITICAL**: This MUST be called periodically (e.g., every 60-120 frames) to
    /// drain VideoToolbox's internal buffers. Without periodic flushing, VT accumulates
    /// intermediate encoding state (bitstream buffers, reference frames, metadata) which
    /// causes heap growth (~5-6 MB/min at 60fps). Call this from the same thread/queue
    /// that calls encode() to avoid queue inversion with the output callback.
    func flush() {
        lock.lock()
        guard let session else {
            lock.unlock()
            return
        }
        lock.unlock()
        // Call CompleteFrames WITHOUT holding the lock — it blocks waiting for
        // the output callback (handleEncodedSampleBuffer), which needs to acquire
        // the lock. Holding it here causes deadlock.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    /// Flush all pending frames then invalidate. May block if the stream is still active.
    func finish() {
        lock.lock()
        defer { lock.unlock() }

        guard let session else { return }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        // Balance the passRetained in init — VT will no longer call the callback.
        Unmanaged.passUnretained(self).release()
    }

    /// Invalidate immediately without flushing. Use during shutdown when the reader is already closed.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }

        guard let session else { return }

        VTCompressionSessionInvalidate(session)
        self.session = nil
        // Balance the passRetained in init — VT will no longer call the callback.
        Unmanaged.passUnretained(self).release()
    }

    /// Reset the stream-configuration-sent flag so the next encoded frame re-emits
    /// the configuration packet. Call this after an IPC reconnection.
    func resetConfiguration() {
        streamConfigurationSent = false
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        autoreleasepool {
            guard CMSampleBufferDataIsReady(sampleBuffer),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
                  let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                return
            }

        let isKeyFrame = Self.isKeyFrame(sampleBuffer)
        let encodeStats = lock.withLock {
            framesEncoded += 1
            if isKeyFrame { keyFramesEncoded += 1 }
            let backlog = max(0, framesSubmitted - framesEncoded)
            if backlog > backlogHighWatermark {
                backlogHighWatermark = backlog
            }
            return (submitted: framesSubmitted, encoded: framesEncoded, keyframes: keyFramesEncoded, backlog: backlog, warned: backlogWarningActive, highWatermark: backlogHighWatermark)
        }
        if encodeStats.backlog >= 8 && !encodeStats.warned {
            lock.withLock { backlogWarningActive = true }
            Self.log("[H264Encoder] falling behind backlog=\(encodeStats.backlog) peak=\(encodeStats.highWatermark) submitted=\(encodeStats.submitted) encoded=\(encodeStats.encoded)")
        } else if encodeStats.backlog == 0 && encodeStats.warned {
            lock.withLock { backlogWarningActive = false }
            Self.log("[H264Encoder] caught up peak=\(encodeStats.highWatermark) submitted=\(encodeStats.submitted) encoded=\(encodeStats.encoded)")
        } else if debugLogging && encodeStats.encoded == 1 {
            Self.log("[H264Encoder] output started profile=high/main/cabac bitrate=\(bitRate)")
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Quantize output PTS onto a 90 kHz integer grid, using the *measured*
        // frame duration (which may reflect a fractional rate like 59.94 fps).
        // This gives downstream consumers clean integer-tick spacing on the
        // standard MPEG-TS timescale, anchored to real wall-clock time.
        let pts = normalizedOutputPTS(rawPTS: rawPTS)

        // Current config uses AllowFrameReordering = false so dts == pts. If
        // reordering is ever enabled, we'd read the real DTS from the sample
        // buffer and translate it through the same coordinator pipeline; the
        // MPEGTSMuxer already emits a dedicated DTS field when it differs.
        let dts = pts

        do {
            // Cache parameter sets — they only change at keyframes.
            // Also refresh the SPS if calibration just locked on a materially
            // different cadence (pendingSPSRefresh); the refresh only takes
            // effect on the next keyframe so downstream parsers don't see a
            // mid-GOP VUI shift.
            let needsSPSRefresh = isKeyFrame && lock.withLock {
                let pending = pendingSPSRefresh
                pendingSPSRefresh = false
                if pending {
                    frameDurationAtSPSEmit = measuredFrameDurationSeconds
                }
                return pending
            }
            if isKeyFrame || cachedParameterSets == nil || needsSPSRefresh {
                let parameterSets = try Self.parameterSets(from: formatDescription)
                let frameDurationSeconds = lock.withLock { measuredFrameDurationSeconds }
                cachedParameterSets = Self.normalizeParameterSetsForFixedFrameRate(
                    parameterSets,
                    frameDurationSeconds: frameDurationSeconds,
                    isFullRange: isFullRange
                )
            }
            let parameterSets = cachedParameterSets!

            let bitstream = try Self.annexBData(from: blockBuffer, prependParameterSets: isKeyFrame ? parameterSets : [])

            if !streamConfigurationSent {
                streamConfigurationSent = true
                let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
                let width = Int(dims.width)
                let height = Int(dims.height)
                let caps = "video/x-h264,stream-format=byte-stream,alignment=au," +
                           "width=\(width),height=\(height),framerate=\(fps)/1"
                outputHandler(
                    EncodedVideoSample(
                        configuration: VideoStreamConfiguration(
                            codec: "h264",
                            width: width,
                            height: height,
                            fps: fps,
                            bitRate: bitRate,
                            format: "annexb",
                            gstreamerCaps: caps,
                            hardwareAccelerated: isHWAccelerated,
                            parameterSets: parameterSets.map { $0.base64EncodedString() }
                        ),
                        payload: nil,
                        pts: pts,
                        isKeyFrame: false
                    )
                )
            }

            outputHandler(
                EncodedVideoSample(
                    configuration: nil,
                    payload: bitstream,
                    pts: pts,
                    dts: dts,
                    isKeyFrame: isKeyFrame
                )
            )
        } catch {
            outputHandler(
                EncodedVideoSample(
                    configuration: nil,
                    payload: nil,
                    pts: .invalid,
                    dts: .invalid,
                    isKeyFrame: false,
                    error: error.localizedDescription
                )
            )
        }
        }
    }

    private func setProperty(_ key: CFString, value: CFTypeRef) throws {
        guard let session else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw WorkerError.encodingFailed("Failed to configure the H.264 encoder property \(key) (status \(status)).")
        }
    }

    private func setOptionalProperty(_ key: CFString, value: CFTypeRef) {
        guard let session else { return }
        _ = VTSessionSetProperty(session, key: key, value: value)
    }

    /// Quantize an outgoing video PTS onto a 90 kHz integer grid using the
    /// authoritative frame duration (caller-supplied) or a median measured from
    /// input PTS deltas after `calibrationFrameCount` frames. The anchor
    /// (tick value of the first frame) is supplied by the SyncCoordinator so
    /// the host-clock offset between streams is preserved. Guarantees
    /// monotonic output PTS even across the calibration lock-in boundary.
    private func normalizedOutputPTS(rawPTS: CMTime) -> CMTime {
        lock.lock()
        defer { lock.unlock() }

        // Self-calibration (only runs when realFrameDuration was not supplied).
        let wasLocked = isFrameDurationLocked
        if !isFrameDurationLocked,
           rawPTS.isValid,
           let previous = lastEmittedRawPTSForCalibration {
            let delta = CMTimeGetSeconds(CMTimeSubtract(rawPTS, previous))
            if delta.isFinite, delta > 0, delta < 1.0 {
                observedDeltaSeconds.append(delta)
                if observedDeltaSeconds.count >= Self.calibrationFrameCount {
                    let sorted = observedDeltaSeconds.sorted()
                    measuredFrameDurationSeconds = sorted[sorted.count / 2]
                    isFrameDurationLocked = true
                }
            }
        }
        lastEmittedRawPTSForCalibration = rawPTS

        // Anchor on first frame. Prefer the coordinator (which preserves
        // cross-stream offsets); fall back to the raw PTS quantized to 90 kHz
        // if no coordinator was supplied.
        let translatedPTS: CMTime
        if let hostDomainPTSFor {
            translatedPTS = hostDomainPTSFor(rawPTS)
        } else {
            translatedPTS = rawPTS
        }

        if anchorTicks == nil {
            if translatedPTS.isValid {
                anchorTicks = CMTimeConvertScale(
                    translatedPTS,
                    timescale: Self.ptsTimescale,
                    method: .roundHalfAwayFromZero
                ).value
            } else {
                anchorTicks = 0
            }
            frameDurationAtSPSEmit = measuredFrameDurationSeconds
        }

        let index = outputFrameIndex
        outputFrameIndex += 1

        let computedTicks: Int64
        if usesAuthoritativeInputPTS, translatedPTS.isValid {
            computedTicks = CMTimeConvertScale(
                translatedPTS,
                timescale: Self.ptsTimescale,
                method: .roundHalfAwayFromZero
            ).value
        } else {
            let ticksPerFrame = Int64((measuredFrameDurationSeconds * Double(Self.ptsTimescale)).rounded())
            computedTicks = (anchorTicks ?? 0) + index * ticksPerFrame
        }

        var totalTicks = computedTicks

        // Guarantee strict monotonic increase — protects against the rare case
        // where a late calibration lock-in would produce a smaller ticksPerFrame
        // and retroactively shrink the PTS of a later frame relative to an
        // earlier one already sent.
        if totalTicks <= lastEmittedOutputPTSValue {
            totalTicks = lastEmittedOutputPTSValue + 1
        }
        lastEmittedOutputPTSValue = totalTicks

        // If calibration JUST locked and the duration moved materially vs the
        // value cached in the current SPS, flag an SPS refresh for the next
        // keyframe so downstream timing metadata stays accurate.
        if !wasLocked && isFrameDurationLocked && frameDurationAtSPSEmit > 0 {
            let ratio = measuredFrameDurationSeconds / frameDurationAtSPSEmit
            if abs(ratio - 1.0) > 0.01 {
                pendingSPSRefresh = true
            }
        }

        return CMTime(value: totalTicks, timescale: Self.ptsTimescale)
    }

    private var lastEmittedRawPTSForCalibration: CMTime?

    private static func log(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    private static let compressionCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr,
              let refcon,
              let sampleBuffer else {
            return
        }

        let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.handleEncodedSampleBuffer(sampleBuffer)
    }

    private static func parameterSets(from formatDescription: CMFormatDescription) throws -> [Data] {
        var result: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var count = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )

            guard status == noErr, let pointer else {
                throw WorkerError.encodingFailed("Failed to read H.264 parameter set \(index) (status \(status)).")
            }

            result.append(Data(bytes: pointer, count: size))
        }
        return result
    }

    private static func normalizeParameterSetsForFixedFrameRate(_ parameterSets: [Data], frameDurationSeconds: Double, isFullRange: Bool) -> [Data] {
        guard !parameterSets.isEmpty else {
            return parameterSets
        }

        var normalized = parameterSets
        if let normalizedSPS = rewriteSPSWithVUITimingIfNeeded(parameterSets[0], frameDurationSeconds: frameDurationSeconds, isFullRange: isFullRange) {
            normalized[0] = normalizedSPS
        }
        return normalized
    }

    private static func rewriteSPSWithVUITimingIfNeeded(_ spsNALUnit: Data, frameDurationSeconds: Double, isFullRange: Bool) -> Data? {
        guard spsNALUnit.count > 1 else {
            return nil
        }

        let nalHeader = spsNALUnit[spsNALUnit.startIndex]
        let nalUnitType = nalHeader & 0x1F
        guard nalUnitType == 7 else {
            return nil
        }

        let rbsp = removeEmulationPreventionBytes(from: spsNALUnit.dropFirst())
        let rbspBits = bits(from: rbsp)
        guard
            let stopBitIndex = rbspStopBitIndex(in: rbspBits),
            let spsInfo = parseSPSHeaderInfo(in: rbspBits, stopBitIndex: stopBitIndex)
        else {
            return nil
        }

        var outputBits: [UInt8] = []
        outputBits.reserveCapacity(rbspBits.count + 128)
        outputBits.append(contentsOf: rbspBits[0..<spsInfo.vuiFlagBitIndex])
        outputBits.append(1) // vui_parameters_present_flag = true
        appendDefaultVUI(bits: &outputBits, frameDurationSeconds: frameDurationSeconds, isFullRange: isFullRange)

        // rbsp_trailing_bits: stop bit + zero padding to byte boundary.
        outputBits.append(1)
        while outputBits.count % 8 != 0 {
            outputBits.append(0)
        }

        let rewrittenRBSP = bytes(from: outputBits)
        let rewrittenEBSP = insertEmulationPreventionBytes(in: rewrittenRBSP)
        return Data([nalHeader]) + rewrittenEBSP
    }

    private static func appendDefaultVUI(bits outputBits: inout [UInt8], frameDurationSeconds: Double, isFullRange: Bool) {
        // aspect_ratio_info_present_flag
        outputBits.append(0)
        // overscan_info_present_flag
        outputBits.append(0)

        // video_signal_type_present_flag = 1 (CRITICAL: signals range and color info)
        outputBits.append(1)
        // video_format = 5 (unspecified, 3 bits)
        appendBits(5, bitCount: 3, into: &outputBits)
        // video_full_range_flag: 1 = full-range (0-255, webcams/BGRA), 0 = video-range (16-235, capture cards)
        outputBits.append(isFullRange ? 1 : 0)
        // colour_description_present_flag = 1
        outputBits.append(1)
        // colour_primaries = 1 (BT.709, 8 bits)
        appendBits(1, bitCount: 8, into: &outputBits)
        // transfer_characteristics = 1 (BT.709, 8 bits)
        appendBits(1, bitCount: 8, into: &outputBits)
        // matrix_coefficients = 1 (BT.709, 8 bits)
        appendBits(1, bitCount: 8, into: &outputBits)

        // chroma_loc_info_present_flag
        outputBits.append(0)
        // timing_info_present_flag
        outputBits.append(1)

        let (numUnitsInTick, timeScale) = vuiRational(forFrameDurationSeconds: frameDurationSeconds)
        appendBits(UInt64(numUnitsInTick), bitCount: 32, into: &outputBits)
        appendBits(UInt64(timeScale), bitCount: 32, into: &outputBits)
        // fixed_frame_rate_flag
        outputBits.append(1)

        // nal_hrd_parameters_present_flag
        outputBits.append(0)
        // vcl_hrd_parameters_present_flag
        outputBits.append(0)
        // pic_struct_present_flag
        outputBits.append(0)
        // bitstream_restriction_flag
        outputBits.append(0)
    }

    /// Pick `(num_units_in_tick, time_scale)` such that
    /// `frame_rate = time_scale / (2 * num_units_in_tick)` (H.264 spec —
    /// time_scale is twice the frame rate when fixed_frame_rate_flag=1).
    ///
    /// Prefer a small-denominator rational matching a standard rate (e.g.
    /// 60000/1001 for 59.94) when the frame duration is close. Otherwise fall
    /// back to a micro-tick representation.
    private static func vuiRational(forFrameDurationSeconds duration: Double) -> (numUnitsInTick: UInt32, timeScale: UInt32) {
        let target = duration > 0 ? (1.0 / duration) : 60.0

        // (frameRate, num_units_in_tick, time_scale)
        // time_scale = 2 * numerator, num_units_in_tick = denominator — so rate = time_scale/(2*num_units).
        let candidates: [(Double, UInt32, UInt32)] = [
            (24000.0/1001.0, 1001, 48000),
            (24.0,             1,      48),
            (25.0,             1,      50),
            (30000.0/1001.0, 1001, 60000),
            (30.0,             1,      60),
            (50.0,             1,     100),
            (60000.0/1001.0, 1001, 120000),
            (60.0,             1,     120),
            (120.0,            1,     240)
        ]

        var best: (UInt32, UInt32) = (1, 120)
        var bestErr = Double.infinity
        for (rate, num, ts) in candidates {
            let err = abs(rate - target) / max(rate, 1e-9)
            if err < bestErr {
                bestErr = err
                best = (num, ts)
            }
        }

        // Threshold: 0.1 ppm. If no standard form matches that precisely,
        // fall back to microsecond-scale ticks.
        if bestErr <= 1e-7 {
            return best
        }

        // Fallback: time_scale = round(target * 2 * 1_000_000), num_units_in_tick = 1_000_000.
        let num: UInt32 = 1_000_000
        let scaled = (target * 2.0 * Double(num)).rounded()
        let ts = UInt32(max(2, min(Double(UInt32.max), scaled)))
        return (num, ts)
    }

    private static func appendBits(_ value: UInt64, bitCount: Int, into outputBits: inout [UInt8]) {
        guard bitCount > 0 else { return }
        for bitIndex in stride(from: bitCount - 1, through: 0, by: -1) {
            outputBits.append(UInt8((value >> UInt64(bitIndex)) & 0x1))
        }
    }

    private static func rbspStopBitIndex(in bits: [UInt8]) -> Int? {
        guard !bits.isEmpty else {
            return nil
        }
        var index = bits.count - 1
        while index >= 0 && bits[index] == 0 {
            index -= 1
        }
        guard index >= 0 else {
            return nil
        }
        return index
    }

    private static func removeEmulationPreventionBytes(from data: some DataProtocol) -> Data {
        var result = Data()
        result.reserveCapacity(data.count)
        var zeroCount = 0
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if zeroCount >= 2 && byte == 0x03 {
                zeroCount = 0
                index = data.index(after: index)
                continue
            }
            result.append(byte)
            if byte == 0 {
                zeroCount += 1
            } else {
                zeroCount = 0
            }
            index = data.index(after: index)
        }
        return result
    }

    private static func insertEmulationPreventionBytes(in rbsp: Data) -> Data {
        var result = Data()
        result.reserveCapacity(rbsp.count + rbsp.count / 16)
        var zeroCount = 0

        for byte in rbsp {
            if zeroCount >= 2 && byte <= 0x03 {
                result.append(0x03)
                zeroCount = 0
            }
            result.append(byte)
            if byte == 0 {
                zeroCount += 1
            } else {
                zeroCount = 0
            }
        }

        return result
    }

    private static func bits(from data: Data) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(data.count * 8)
        for byte in data {
            for bitIndex in stride(from: 7, through: 0, by: -1) {
                result.append(UInt8((byte >> bitIndex) & 0x1))
            }
        }
        return result
    }

    private static func bytes(from bits: [UInt8]) -> Data {
        precondition(bits.count % 8 == 0, "Bit stream length must be byte-aligned")
        var result = Data(capacity: bits.count / 8)
        var byte: UInt8 = 0
        for (index, bit) in bits.enumerated() {
            byte = (byte << 1) | (bit & 0x1)
            if index % 8 == 7 {
                result.append(byte)
                byte = 0
            }
        }
        return result
    }

    private struct SPSHeaderInfo {
        let vuiFlagBitIndex: Int
        let vuiParametersPresent: Bool
    }

    private static func parseSPSHeaderInfo(in bits: [UInt8], stopBitIndex: Int) -> SPSHeaderInfo? {
        guard stopBitIndex > 0 else {
            return nil
        }
        let payloadBits = Array(bits[0..<stopBitIndex])
        var reader = BitReader(bits: payloadBits)

        guard let profileIDC = reader.readBits(8) else { return nil } // profile_idc
        guard reader.readBits(8) != nil else { return nil } // constraint_set flags + reserved
        guard reader.readBits(8) != nil else { return nil } // level_idc
        guard reader.readUE() != nil else { return nil }    // seq_parameter_set_id

        let highProfileIDs: Set<UInt64> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        if highProfileIDs.contains(profileIDC) {
            guard let chromaFormatIDC = reader.readUE() else { return nil }
            if chromaFormatIDC == 3 {
                guard reader.readBit() != nil else { return nil }
            }
            guard reader.readUE() != nil else { return nil } // bit_depth_luma_minus8
            guard reader.readUE() != nil else { return nil } // bit_depth_chroma_minus8
            guard reader.readBit() != nil else { return nil } // qpprime_y_zero_transform_bypass_flag
            guard let seqScalingMatrixPresentFlag = reader.readBit() else { return nil }
            if seqScalingMatrixPresentFlag == 1 {
                let scalingListCount = (chromaFormatIDC != 3) ? 8 : 12
                for index in 0..<scalingListCount {
                    guard let present = reader.readBit() else { return nil }
                    if present == 1 {
                        let size = index < 6 ? 16 : 64
                        guard reader.skipScalingList(ofSize: size) else { return nil }
                    }
                }
            }
        }

        guard reader.readUE() != nil else { return nil } // log2_max_frame_num_minus4
        guard let picOrderCntType = reader.readUE() else { return nil }
        if picOrderCntType == 0 {
            guard reader.readUE() != nil else { return nil } // log2_max_pic_order_cnt_lsb_minus4
        } else if picOrderCntType == 1 {
            guard reader.readBit() != nil else { return nil } // delta_pic_order_always_zero_flag
            guard reader.readSE() != nil else { return nil }  // offset_for_non_ref_pic
            guard reader.readSE() != nil else { return nil }  // offset_for_top_to_bottom_field
            guard let cycleCount = reader.readUE() else { return nil }
            if cycleCount > 256 {
                return nil
            }
            for _ in 0..<cycleCount {
                guard reader.readSE() != nil else { return nil }
            }
        }

        guard reader.readUE() != nil else { return nil } // num_ref_frames
        guard reader.readBit() != nil else { return nil } // gaps_in_frame_num_value_allowed_flag
        guard reader.readUE() != nil else { return nil } // pic_width_in_mbs_minus1
        guard reader.readUE() != nil else { return nil } // pic_height_in_map_units_minus1
        guard let frameMbsOnlyFlag = reader.readBit() else { return nil }
        if frameMbsOnlyFlag == 0 {
            guard reader.readBit() != nil else { return nil } // mb_adaptive_frame_field_flag
        }
        guard reader.readBit() != nil else { return nil } // direct_8x8_inference_flag
        guard let frameCroppingFlag = reader.readBit() else { return nil }
        if frameCroppingFlag == 1 {
            guard reader.readUE() != nil else { return nil }
            guard reader.readUE() != nil else { return nil }
            guard reader.readUE() != nil else { return nil }
            guard reader.readUE() != nil else { return nil }
        }

        let vuiFlagIndex = reader.position
        guard let vuiFlag = reader.readBit() else { return nil }
        return SPSHeaderInfo(vuiFlagBitIndex: vuiFlagIndex, vuiParametersPresent: vuiFlag == 1)
    }

    private struct BitReader {
        let bits: [UInt8]
        var position: Int = 0

        mutating func readBit() -> UInt8? {
            guard position < bits.count else { return nil }
            let bit = bits[position]
            position += 1
            return bit
        }

        mutating func readBits(_ count: Int) -> UInt64? {
            guard count >= 0, position + count <= bits.count else { return nil }
            var value: UInt64 = 0
            for _ in 0..<count {
                guard let bit = readBit() else { return nil }
                value = (value << 1) | UInt64(bit)
            }
            return value
        }

        mutating func readUE() -> Int? {
            var leadingZeroBits = 0
            while let bit = readBit() {
                if bit == 0 {
                    leadingZeroBits += 1
                    if leadingZeroBits > 31 {
                        return nil
                    }
                    continue
                }
                if leadingZeroBits == 0 {
                    return 0
                }
                guard let suffix = readBits(leadingZeroBits) else { return nil }
                let value = (1 << leadingZeroBits) - 1 + Int(suffix)
                return value
            }
            return nil
        }

        mutating func readSE() -> Int? {
            guard let ueValue = readUE() else { return nil }
            let magnitude = (ueValue + 1) / 2
            return ueValue % 2 == 0 ? -magnitude : magnitude
        }

        mutating func skipScalingList(ofSize size: Int) -> Bool {
            var lastScale = 8
            var nextScale = 8
            for _ in 0..<size {
                if nextScale != 0 {
                    guard let deltaScale = readSE() else { return false }
                    nextScale = (lastScale + deltaScale + 256) % 256
                }
                lastScale = (nextScale == 0) ? lastScale : nextScale
            }
            return true
        }
    }

    private static func annexBData(from blockBuffer: CMBlockBuffer, prependParameterSets: [Data]) throws -> Data {
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)

        // Pre-size: parameter sets + start codes + block data (start codes replace 4-byte lengths, so same size).
        let paramOverhead = prependParameterSets.reduce(0) { $0 + 4 + $1.count }
        var output = Data()
        output.reserveCapacity(paramOverhead + totalLength)

        for parameterSet in prependParameterSets {
            output.append(contentsOf: startCode)
            output.append(parameterSet)
        }

        // Try zero-copy access to the contiguous block buffer.
        var dataPointer: UnsafeMutablePointer<CChar>?
        var lengthAtOffset = 0
        var totalLengthOut = 0
        let contiguousStatus = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLengthOut, dataPointerOut: &dataPointer
        )

        if contiguousStatus == noErr, let ptr = dataPointer, lengthAtOffset == totalLength {
            // Fast path: buffer is contiguous — parse NALs in-place without copying.
            try ptr.withMemoryRebound(to: UInt8.self, capacity: totalLength) { base in
                var offset = 0
                while offset + 4 <= totalLength {
                    let nalLength = Int(UInt32(base[offset]) << 24 | UInt32(base[offset+1]) << 16 |
                                        UInt32(base[offset+2]) << 8 | UInt32(base[offset+3]))
                    offset += 4
                    guard offset + nalLength <= totalLength else {
                        throw WorkerError.encodingFailed("Encountered a truncated H.264 NAL unit in the encoded output.")
                    }
                    output.append(contentsOf: startCode)
                    output.append(UnsafeBufferPointer(start: base + offset, count: nalLength))
                    offset += nalLength
                }
            }
        } else {
            // Fallback: non-contiguous — copy to Data first.
            let data = try Data.reading(blockBuffer: blockBuffer)
            var cursor = data.startIndex
            while cursor + 4 <= data.endIndex {
                let nalLength = Int(data.withUnsafeBytes { buf -> UInt32 in
                    let p = buf.baseAddress!.advanced(by: cursor).assumingMemoryBound(to: UInt8.self)
                    return UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
                })
                cursor += 4
                guard cursor + nalLength <= data.endIndex else {
                    throw WorkerError.encodingFailed("Encountered a truncated H.264 NAL unit in the encoded output.")
                }
                output.append(contentsOf: startCode)
                output.append(data[cursor..<cursor + nalLength])
                cursor += nalLength
            }
        }

        return output
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]],
            let first = attachments.first else {
            return false
        }

        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static func isHardwareAccelerated(_ session: VTCompressionSession?) -> Bool {
        guard let session else {
            return false
        }

        var value: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault,
            valueOut: &value
        )

        guard status == noErr else {
            return false
        }

        guard let value else {
            return false
        }

        return (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false
    }

    private static func defaultBitRate(width: Int32, height: Int32, fps: Int) -> Int {
        let pixels = max(Int(width) * Int(height), 1)
        let scaled = Double(pixels) / Double(1920 * 1080)
        let bitrate = Int(8_000_000 * scaled * (Double(fps) / 30.0))
        if Int(width) >= 1280, Int(height) >= 720, fps >= 60 {
            return max(bitrate, 10_000_000)
        }
        return bitrate
    }
}

struct EncodedVideoSample {
    let configuration: VideoStreamConfiguration?
    let payload: Data?
    let pts: CMTime
    let dts: CMTime
    let isKeyFrame: Bool
    let error: String?

    init(
        configuration: VideoStreamConfiguration?,
        payload: Data?,
        pts: CMTime,
        dts: CMTime? = nil,
        isKeyFrame: Bool,
        error: String? = nil
    ) {
        self.configuration = configuration
        self.payload = payload
        self.pts = pts
        self.dts = dts ?? pts
        self.isKeyFrame = isKeyFrame
        self.error = error
    }
}

private extension Data {
    static func reading(blockBuffer: CMBlockBuffer) throws -> Data {
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
            throw WorkerError.encodingFailed("Failed to copy encoded H.264 data from the encoder output (status \(status)).")
        }

        return data
    }
}
