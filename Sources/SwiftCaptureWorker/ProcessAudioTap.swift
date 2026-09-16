import Foundation
import CoreAudio
import AudioToolbox
import AppKit

/// Taps the audio output of a specific process using `AudioHardwareCreateProcessTap`
/// (macOS 14.2+) and an aggregate device for I/O, then writes SCAP PCM packets via
/// the given `PacketStreamWriter`.
///
/// Lifecycle: `init` → `start()` → `stop()`.  `stop()` is idempotent and is also
/// called from `deinit`.
@available(macOS 14.2, *)
final class ProcessAudioTap: @unchecked Sendable {
    private struct RenderDebugSnapshot {
        var callbackCount: UInt64 = 0
        var callbacksWithPayload: UInt64 = 0
        var callbacksWithoutPayload: UInt64 = 0
        var lastBusIndex: UInt32 = 0
        var lastFrameCount: UInt32 = 0
        var lastRenderedBytes: Int = 0
        var lastPayloadBytes: Int = 0
        var lastBufferCount: UInt32 = 0
        var lastBuffer0Channels: UInt32 = 0
        var lastBuffer0Bytes: UInt32 = 0
        var lastBuffer0HasData: Bool = false
        var lastHostTime: UInt64 = 0
        var lastSampleTime: Float64 = 0
    }

    private static let maxFramesPerSlice: UInt32 = 2048

    private let writer: PacketStreamWriter
    private let ioQueue = DispatchQueue(label: "SwiftCapture.ProcessAudioTap", qos: .userInitiated)
    private let aggregateSettleTimeoutSeconds: Double = 2.0
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var aggregateDeviceUID: String?
    private var tapUID: String?
    private var audioUnit: AudioUnit?
    private var tapASBD: AudioStreamBasicDescription?
    private var clientASBD: AudioStreamBasicDescription?
    private var captureBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var interleavedBuffer: UnsafeMutablePointer<Float>?
    private var configSent = false   // written once from the HAL thread; harmless race
    private let debugBufferSizes = ProcessInfo.processInfo.environment["SCAP_DEBUG_PROCESS_AUDIO_TAP"] == "1"
    private var renderCallbackCount: UInt64 = 0
    private var renderDebugSnapshot = RenderDebugSnapshot()

    // MARK: - Init

    /// - parameter processAudioObjectIDs: One or more CoreAudio process AudioObjectIDs
    ///   to include in the stereo mixdown tap.  Electron-based apps split audio
    ///   across several helper processes; pass all of them here.
    init(processAudioObjectIDs: [AudioObjectID], writer: PacketStreamWriter) throws {
        precondition(!processAudioObjectIDs.isEmpty, "At least one process AudioObjectID required")
        self.writer = writer
        trace("init: processAudioObjectIDs=\(processAudioObjectIDs)")

        // Mirror AudioCap's public reference setup as closely as possible:
        // create a stereo mixdown tap, assign a stable UUID up front, then
        // publish it through a private aggregate device anchored to the current
        // system output device.
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: processAudioObjectIDs)
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted
        tapDesc.name = "SwiftCapture-ProcessTap"
        trace("init: tapDesc uuid=\(tapDesc.uuid.uuidString) private=\(tapDesc.isPrivate) mute=\(tapDesc.muteBehavior.rawValue) name=\(tapDesc.name)")

