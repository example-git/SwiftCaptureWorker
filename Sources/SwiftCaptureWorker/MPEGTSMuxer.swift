import Foundation
import CoreMedia

/// Protocol for MPEG-TS packet sinks (file, SRT socket, etc.)
protocol MPEGTSSink: AnyObject {
    func writeTSChunk(_ data: Data) throws
    func close() throws
}

/// FileHandle conforms to MPEGTSSink
extension FileHandle: MPEGTSSink {
    func writeTSChunk(_ data: Data) throws {
        try write(contentsOf: data)
    }

    // close() is already defined on FileHandle
}

/// MPEG-TS muxer that combines H.264 video and AAC audio with proper synchronization.
/// Outputs to a file handle or file path suitable for ffplay/ffprobe.
final class MPEGTSMuxer {
    private let lock = NSLock()
    private var sink: MPEGTSSink?
    private var filePath: String?
    private let shouldCloseSink: Bool

    // Buffer for batching TS packets into 1316-byte chunks (7 × 188)
    private var tsBuffer = Data()
    private let tsChunkSize = 1316  // 7 TS packets

    // PAT/PMT tables (fixed for simplicity)
    private var patPMT: Data?
    private var nextPCR: UInt64 = 0
    private var lastVideoPTS: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var videoFrameCount = 0

    // A/V alignment is handled upstream by SyncCoordinator: every incoming
    // pts is already host-domain, master-origin-relative, and on the 90 kHz
    // grid. The muxer just packages it into PES. We preserve the absolute
    // offset between streams rather than rebasing each to zero independently.
    // For 33-bit PES wrap detection:
    private var ptsWrapLogged = false

    // Elementary stream PIDs
    private let videoPID: UInt16 = 0x100  // 256
    private let audioPID: UInt16 = 0x101  // 257
    private let patPID: UInt16 = 0x000
    private let pmtPID: UInt16 = 0x010
    private let sdtPID: UInt16 = 0x011   // DVB-SI Service Description Table

    // MPEG-TS packet constants
    private let packetSize = 188
    private var continuityCounterVideo = UInt8(0)
    private var continuityCounterAudio = UInt8(0)
    private var continuityCounterPAT = UInt8(0)
    private var continuityCounterPMT = UInt8(0)
    private var continuityCounterSDT = UInt8(0)


    /// Initialize with a custom sink (for SRT, network streams, etc.)
    init(sink: MPEGTSSink) throws {
        self.sink = sink
        self.filePath = nil
        self.shouldCloseSink = true

        // Write MPEG-TS header: PAT + PMT tables
        try writePATAndPMT()
    }

    /// Initialize with a file path (legacy mode)
    init(outputPath: String) throws {
        self.filePath = outputPath

        let fileHandle: FileHandle
        let shouldClose: Bool

        if outputPath == "/dev/stdout" || outputPath == "-" {
            fileHandle = .standardOutput
            shouldClose = false
        } else {
            // Create or truncate the output file
            FileManager.default.createFile(atPath: outputPath, contents: nil, attributes: nil)
            guard let handle = FileHandle(forWritingAtPath: outputPath) else {
                throw WorkerError.ioFailed("Failed to open output file for MPEG-TS mux: \(outputPath)")
            }
            fileHandle = handle
            shouldClose = true
        }

        self.sink = fileHandle
        self.shouldCloseSink = shouldClose

        // Write MPEG-TS header: PAT + PMT tables
        try writePATAndPMT()
    }

    deinit {
        // Flush any remaining buffered TS packets
        try? flushTSBuffer()

        if shouldCloseSink {
            try? sink?.close()
        }
    }

    /// Write H.264 video sample to the mux. `pts` and `dts` are expected to be
    /// already host-domain, master-origin-relative, and on the 90 kHz grid
    /// (see SyncCoordinator). If `dts` is `.invalid` it defaults to `pts`.
    func writeVideoSample(_ payload: Data, pts: CMTime, dts: CMTime = .invalid, isKeyFrame: Bool) throws {
        lock.lock()
        defer { lock.unlock() }

        lastVideoPTS = pts
        let effectiveDTS = dts.isValid ? dts : pts

        // Compute PCR from PTS (90 kHz, 33-bit). PCR is embedded in the first
        // TS packet of every video PES so the receiver has a continuous clock reference.
        let ptsCM = CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero)
        let pcrValue: UInt64 = ptsCM.isValid
            ? (UInt64(max(Int64(0), ptsCM.value)) & 0x1FFFFFFFF)
            : 0

        // Re-send PAT/PMT every 30 video frames (≈1 s at 30 fps) so the server
        // can re-sync if it missed the initial tables at stream start.
        videoFrameCount += 1
        if videoFrameCount % 30 == 0 {
            try writePATAndPMT()
        }

        // Prepend H.264 AUD (Access Unit Delimiter) NALU before every frame.
        // GStreamer's h264parse inserts AUD before muxing into MPEG-TS.
        // Many server-side H.264 parsers rely on AUD to locate AU boundaries
        // within PES payloads; without it they silently fail to decode frames.
        // AUD = start_code(4) + nal_type(0x09) + primary_pic_type(0xF0=any)
        let aud = Data([0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])
        let payloadWithAUD = aud + payload

        // Split H.264 payload into MPEG-TS packets, embedding PCR in the first
        try writePESPackets(
            payload: payloadWithAUD,
            streamID: 0xE0,  // H.264 video stream
            pts: pts,
            dts: effectiveDTS,
            pid: videoPID,
            continuityCounter: &continuityCounterVideo,
            pcrForFirstPacket: pcrValue,
            isKeyFrame: isKeyFrame
        )
    }

    /// Write AAC audio sample to the mux. `pts` is expected to be already
    /// host-domain, master-origin-relative, and on the 90 kHz grid.
    func writeAudioSample(_ payload: Data, pts: CMTime) throws {
        lock.lock()
        defer { lock.unlock() }

        lastAudioPTS = pts

        // Split AAC payload into MPEG-TS packets
        try writePESPackets(
            payload: payload,
            streamID: 0xC0,  // AAC audio stream
            pts: pts,
            dts: pts,
            pid: audioPID,
            continuityCounter: &continuityCounterAudio
        )
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }

        // Flush any remaining buffered TS packets
        try? flushTSBuffer()

        if shouldCloseSink {
            // Synchronize if it's a FileHandle
            (sink as? FileHandle)?.synchronizeFile()
            try? sink?.close()
        }
    }

    // MARK: - Private: Buffer Management

    /// Flush buffered TS packets to the sink in 1316-byte chunks (7 TS packets).
    /// Called when buffer >= 1316 bytes or on finish().
    private func flushTSBuffer() throws {
        guard !tsBuffer.isEmpty else { return }
        guard let sink = sink else {
            throw WorkerError.ioFailed("Sink not available for flushing TS buffer")
        }

        // Write complete 1316-byte chunks
        while tsBuffer.count >= tsChunkSize {
            let chunk = tsBuffer.prefix(tsChunkSize)
            try sink.writeTSChunk(Data(chunk))
            tsBuffer.removeFirst(tsChunkSize)
        }

        // On final flush (finish/deinit), also flush partial chunks
        // This is called with lock held, safe to check isEmpty
        if !tsBuffer.isEmpty {
            try sink.writeTSChunk(tsBuffer)
            tsBuffer.removeAll()
        }
    }

    // MARK: - Private: PAT/PMT Construction

    private func writePATAndPMT() throws {
        // PAT: Program Association Table
        var pat = Data()
        pat.append(0x00)  // table_id
        pat.append(0xB0)  // section_syntax_indicator=1, reserved=11, section_length_hi
        pat.append(0x0D)  // section_length_lo (13 bytes)
        pat.append(0x00)  // program_number_hi
        pat.append(0x01)  // program_number_lo
        pat.append(0xC1)  // reserved=11, version_number=00001
        pat.append(0x00)  // section_number
        pat.append(0x00)  // last_section_number
        pat.append(0x00)  // program_number_hi
        pat.append(0x01)  // program_number_lo
        pat.append(0xE0 | UInt8(pmtPID >> 8))  // reserved=111, PMT PID hi
        pat.append(UInt8(pmtPID & 0xFF))       // PMT PID lo

        // CRC32
        let patCRC = Self.calculateCRC32(pat)
        pat.append(UInt8((patCRC >> 24) & 0xFF))
        pat.append(UInt8((patCRC >> 16) & 0xFF))
        pat.append(UInt8((patCRC >> 8) & 0xFF))
        pat.append(UInt8(patCRC & 0xFF))

        // Prepend pointer_field (0x00) — required for PSI sections when PUSI=1 (ISO 13818-1 §2.4.4)
        var patPacket = Data([0x00])
        patPacket.append(contentsOf: pat)
        try writeTSPacket(pid: patPID, payload: patPacket, payloadStart: true, continuityCounter: &continuityCounterPAT)

        // PMT: Program Map Table
        var pmt = Data()
        pmt.append(0x02)  // table_id (PMT)
        pmt.append(0xB0)  // section_syntax_indicator=1, reserved=11, section_length_hi
        pmt.append(0x17)  // section_length_lo (23 bytes)
        pmt.append(0x00)  // program_number_hi
        pmt.append(0x01)  // program_number_lo
        pmt.append(0xC1)  // reserved=11, version_number=00001
        pmt.append(0x00)  // section_number
        pmt.append(0x00)  // last_section_number
        pmt.append(0xE0 | UInt8(videoPID >> 8))  // reserved=111, PCR PID hi
        pmt.append(UInt8(videoPID & 0xFF))       // PCR PID lo
        pmt.append(0xF0)  // reserved=1111, program_info_length_hi
        pmt.append(0x00)  // program_info_length_lo

        // Video stream descriptor (H.264)
        pmt.append(0x1B)  // stream_type (H.264)
        pmt.append(0xE0 | UInt8(videoPID >> 8))  // reserved=111, elementary_PID hi
        pmt.append(UInt8(videoPID & 0xFF))       // elementary_PID lo
        pmt.append(0xF0)  // reserved=1111, ES_info_length_hi
        pmt.append(0x00)  // ES_info_length_lo

        // Audio stream descriptor (AAC)
        pmt.append(0x0F)  // stream_type (AAC)
        pmt.append(0xE0 | UInt8(audioPID >> 8))  // reserved=111, elementary_PID hi
        pmt.append(UInt8(audioPID & 0xFF))       // elementary_PID lo
        pmt.append(0xF0)  // reserved=1111, ES_info_length_hi
        pmt.append(0x00)  // ES_info_length_lo

        // CRC32
        let pmtCRC = Self.calculateCRC32(pmt)
        pmt.append(UInt8((pmtCRC >> 24) & 0xFF))
        pmt.append(UInt8((pmtCRC >> 16) & 0xFF))
        pmt.append(UInt8((pmtCRC >> 8) & 0xFF))
        pmt.append(UInt8(pmtCRC & 0xFF))

        // Prepend pointer_field (0x00) — required for PSI sections when PUSI=1 (ISO 13818-1 §2.4.4)
        var pmtPacket = Data([0x00])
        pmtPacket.append(contentsOf: pmt)
        try writeTSPacket(pid: pmtPID, payload: pmtPacket, payloadStart: true, continuityCounter: &continuityCounterPMT)

        // SDT (Service Description Table, PID 0x0011) — GStreamer's mpegtsmux always emits
        // this alongside PAT/PMT. Some MPEG-TS demuxers (including GStreamer's tsdemux) wait
        // for SDT before fully initialising the service, which can stall the pipeline.
        try writeSDT()
    }

    /// Emit a minimal DVB SDT (table_id=0x42, actual_TS) with a single service entry
    /// for program 1. No human-readable service name is included (descriptor_length=0).
    private func writeSDT() throws {
        // SDT section payload (before pointer_field and CRC):
        //   table_id                          = 0x42 (SDT actual TS)
        //   section_syntax_indicator          = 1
        //   reserved_future_use               = 1
        //   reserved                          = 11
        //   section_length                    = 13 (bytes after this field through CRC)
        //   transport_stream_id               = 0x0001
        //   reserved                          = 11
        //   version_number                    = 00000
        //   current_next_indicator            = 1  → 0xC1
        //   section_number                    = 0x00
        //   last_section_number               = 0x00
        //   original_network_id               = 0x0001
        //   reserved_future_use               = 0xFF
        //   service_id (= program_number)     = 0x0001
        //   reserved_future_use(6) + EIT_schedule_flag(1) + EIT_present_following_flag(1) = 0xFC
        //   running_status(3) + free_CA_mode(1) + descriptors_loop_length(12)
        //     running_status=4 (running), free_CA_mode=0, descriptors_loop_length=0
        //     → 0x80 | (4 << 1) → high byte: (4 << 5) | 0 = 0x80, low byte: 0x00
        //   [no descriptors]
        //   CRC32 (4 bytes)
        // section_length counts: transport_stream_id(2) + version_byte(1) + section_number(1) +
        //   last_section_number(1) + original_network_id(2) + reserved(1) +
        //   service_entry(5) + CRC(4) = 17 bytes
        var sdt = Data()
        sdt.append(0x42)  // table_id: SDT actual
        sdt.append(0xF0)  // section_syntax_indicator=1, '1'=1, reserved=11, section_length hi=0000
        sdt.append(0x11)  // section_length lo = 17
        sdt.append(0x00)  // transport_stream_id hi
        sdt.append(0x01)  // transport_stream_id lo
        sdt.append(0xC1)  // reserved=11, version_number=0, current_next_indicator=1
        sdt.append(0x00)  // section_number
        sdt.append(0x00)  // last_section_number
        sdt.append(0x00)  // original_network_id hi
        sdt.append(0x01)  // original_network_id lo
        sdt.append(0xFF)  // reserved_future_use
        // Service entry: service_id=0x0001
        sdt.append(0x00)  // service_id hi
        sdt.append(0x01)  // service_id lo
        sdt.append(0xFC)  // reserved(6)=111111, EIT_schedule=0, EIT_present_following=0
        // running_status=4 (running), free_CA_mode=0, descriptors_loop_length=0
        // Bits: 100(running_status=4) 0(free_CA) 000000000000(length=0) → 0x80 0x00
        sdt.append(0x80)
        sdt.append(0x00)

        let sdtCRC = Self.calculateCRC32(sdt)
        sdt.append(UInt8((sdtCRC >> 24) & 0xFF))
        sdt.append(UInt8((sdtCRC >> 16) & 0xFF))
        sdt.append(UInt8((sdtCRC >> 8) & 0xFF))
        sdt.append(UInt8(sdtCRC & 0xFF))

        var sdtPacket = Data([0x00])  // pointer_field
        sdtPacket.append(contentsOf: sdt)
        try writeTSPacket(pid: sdtPID, payload: sdtPacket, payloadStart: true, continuityCounter: &continuityCounterSDT)
    }

    // MARK: - Private: PES and TS packet writing

    private func writePESPackets(
        payload: Data,
        streamID: UInt8,
        pts: CMTime,
        dts: CMTime,
        pid: UInt16,
        continuityCounter: inout UInt8,
        pcrForFirstPacket: UInt64? = nil,
        isKeyFrame: Bool = false
    ) throws {
        // Express PTS/DTS directly on the 90 kHz MPEG-TS grid. If the input
        // CMTime is already at 90 kHz we preserve tick-exact values; otherwise
        // we convert with rounding (rather than `.seconds * 90000` which truncates).
        let ptsCM = CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero)
        let dtsCM = CMTimeConvertScale(dts, timescale: 90_000, method: .roundHalfAwayFromZero)
        // MPEG-TS PES PTS/DTS is a 33-bit field. Modulo-wrap explicitly so
        // captures > 26.5h (or post-suspend clock jumps) don't overflow.
        let pesPTSMask: UInt64 = (UInt64(1) << 33) - 1
        let rawPTS = max(Int64(0), ptsCM.value)
        let rawDTS = max(Int64(0), dtsCM.value)
        if !ptsWrapLogged && (UInt64(rawPTS) > pesPTSMask || UInt64(rawDTS) > pesPTSMask) {
            FileHandle.standardError.write(Data(
                "[MPEGTSMuxer] PES PTS 33-bit wrap reached (ticks=\(rawPTS)); modulo wrap engaged.\n".utf8
            ))
            ptsWrapLogged = true
        }
        let ptsValue = UInt64(rawPTS) & pesPTSMask
        let dtsValue = UInt64(rawDTS) & pesPTSMask

        // ISO 13818-1 §2.4.3.7 compliance:
        // - Video (0xE0–0xEF): data_alignment_indicator=1, DTS always present (matches GStreamer mpegtsmux).
        // - Audio (0xC0–0xDF): data_alignment_indicator=0, DTS only when it differs from PTS.
        let isVideoStream = streamID >= 0xE0
        let writeDTS = isVideoStream || (ptsValue != dtsValue)

        // Build PES header
        var pesHeader = Data()
        pesHeader.append(0x00)  // packet_start_code_prefix (3 bytes)
        pesHeader.append(0x00)
        pesHeader.append(0x01)
        pesHeader.append(streamID)

        // PES packet length (written at bytes 4–5, fixed up below)
        pesHeader.append(0x00)
        pesHeader.append(0x00)

        // PES header flags byte:
        //   bits 7-6: '10' (fixed marker)
        //   bits 5-4: PES_scrambling_control = 00
        //   bit  3:   PES_priority = 0
        //   bit  2:   data_alignment_indicator — must be 1 for H.264 (each PES starts at AU boundary)
        //   bit  1:   copyright = 0
        //   bit  0:   original_or_copy = 0
        pesHeader.append(isVideoStream ? 0x84 : 0x80)

        if writeDTS {
            pesHeader.append(0xC0)  // PTS_DTS_flags=11 (both)
            pesHeader.append(0x0A)  // header_data_length: 10 bytes (5 PTS + 5 DTS)
        } else {
            pesHeader.append(0x80)  // PTS_DTS_flags=10 (PTS only)
            pesHeader.append(0x05)  // header_data_length: 5 bytes
        }

        // PTS (33 bits + marker bits)
        let ptsMarker: UInt8 = writeDTS ? 0x30 : 0x20
        pesHeader.append(ptsMarker | UInt8((ptsValue >> 30) & 0x07))
        pesHeader.append(UInt8((ptsValue >> 22) & 0xFF))
        pesHeader.append(UInt8((((ptsValue >> 15) & 0x7F) << 1) | 0x01))
        pesHeader.append(UInt8((ptsValue >> 7) & 0xFF))
        pesHeader.append(UInt8((((ptsValue & 0x7F) << 1) | 0x01)))

        if writeDTS {
            // DTS (33 bits + marker bits)
            pesHeader.append(0x10 | UInt8((dtsValue >> 30) & 0x07))
            pesHeader.append(UInt8((dtsValue >> 22) & 0xFF))
            pesHeader.append(UInt8((((dtsValue >> 15) & 0x7F) << 1) | 0x01))
            pesHeader.append(UInt8((dtsValue >> 7) & 0xFF))
            pesHeader.append(UInt8((((dtsValue & 0x7F) << 1) | 0x01)))
        }

        // PES_packet_length = number of bytes following this field (i.e., from byte 6 onward).
        // ISO 13818-1 §2.4.3.7: for video elementary streams the PES_packet_length MUST be 0
        // (unbounded). Strict MPEG-TS parsers reject non-zero lengths for video.
        if isVideoStream {
            pesHeader[4] = 0
            pesHeader[5] = 0
        } else {
            let pesPacketLength = (pesHeader.count - 6) + payload.count
            if pesPacketLength <= 0xFFFF {
                pesHeader[4] = UInt8((pesPacketLength >> 8) & 0xFF)
                pesHeader[5] = UInt8(pesPacketLength & 0xFF)
            } else {
                pesHeader[4] = 0
                pesHeader[5] = 0
            }
        }

        let pesData = pesHeader + payload

        // Split into TS packets
        var offset = 0
        var isPayloadStart = true
        while offset < pesData.count {
            // When PCR is carried in the first TS packet, 8 bytes of that packet's
            // 184-byte payload area are consumed by the adaptation field (1 length +
            // 1 flags + 6 PCR), leaving 176 bytes for PES data.
            // When DTS was added (video), the PES header is 5 bytes longer (14 vs 9),
            // so the effective available room is still correctly computed via min().
            let maxChunk = (isPayloadStart && pcrForFirstPacket != nil) ? 176 : 184
            let chunkSize = min(maxChunk, pesData.count - offset)
            let chunk = pesData.subdata(in: offset..<offset + chunkSize)
            try writeTSPacket(
                pid: pid,
                payload: chunk,
                payloadStart: isPayloadStart,
                continuityCounter: &continuityCounter,
                pcrValue: isPayloadStart ? pcrForFirstPacket : nil,
                randomAccessIndicator: isPayloadStart && isKeyFrame
            )
            offset += chunkSize
            isPayloadStart = false
        }
    }

    private static func calculateCRC32(_ data: Data) -> UInt32 {
        // MPEG-2 CRC32 polynomial: 0x04C11DB7
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04C11DB7 : (crc << 1)
            }
        }
        return crc
    }

    private func writeTSPacket(
        pid: UInt16,
        payload: Data,
        payloadStart: Bool,
        continuityCounter: inout UInt8,
        pcrValue: UInt64? = nil,
        randomAccessIndicator: Bool = false
    ) throws {
        guard sink != nil else {
            throw WorkerError.ioFailed("Sink not available for writing MPEG-TS packet")
        }

        // Available payload space per TS packet (188 - 4-byte header).
        let maxPayload = packetSize - 4
        let payloadLen = payload.count
        precondition(payloadLen <= maxPayload, "writeTSPacket expects chunks <= 184 bytes")

        // Adaptation field is needed when payload < 184 bytes (stuffing), PCR must be carried,
        // or random_access_indicator must be set.
        // adaptation_field_control: 01 = payload only, 10 = adaptation only, 11 = both.
        let needsAdaptationField = payloadLen < maxPayload || pcrValue != nil || randomAccessIndicator
        let afc: UInt8 = needsAdaptationField ? 0x30 : 0x10

        var packet = Data(capacity: packetSize)

        // Sync byte
        packet.append(0x47)

        // Header byte 1: transport_error_indicator=0, payload_unit_start_indicator, transport_priority=0, PID hi
        let headerByte1 = (payloadStart ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F)
        packet.append(headerByte1)

        // Header byte 2: PID lo
        packet.append(UInt8(pid & 0xFF))

        // Header byte 3: transport_scrambling=00, adaptation_field_control, continuity_counter
        packet.append(afc | (continuityCounter & 0x0F))

        continuityCounter = (continuityCounter + 1) & 0x0F

        if let pcr = pcrValue {
            // PCR adaptation field: 1 length byte + 1 flags byte + 6 PCR bytes + stuffing.
            // Caller must have limited payload to <= 176 bytes so there's room.
            let adaptationFieldLength = 183 - payloadLen  // = 188 - 4 header - 1 length byte - payloadLen
            precondition(adaptationFieldLength >= 7,
                         "PCR adaptation field requires adaptationFieldLength >= 7; payloadLen=\(payloadLen)")
            let stuffingCount = adaptationFieldLength - 7  // 7 = 1 flags + 6 PCR bytes

            packet.append(UInt8(adaptationFieldLength))
            // flags: PCR_flag=1, random_access_indicator=1 for keyframes
            let afFlags: UInt8 = 0x10 | (randomAccessIndicator ? 0x40 : 0x00)
            packet.append(afFlags)

            // 6-byte PCR field: 33-bit base (90 kHz) + 6-bit reserved (all 1s) + 9-bit extension (0)
            // Encoding (ISO 13818-1 §2.4.3.5):
            //   bits[47:15] = pcr_base (33 bits)
            //   bits[14:9]  = reserved (6 bits, all 1s)
            //   bits[8:0]   = pcr_extension (9 bits, 0)
            let pcrBase = pcr & 0x1FFFFFFFF
            packet.append(UInt8((pcrBase >> 25) & 0xFF))
            packet.append(UInt8((pcrBase >> 17) & 0xFF))
            packet.append(UInt8((pcrBase >> 9)  & 0xFF))
            packet.append(UInt8((pcrBase >> 1)  & 0xFF))
            // byte 4: base[0] (1 bit) | reserved=111111 (6 bits) | extension[8]=0 (1 bit) = 0x7E mask
            packet.append(UInt8(((pcrBase & 0x01) << 7) | 0x7E))
            packet.append(0x00)  // PCR extension[7:0] = 0

            for _ in 0..<stuffingCount {
                packet.append(0xFF)
            }
        } else if needsAdaptationField {
            // Stuffing-only adaptation field (no PCR), possibly with random_access_indicator.
            // adaptation_field_length counts the bytes AFTER itself.
            let adaptationFieldTotal = maxPayload - payloadLen  // includes the length byte
            let adaptationFieldLength = adaptationFieldTotal - 1
            packet.append(UInt8(adaptationFieldLength))
            if adaptationFieldLength >= 1 {
                // Flags byte: random_access_indicator when this is a keyframe start packet
                let afFlags: UInt8 = randomAccessIndicator ? 0x40 : 0x00
                packet.append(afFlags)
                for _ in 0..<(adaptationFieldLength - 1) {
                    packet.append(0xFF)
                }
            }
        }

        // Append payload after the adaptation field (if any).
        packet.append(payload)

        assert(packet.count == packetSize, "TS packet must be exactly 188 bytes; got \(packet.count)")

        // Buffer the TS packet
        tsBuffer.append(packet)

        // Flush when we have a complete 1316-byte chunk (7 TS packets)
        if tsBuffer.count >= tsChunkSize {
            try flushTSBuffer()
        }
    }
}