        var tapObjectID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapObjectID)
        trace("init: AudioHardwareCreateProcessTap status=\(tapStatus) tapObjectID=\(tapObjectID)")
        guard tapStatus == noErr else {
            throw WorkerError.captureFailed("AudioHardwareCreateProcessTap failed (OSStatus \(tapStatus)).")
        }
        self.tapID = tapObjectID

        // 2. Read the tap's audio format so we can emit a CONFIG packet.
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioObjectGetPropertyData(tapObjectID, &fmtAddr, 0, nil, &fmtSize, &asbd)
        trace("init: tap format status=\(fmtStatus) size=\(fmtSize) asbd=\(Self.describe(asbd))")
        guard fmtStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapObjectID)
            throw WorkerError.captureFailed("Failed to read tap format (OSStatus \(fmtStatus)).")
        }
        self.tapASBD = asbd

        // Pick an aggregatable clock device.  Bluetooth and AirPlay devices cannot
        // participate in Core Audio aggregate devices; using one would leave the
        // aggregate with 0 output streams, stalling the I/O clock.  Prefer
        // built-in → USB/Thunderbolt → FireWire → PCI, then fall back to the
        // default system output if nothing better is found.
        let defaultSystemOutputDeviceID = try Self.defaultSystemOutputDeviceID()
        let subDeviceID = Self.aggrelatableOutputDeviceID(preferring: defaultSystemOutputDeviceID)
                          ?? defaultSystemOutputDeviceID
        let defaultSystemOutputDeviceUID = try Self.deviceUID(for: subDeviceID)
        trace("init: subDeviceID=\(subDeviceID) uid=\(defaultSystemOutputDeviceUID)")

        // 3. Create a private aggregate device that wraps the tap and is anchored to
        //    the current system output device, matching AudioCap's reference shape.
        let tapUID = try Self.tapUID(for: tapObjectID)
        self.tapUID = tapUID
        trace("init: runtime tapUID=\(tapUID)")

        let aggUID = "SwiftCaptureTap-\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceUIDKey:           aggUID,
            kAudioAggregateDeviceNameKey:          "SwiftCapture Process Tap",
            kAudioAggregateDeviceIsPrivateKey:     true,
            kAudioAggregateDeviceIsStackedKey:     false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: defaultSystemOutputDeviceUID]],
            kAudioAggregateDeviceMainSubDeviceKey: defaultSystemOutputDeviceUID,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID
            ]] as [[String: Any]],
            kAudioAggregateDeviceTapAutoStartKey:  true,
        ]
        trace("init: aggregate descriptor uid=\(aggUID) desc=\(aggDesc)")
        var aggID: AudioDeviceID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        trace("init: AudioHardwareCreateAggregateDevice status=\(aggStatus) aggregateDeviceID=\(aggID)")
        guard aggStatus == noErr, aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapObjectID)
            throw WorkerError.captureFailed("AudioHardwareCreateAggregateDevice failed (OSStatus \(aggStatus)).")
        }
        self.aggregateDeviceID = aggID
        self.aggregateDeviceUID = aggUID

        try Self.waitForAggregateDeviceToSettle(aggID, timeoutSeconds: aggregateSettleTimeoutSeconds)
        try Self.configureAggregateDeviceSampleRate(aggID, to: asbd.mSampleRate)
        trace("init: aggregate settled and sample rate configured to \(asbd.mSampleRate)")
    }

    // MARK: - Start / Stop

    func start() throws {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            throw WorkerError.captureFailed("Process audio tap is not initialised.")
        }
        trace("start: aggregateDeviceID=\(aggregateDeviceID) aggregateUID=\(aggregateDeviceUID ?? "(nil)") tapID=\(tapID) tapUID=\(tapUID ?? "(nil)")")

        try prepareAudioUnit()

        guard let audioUnit else {
            throw WorkerError.captureFailed("Process audio tap audio unit is not initialised.")
        }

        let startStatus = AudioOutputUnitStart(audioUnit)
        trace("start: AudioOutputUnitStart status=\(startStatus)")
        guard startStatus == noErr else {
            disposeAudioUnit()
            throw WorkerError.captureFailed("AudioOutputUnitStart on tap aggregate device failed (OSStatus \(startStatus)).")
        }
        trace("start: audio unit started successfully")
    }

    func stop() {
        trace("stop: begin aggregateDeviceID=\(aggregateDeviceID) tapID=\(tapID) audioUnit=\(audioUnit != nil)")
        flushRenderDebugSnapshot()
        disposeAudioUnit()
        writer.writeEndOfStream()
        writer.close()
        if aggregateDeviceID != kAudioObjectUnknown {
            trace("stop: destroying aggregate device id=\(aggregateDeviceID)")
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            trace("stop: destroying process tap id=\(tapID)")
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        tapUID = nil
        trace("stop: complete")
    }

    deinit { stop() }

    // MARK: - Process resolution

    /// Resolves a single PID to its CoreAudio process AudioObjectID.
    static func resolveProcessAudioObjectID(pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        var result: AudioObjectID = kAudioObjectUnknown
        var resultSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var qualifier  = pid
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &qualifier,
            &resultSize, &result)
        guard status == noErr, result != kAudioObjectUnknown else { return nil }
        return result
    }

    @available(macOS 14.2, *)
    static func discoverProcessAudioSources() -> [ProcessAudioSource] {
        let descriptors = enumerateProcessAudioObjectDescriptors()
        guard !descriptors.isEmpty else { return [] }

        struct Group {
            var objectIDs = Set<AudioObjectID>()
            var bundleIdentifiers = Set<String>()
            var processIDs = Set<Int32>()
            var preferredApp: NSRunningApplication?
        }

        let runningApps = NSWorkspace.shared.runningApplications
            .filter { app in
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return false }
                return !app.isTerminated
            }

        var groups: [String: Group] = [:]
        for descriptor in descriptors {
            let familyBundleID = canonicalBundleFamily(for: descriptor.bundleIdentifier)
            var group = groups[familyBundleID] ?? Group()
            group.objectIDs.insert(descriptor.objectID)
            group.bundleIdentifiers.insert(descriptor.bundleIdentifier)
            groups[familyBundleID] = group
        }

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            let familyBundleID = canonicalBundleFamily(for: bundleID)
            guard var group = groups[familyBundleID] else { continue }
            group.processIDs.insert(app.processIdentifier)
            group.bundleIdentifiers.insert(bundleID)
            if shouldPrefer(app, over: group.preferredApp, forFamilyBundleID: familyBundleID) {
                group.preferredApp = app
            }
            groups[familyBundleID] = group
        }

        return groups.map { familyBundleID, group in
            let preferredApp = group.preferredApp
            let sortedProcessIDs = group.processIDs.sorted()
            let trimmedName = preferredApp?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmedName?.isEmpty == false ? trimmedName : nil) ?? familyBundleID
            let representativePID = preferredApp?.processIdentifier ?? sortedProcessIDs.first
            return ProcessAudioSource(
                name: name,
                bundleIdentifier: familyBundleID,
                processID: representativePID,
                processIDs: sortedProcessIDs,
                bundleIdentifiers: group.bundleIdentifiers.sorted(),
                processObjectCount: group.objectIDs.count
            )
        }
        .sorted { left, right in
            left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    /// Returns every CoreAudio process AudioObjectID whose bundle ID starts with
    /// `bundleIDPrefix`.  Electron-based apps split audio across a main process
    /// (e.g. `com.co.app`) and helper subprocesses (`com.co.app.helper`,
    /// `com.co.app.helper.renderer`, …).  Passing the main bundle-ID prefix here
    /// catches all of them in one tap.
    static func resolveAllProcessAudioObjectIDs(bundleIDPrefixes prefixes: [String]) -> [AudioObjectID] {
        let normalizedPrefixes = Array(Set(prefixes.map { canonicalBundleFamily(for: $0).lowercased() })).sorted()
        guard !normalizedPrefixes.isEmpty else { return [] }

        let matches = enumerateProcessAudioObjectDescriptors().compactMap { descriptor -> AudioObjectID? in
            let normalizedBundleID = canonicalBundleFamily(for: descriptor.bundleIdentifier).lowercased()
            if normalizedPrefixes.contains(where: { prefix in
                normalizedBundleID == prefix || normalizedBundleID.hasPrefix(prefix + ".")
            }) {
                return descriptor.objectID
            }
            return nil
        }
        return Array(Set(matches))
    }

    private static func defaultSystemOutputDeviceID() throws -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        traceStatic("defaultSystemOutputDeviceID: status=\(status) deviceID=\(deviceID)")
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw WorkerError.captureFailed("Failed to resolve default system output device (OSStatus \(status)).")
        }
        return deviceID
    }

    /// Returns the best output device ID to use as the aggregate clock sub-device.
    /// Bluetooth and AirPlay cannot participate in aggregate devices and will leave
    /// the aggregate with 0 output streams (stalling the I/O clock).  We prefer
    /// built-in audio, then USB/Thunderbolt, then the caller-supplied preferred device.
    private static func aggrelatableOutputDeviceID(preferring preferred: AudioDeviceID) -> AudioDeviceID? {
        let preferredTransports: [UInt32] = [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypePCI,
        ]

        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &listSize) == noErr,
              listSize > 0 else { return nil }

        let count = Int(listSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &listSize, &ids) == noErr
        else { return nil }

        // Keep only devices that have at least one output stream.
        func hasOutputStreams(_ devID: AudioDeviceID) -> Bool {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope:    kAudioDevicePropertyScopeOutput,
                mElement:  kAudioObjectPropertyElementMain)
            var sz: UInt32 = 0
            return AudioObjectGetPropertyDataSize(devID, &addr, 0, nil, &sz) == noErr && sz > 0
        }

        func transportType(_ devID: AudioDeviceID) -> UInt32 {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain)
            var t: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(devID, &addr, 0, nil, &sz, &t)
            return t
        }

        // Preferred: candidate that matches the caller's device AND has an aggregatable transport.
        let preferredTransport = transportType(preferred)
        if preferredTransports.contains(preferredTransport), hasOutputStreams(preferred) {
            traceStatic("aggrelatableOutputDeviceID: preferred device \(preferred) is already aggregatable (transport=\(preferredTransport))")
            return preferred
        }

        // Search for the best alternative among all devices.
        for transport in preferredTransports {
            for devID in ids where devID != kAudioObjectUnknown {
                if transportType(devID) == transport, hasOutputStreams(devID) {
                    traceStatic("aggrelatableOutputDeviceID: chose devID=\(devID) transport=\(transport) instead of preferred=\(preferred)")
                    return devID
                }
            }
        }

        traceStatic("aggrelatableOutputDeviceID: no aggregatable device found, will fall back to preferred=\(preferred)")
        return nil
    }

    private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &ref)
        traceStatic("deviceUID: deviceID=\(deviceID) status=\(status)")
        guard status == noErr, let uid = ref?.takeRetainedValue() as String? else {
            throw WorkerError.captureFailed("Failed to resolve default output device UID (OSStatus \(status)).")
        }
        traceStatic("deviceUID: deviceID=\(deviceID) uid=\(uid)")
        return uid
    }

    private static func tapUID(for tapID: AudioObjectID) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &ref)
        traceStatic("tapUID: tapID=\(tapID) status=\(status)")
        guard status == noErr, let uid = ref?.takeRetainedValue() as String? else {
            throw WorkerError.captureFailed("Failed to resolve process tap UID (OSStatus \(status)).")
        }
        traceStatic("tapUID: tapID=\(tapID) uid=\(uid)")
        return uid
    }

    /// Resolves an app name (or partial bundle ID) to ALL CoreAudio process
    /// AudioObjectIDs that belong to that app family.
    ///
    /// Strategy: collect every running app whose localized name or bundle ID
    /// matches the requested app name, then include each bundle family so helper
    /// apps like `*.helper` and `*.helper.renderer` are kept in the tap set.
    static func resolveAllProcessAudioObjectIDs(appName: String) -> [AudioObjectID] {
        let bundleIDs = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard let bundleID = app.bundleIdentifier else { return nil }
            let nameMatches = app.localizedName?.localizedCaseInsensitiveContains(appName) ?? false
            let bundleMatches = bundleID.localizedCaseInsensitiveContains(appName)
            return (nameMatches || bundleMatches) ? bundleID : nil
        }
        guard !bundleIDs.isEmpty else { return [] }

        let prefixes = Array(Set(bundleIDs.flatMap { bundleID -> [String] in
            var results = [bundleID]
            if let helperRange = bundleID.range(of: ".helper", options: [.caseInsensitive, .backwards]) {
                results.append(String(bundleID[..<helperRange.lowerBound]))
            }
            return results
        }))
        let results = resolveAllProcessAudioObjectIDs(bundleIDPrefixes: prefixes)
        return results
    }

    static func resolveAllProcessAudioObjectIDs(bundleIDPrefix prefix: String) -> [AudioObjectID] {
        resolveAllProcessAudioObjectIDs(bundleIDPrefixes: [prefix])
    }

    @available(macOS 14.2, *)
    private struct ProcessAudioObjectDescriptor {
        let objectID: AudioObjectID
        let bundleIdentifier: String
    }

    @available(macOS 14.2, *)
    private static func enumerateProcessAudioObjectDescriptors() -> [ProcessAudioObjectDescriptor] {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr,
            0,
            nil,
            &listSize
        ) == noErr, listSize > 0 else {
            return []
        }

        let count = Int(listSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr,
            0,
            nil,
            &listSize,
            &ids
        ) == noErr else {
            return []
        }

        return ids.compactMap { objectID -> ProcessAudioObjectDescriptor? in
            let bundleIdentifier = bundleIdentifier(forProcessObjectID: objectID)
            guard !bundleIdentifier.isEmpty else { return nil }
            return ProcessAudioObjectDescriptor(objectID: objectID, bundleIdentifier: bundleIdentifier)
        }
    }

    @available(macOS 14.2, *)
    private static func bundleIdentifier(forProcessObjectID objectID: AudioObjectID) -> String {
        var bidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>? = nil
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &bidAddr, 0, nil, &sz, &ref) == noErr,
              let bundleID = ref?.takeRetainedValue() as String? else {
            return ""
        }
        return bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalBundleFamily(for bundleIdentifier: String) -> String {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let helperRange = trimmed.range(of: ".helper", options: [.caseInsensitive, .backwards]) {
            return String(trimmed[..<helperRange.lowerBound])
        }
        return trimmed
    }

    private static func shouldPrefer(
        _ candidate: NSRunningApplication,
        over current: NSRunningApplication?,
        forFamilyBundleID familyBundleID: String
    ) -> Bool {
        guard let current else { return true }
        let candidateBundleID = candidate.bundleIdentifier ?? ""
        let currentBundleID = current.bundleIdentifier ?? ""
        let candidateScore = appPreferenceScore(candidate, familyBundleID: familyBundleID, bundleIdentifier: candidateBundleID)
        let currentScore = appPreferenceScore(current, familyBundleID: familyBundleID, bundleIdentifier: currentBundleID)
        if candidateScore != currentScore {
            return candidateScore > currentScore
        }
        let candidateName = candidate.localizedName ?? candidateBundleID
        let currentName = current.localizedName ?? currentBundleID
        return candidateName.localizedCaseInsensitiveCompare(currentName) == .orderedAscending
    }

    private static func appPreferenceScore(
        _ app: NSRunningApplication,
        familyBundleID: String,
        bundleIdentifier: String
    ) -> Int {
        var score = 0
        if bundleIdentifier.caseInsensitiveCompare(familyBundleID) == .orderedSame {
            score += 8
        } else if canonicalBundleFamily(for: bundleIdentifier).caseInsensitiveCompare(familyBundleID) == .orderedSame {
            score += 4
        }
        if app.activationPolicy == .regular {
            score += 2
        }
        if let localizedName = app.localizedName, !localizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 1
        }
        return score
    }

    // MARK: - AudioUnit capture

    private func prepareAudioUnit() throws {
        guard audioUnit == nil else { return }
        guard let tapASBD else {
            throw WorkerError.captureFailed("Tap stream format unavailable before AudioUnit setup.")
        }
        trace("prepareAudioUnit: begin tapASBD=\(Self.describe(tapASBD)) aggregateDeviceID=\(aggregateDeviceID)")

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw WorkerError.captureFailed("Unable to find HAL output AudioUnit component.")
        }
        trace("prepareAudioUnit: found HAL output AudioComponent")

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        trace("prepareAudioUnit: AudioComponentInstanceNew status=\(status) unitCreated=\(unit != nil)")
        guard status == noErr, let unit else {
            throw WorkerError.captureFailed("AudioComponentInstanceNew failed (OSStatus \(status)).")
        }

        do {
            // Bind the device FIRST — CurrentDevice must be set before input IO on
            // bus 1 is enabled.  Output IO is kept enabled (default) so the AUHAL
            // registers an output I/O proc that drives the private aggregate device's
            // clock; the tap is clock-slaved to that output stream.  We output silence
            // (ioData zeroed in the callback) so there is no audible effect.
            var deviceID = aggregateDeviceID
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            trace("prepareAudioUnit: set current device status=\(status) deviceID=\(deviceID)")
            guard status == noErr else {
                throw WorkerError.captureFailed("Failed to bind AudioUnit to aggregate device (OSStatus \(status)).")
            }

            // Enable input IO on bus 1 after the device is bound.
            try Self.setAudioUnitProperty(
                unit,
                selector: kAudioOutputUnitProperty_EnableIO,
                scope: kAudioUnitScope_Input,
                element: 1,
                value: UInt32(1)
            )
            trace("prepareAudioUnit: enabled input IO on bus 1")
            trace("prepareAudioUnit: hasIO input[1]=\(try Self.audioUnitHasIO(unit, scope: kAudioUnitScope_Input, element: 1)) output[0]=\(try Self.audioUnitHasIO(unit, scope: kAudioUnitScope_Output, element: 0))")

            var clientFormat = tapASBD
            clientFormat.mFormatID = kAudioFormatLinearPCM
            clientFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            clientFormat.mFramesPerPacket = 1
            clientFormat.mBitsPerChannel = UInt32(MemoryLayout<Float>.size * 8)
            clientFormat.mChannelsPerFrame = max(clientFormat.mChannelsPerFrame, 1)
            clientFormat.mBytesPerFrame = UInt32(MemoryLayout<Float>.size) * clientFormat.mChannelsPerFrame
            clientFormat.mBytesPerPacket = clientFormat.mBytesPerFrame

            status = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &clientFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            trace("prepareAudioUnit: set stream format status=\(status) clientASBD=\(Self.describe(clientFormat))")
            guard status == noErr else {
                throw WorkerError.captureFailed("Failed to set AudioUnit stream format (OSStatus \(status)).")
            }

            try Self.setAudioUnitProperty(
                unit,
                selector: kAudioUnitProperty_MaximumFramesPerSlice,
                scope: kAudioUnitScope_Global,
                element: 0,
                value: Self.maxFramesPerSlice
            )
            trace("prepareAudioUnit: set maxFramesPerSlice=\(Self.maxFramesPerSlice)")

            var callback = AURenderCallbackStruct(
                inputProc: Self.tapRenderCallback,
                inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            trace("prepareAudioUnit: set input callback status=\(status)")
            guard status == noErr else {
                throw WorkerError.captureFailed("Failed to install AudioUnit input callback (OSStatus \(status)).")
            }

            status = AudioUnitInitialize(unit)
            trace("prepareAudioUnit: AudioUnitInitialize status=\(status)")
            guard status == noErr else {
                throw WorkerError.captureFailed("AudioUnitInitialize failed (OSStatus \(status)).")
            }

            try allocateCaptureBuffers(for: clientFormat)

            self.audioUnit = unit
            self.clientASBD = clientFormat
            trace("prepareAudioUnit: complete")
        } catch {
            trace("prepareAudioUnit: failed error=\(error)")
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func allocateCaptureBuffers(for format: AudioStreamBasicDescription) throws {
        let channelCount = max(Int(format.mChannelsPerFrame), 1)
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bufferCount = isNonInterleaved ? channelCount : 1
        let ablSize = MemoryLayout<AudioBufferList>.size + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        trace("allocateCaptureBuffers: channelCount=\(channelCount) isNonInterleaved=\(isNonInterleaved) bufferCount=\(bufferCount) ablSize=\(ablSize)")
        guard let rawABL = malloc(ablSize) else {
            throw WorkerError.captureFailed("Failed to allocate tap capture buffer list.")
        }
        memset(rawABL, 0, ablSize)
        let bufferList = rawABL.assumingMemoryBound(to: AudioBufferList.self)
        bufferList.pointee.mNumberBuffers = UInt32(bufferCount)

        let bytesPerSample = MemoryLayout<Float>.size
        let perBufferByteCount = isNonInterleaved
            ? Int(Self.maxFramesPerSlice) * bytesPerSample
            : Int(Self.maxFramesPerSlice) * channelCount * bytesPerSample
        trace("allocateCaptureBuffers: perBufferByteCount=\(perBufferByteCount) bytesPerSample=\(bytesPerSample)")

        let firstBufferPtr = withUnsafeMutablePointer(to: &bufferList.pointee.mBuffers) { $0 }
        var allocationFailed = false
        for idx in 0..<bufferCount {
            let audioBuffer = firstBufferPtr.advanced(by: idx)
            audioBuffer.pointee.mNumberChannels = isNonInterleaved ? 1 : UInt32(channelCount)
            audioBuffer.pointee.mDataByteSize = UInt32(perBufferByteCount)
            audioBuffer.pointee.mData = malloc(perBufferByteCount)
            if audioBuffer.pointee.mData == nil {
                allocationFailed = true
                break
            }
            memset(audioBuffer.pointee.mData, 0, perBufferByteCount)
            trace("allocateCaptureBuffers: buffer[\(idx)] channels=\(audioBuffer.pointee.mNumberChannels) bytes=\(audioBuffer.pointee.mDataByteSize)")
        }
        if allocationFailed {
            for idx in 0..<bufferCount {
                let audioBuffer = firstBufferPtr.advanced(by: idx)
                if let data = audioBuffer.pointee.mData {
                    free(data)
                    audioBuffer.pointee.mData = nil
                }
            }
        }
        if allocationFailed {
            free(rawABL)
            throw WorkerError.captureFailed("Failed to allocate tap channel buffer.")
        }

        guard let interleavedBuffer = malloc(Int(Self.maxFramesPerSlice) * channelCount * bytesPerSample)?
            .assumingMemoryBound(to: Float.self) else {
            for idx in 0..<bufferCount {
                let audioBuffer = firstBufferPtr.advanced(by: idx)
                if let data = audioBuffer.pointee.mData {
                    free(data)
                    audioBuffer.pointee.mData = nil
                }
            }
            free(rawABL)
            throw WorkerError.captureFailed("Failed to allocate interleaved tap buffer.")
        }

        self.captureBufferList = bufferList
        self.interleavedBuffer = interleavedBuffer
        trace("allocateCaptureBuffers: complete interleavedBytes=\(Int(Self.maxFramesPerSlice) * channelCount * bytesPerSample)")
    }

    private func disposeAudioUnit() {
        trace("disposeAudioUnit: begin audioUnit=\(audioUnit != nil) captureBufferList=\(captureBufferList != nil) interleavedBuffer=\(interleavedBuffer != nil)")
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
        }

        if let captureBufferList {
            let bufferCount = Int(captureBufferList.pointee.mNumberBuffers)
            withUnsafeMutablePointer(to: &captureBufferList.pointee.mBuffers) { firstBufferPtr in
                for idx in 0..<bufferCount {
                    let audioBuffer = firstBufferPtr.advanced(by: idx)
                    if let data = audioBuffer.pointee.mData {
                        free(data)
                        audioBuffer.pointee.mData = nil
                    }
                }
            }
            free(captureBufferList)
            self.captureBufferList = nil
        }

        if let interleavedBuffer {
            free(interleavedBuffer)
            self.interleavedBuffer = nil
        }

        self.clientASBD = nil
        trace("disposeAudioUnit: complete")
    }

    private func renderTap(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busIndex: UInt32,
        frameCount: UInt32,
        outputData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        // outputData is NULL for kAudioOutputUnitProperty_SetInputCallback; the
        // output side of the AUHAL runs independently (default silence) to keep
        // the aggregate device's I/O clock alive without us needing to fill it.

        guard let audioUnit, let captureBufferList, let interleavedBuffer, let clientASBD else { return noErr }

        let clampedFrameCount = min(frameCount, Self.maxFramesPerSlice)
        renderCallbackCount += 1
        renderDebugSnapshot.callbackCount = renderCallbackCount
        renderDebugSnapshot.lastBusIndex = busIndex
        renderDebugSnapshot.lastFrameCount = clampedFrameCount
        renderDebugSnapshot.lastHostTime = timeStamp.pointee.mHostTime
        renderDebugSnapshot.lastSampleTime = timeStamp.pointee.mSampleTime
        let renderStatus = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            timeStamp,
            1,
            clampedFrameCount,
            captureBufferList
        )
        guard renderStatus == noErr else { return renderStatus }

        let renderedBytes = Self.totalBufferByteCount(UnsafePointer(captureBufferList))
        renderDebugSnapshot.lastRenderedBytes = renderedBytes
        renderDebugSnapshot.lastBufferCount = captureBufferList.pointee.mNumberBuffers
        if captureBufferList.pointee.mNumberBuffers > 0 {
            let firstBuffer = withUnsafePointer(to: captureBufferList.pointee.mBuffers) { $0.pointee }
            renderDebugSnapshot.lastBuffer0Channels = firstBuffer.mNumberChannels
            renderDebugSnapshot.lastBuffer0Bytes = firstBuffer.mDataByteSize
            renderDebugSnapshot.lastBuffer0HasData = firstBuffer.mData != nil
        } else {
            renderDebugSnapshot.lastBuffer0Channels = 0
            renderDebugSnapshot.lastBuffer0Bytes = 0
            renderDebugSnapshot.lastBuffer0HasData = false
        }

        let payload = Self.extractPCMFromRenderedBuffer(
            captureBufferList: captureBufferList,
            interleavedBuffer: interleavedBuffer,
            frameCount: Int(clampedFrameCount),
            asbd: clientASBD
        )
        renderDebugSnapshot.lastPayloadBytes = payload.count
        if payload.isEmpty {
            renderDebugSnapshot.callbacksWithoutPayload += 1
        } else {
            renderDebugSnapshot.callbacksWithPayload += 1
        }
        guard !payload.isEmpty else { return noErr }

        if !configSent {
            configSent = true
            let fmt   = Self.gstreamerFormat(from: clientASBD) ?? "F32LE"
            let rate  = Int(clientASBD.mSampleRate)
            let ch    = Int(clientASBD.mChannelsPerFrame)
            let caps  = "audio/x-raw,format=\(fmt),layout=interleaved,rate=\(rate),channels=\(ch)"
            try? writer.writeConfiguration(AudioStreamConfiguration(
                codec:           "lpcm",
                sampleRate:      clientASBD.mSampleRate,
                channels:        clientASBD.mChannelsPerFrame,
                bitsPerChannel:  clientASBD.mBitsPerChannel,
                bytesPerFrame:   clientASBD.mBytesPerFrame,
                framesPerPacket: clientASBD.mFramesPerPacket,
                formatFlags:     numericCast(clientASBD.mFormatFlags),
                gstreamerCaps:   caps,
                isInterleaved:   true
            ))
        }

        // mHostTime is 0 when the HAL hasn't provided a valid timestamp yet.
        // In that case fall back to wall-clock monotonic time so the downstream
        // PTS never regresses to zero mid-stream.
        let hostTime = timeStamp.pointee.mHostTime
        let pts: UInt64
        if hostTime != 0 {
            pts = AudioConvertHostTimeToNanos(hostTime)
        } else {
            var ts = timespec()
            clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
            pts = UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
        }
        try? writer.writeSample(payload, ptsNanoseconds: pts)
        return noErr
    }

    private static let tapRenderCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
        let tap = Unmanaged<ProcessAudioTap>.fromOpaque(inRefCon).takeUnretainedValue()
        return tap.renderTap(
            ioActionFlags: ioActionFlags,
            timeStamp: inTimeStamp,
            busIndex: inBusNumber,
            frameCount: inNumberFrames,
            outputData: ioData
        )
    }

    private static func setAudioUnitProperty<T>(
        _ audioUnit: AudioUnit,
        selector: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        value: T
    ) throws {
        var mutableValue = value
        let status = AudioUnitSetProperty(
            audioUnit,
            selector,
            scope,
            element,
            &mutableValue,
            UInt32(MemoryLayout<T>.size)
        )
        guard status == noErr else {
            throw WorkerError.captureFailed("AudioUnitSetProperty(\(selector)) failed (OSStatus \(status)).")
        }
    }

    private static func audioUnitHasIO(
        _ audioUnit: AudioUnit,
        scope: AudioUnitScope,
        element: AudioUnitElement
    ) throws -> Bool {
        var hasIO: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_HasIO,
            scope,
            element,
            &hasIO,
            &size
        )
        guard status == noErr else {
            throw WorkerError.captureFailed("AudioUnitGetProperty(kAudioOutputUnitProperty_HasIO) failed (OSStatus \(status)).")
        }
        return hasIO != 0
    }

    // MARK: - PCM extraction

    /// Returns a stable `UnsafePointer<AudioBuffer>` to `mBuffers[0]` of a
    /// heap-allocated `AudioBufferList`.  Using `withUnsafePointer(to: abl.mBuffers)`
    /// returns a pointer to a STACK COPY that is immediately invalid after the closure
    /// returns; this helper computes the address through raw pointer arithmetic instead.
    ///
    /// On 64-bit platforms `AudioBufferList` is 24 bytes:
    ///   offset 0 — mNumberBuffers (UInt32, 4 bytes)
    ///   offset 4 — padding (4 bytes, to align the pointer inside AudioBuffer to 8 bytes)
    ///   offset 8 — mBuffers[0] (AudioBuffer, 16 bytes)
    /// So the correct stride to reach mBuffers[0] is
    /// MemoryLayout<AudioBufferList>.size − MemoryLayout<AudioBuffer>.size = 8.
    private static func audioBufferListFirstBuffer(_ abl: UnsafePointer<AudioBufferList>) -> UnsafePointer<AudioBuffer> {
        let offset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        return UnsafeRawPointer(abl)
            .advanced(by: offset)
            .assumingMemoryBound(to: AudioBuffer.self)
    }

    /// Copies audio from an AudioUnit-rendered `AudioBufferList` into a single
    /// interleaved `Data` blob, matching the old Objective-C `AppTapInput` path.
    private static func extractPCMFromRenderedBuffer(
        captureBufferList: UnsafeMutablePointer<AudioBufferList>,
        interleavedBuffer: UnsafeMutablePointer<Float>,
        frameCount: Int,
        asbd: AudioStreamBasicDescription
    ) -> Data {
        let bufferList = UnsafePointer(captureBufferList)
        let numBuffers = Int(bufferList.pointee.mNumberBuffers)
        guard numBuffers > 0, frameCount > 0 else { return Data() }

        let firstBufPtr = audioBufferListFirstBuffer(bufferList)

        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
        let bytesPerSample = MemoryLayout<Float>.size

        if !isNonInterleaved || numBuffers == 1 {
            let ab = firstBufPtr.pointee
            guard let ptr = ab.mData else { return Data() }
            let byteCount = frameCount * channelCount * bytesPerSample
            return Data(bytes: ptr, count: min(byteCount, Int(ab.mDataByteSize)))
        }

        for channel in 0..<numBuffers {
            let ab = firstBufPtr.advanced(by: channel).pointee
            guard let srcBase = ab.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frameCount {
                interleavedBuffer[frame * numBuffers + channel] = srcBase[frame]
            }
        }
        return Data(bytes: interleavedBuffer, count: frameCount * numBuffers * bytesPerSample)
    }

    private static func totalBufferByteCount(_ bufferList: UnsafePointer<AudioBufferList>) -> Int {
        let numBuffers = Int(bufferList.pointee.mNumberBuffers)
        guard numBuffers > 0 else { return 0 }
        let firstBufPtr = audioBufferListFirstBuffer(bufferList)
        var total = 0
        for idx in 0..<numBuffers {
            total += Int(firstBufPtr.advanced(by: idx).pointee.mDataByteSize)
        }
        return total
    }

    private static func waitForAggregateDeviceToSettle(
        _ deviceID: AudioDeviceID,
        timeoutSeconds: Double
    ) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        traceStatic("waitForAggregateDeviceToSettle: begin deviceID=\(deviceID) timeoutSeconds=\(timeoutSeconds)")
        while Date() < deadline {
            guard try isDeviceAlive(deviceID) else {
                throw WorkerError.captureFailed("Aggregate tap device disappeared before startup completed.")
            }

            let inputStreams = try streamCount(for: deviceID, scope: kAudioDevicePropertyScopeInput)
            let outputStreams = try streamCount(for: deviceID, scope: kAudioDevicePropertyScopeOutput)
            traceStatic("waitForAggregateDeviceToSettle: deviceID=\(deviceID) inputStreams=\(inputStreams) outputStreams=\(outputStreams)")
            // Require BOTH input (tap) AND output (sub-device) streams.
            // Settling on input alone means the output clock sub-device is not
            // yet registered; without it the AUHAL binding fails and the I/O
            // cycle never starts.
            if inputStreams > 0 && outputStreams > 0 {
                traceStatic("waitForAggregateDeviceToSettle: settled inputStreams=\(inputStreams) outputStreams=\(outputStreams)")
                return
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        let inputStreams = (try? streamCount(for: deviceID, scope: kAudioDevicePropertyScopeInput)) ?? -1
        let outputStreams = (try? streamCount(for: deviceID, scope: kAudioDevicePropertyScopeOutput)) ?? -1
        traceStatic("waitForAggregateDeviceToSettle: timeout inputStreams=\(inputStreams) outputStreams=\(outputStreams)")
        throw WorkerError.captureFailed(
            "Aggregate tap device did not settle before startup — need both input and output streams " +
            "(inputStreams=\(inputStreams), outputStreams=\(outputStreams))."
        )
    }

    private static func configureAggregateDeviceSampleRate(_ deviceID: AudioDeviceID, to sampleRate: Float64) throws {
        guard sampleRate > 0 else { return }
        var desiredSampleRate = sampleRate
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID,
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &desiredSampleRate
        )
        traceStatic("configureAggregateDeviceSampleRate: deviceID=\(deviceID) requested=\(sampleRate) status=\(status)")
        guard status == noErr else {
            throw WorkerError.captureFailed("Failed to set aggregate device sample rate (OSStatus \(status)).")
        }
    }

    private static func isDeviceAlive(_ deviceID: AudioDeviceID) throws -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &alive)
        traceStatic("isDeviceAlive: deviceID=\(deviceID) status=\(status) alive=\(alive)")
        guard status == noErr else {
            throw WorkerError.captureFailed("Failed to read aggregate device alive state (OSStatus \(status)).")
        }
        return alive != 0
    }

    private static func streamCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        traceStatic("streamCount: deviceID=\(deviceID) scope=\(scope) sizeStatus=\(sizeStatus) size=\(size)")
        guard sizeStatus == noErr else {
            throw WorkerError.captureFailed("Failed to query aggregate device streams (OSStatus \(sizeStatus)).")
        }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    // MARK: - GStreamer format token

    private static func gstreamerFormat(from asbd: AudioStreamBasicDescription) -> String? {
        let isBE  = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let end   = isBE ? "BE" : "LE"
        let bits  = asbd.mBitsPerChannel
        if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
            guard bits == 32 || bits == 64 else { return nil }
            return "F\(bits)\(end)"
        }
        let sign  = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 ? "S" : "U"
        guard [8, 16, 24, 32].contains(bits) else { return nil }
        return bits == 8 ? "\(sign)8" : "\(sign)\(bits)\(end)"
    }

    private func trace(_ message: String) {
        guard debugBufferSizes else { return }
        fputs("ProcessAudioTap trace: \(message)\n", stderr)
    }

    private static func traceStatic(_ message: String) {
        guard ProcessInfo.processInfo.environment["SCAP_DEBUG_PROCESS_AUDIO_TAP"] == "1" else { return }
        fputs("ProcessAudioTap trace: \(message)\n", stderr)
    }

    private static func describe(_ asbd: AudioStreamBasicDescription) -> String {
        "rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) bytes/frame=\(asbd.mBytesPerFrame) frames/packet=\(asbd.mFramesPerPacket) flags=0x\(String(asbd.mFormatFlags, radix: 16)) formatID=\(asbd.mFormatID)"
    }

    private func flushRenderDebugSnapshot() {
        guard debugBufferSizes else { return }
        let snapshot = renderDebugSnapshot
        trace(
            "render summary: callbacks=\(snapshot.callbackCount) withPayload=\(snapshot.callbacksWithPayload) " +
            "withoutPayload=\(snapshot.callbacksWithoutPayload) lastBus=\(snapshot.lastBusIndex) " +
            "lastFrames=\(snapshot.lastFrameCount) lastRenderedBytes=\(snapshot.lastRenderedBytes) " +
            "lastPayloadBytes=\(snapshot.lastPayloadBytes) lastBufferCount=\(snapshot.lastBufferCount) " +
            "buffer0Channels=\(snapshot.lastBuffer0Channels) buffer0Bytes=\(snapshot.lastBuffer0Bytes) " +
            "buffer0HasData=\(snapshot.lastBuffer0HasData) hostTime=\(snapshot.lastHostTime) " +
            "sampleTime=\(snapshot.lastSampleTime)"
        )
    }
}
