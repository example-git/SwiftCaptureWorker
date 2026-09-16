import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import IOKit.graphics

enum SourceDiscovery {
    static func query(kind: SourceKind) throws -> SourceDiscoveryResponse {
        let videoSources: VideoSources?
        let audioSources: AudioSources?
        let webcamSources: [WebcamSource]?

        switch kind {
        case .video:
            videoSources = try VideoSources(
                displays: displays(),
                applications: applications()
            )
            audioSources = nil
            webcamSources = webcamDevices()
        case .audio:
            videoSources = nil
            audioSources = AudioSources(
                systemAudioSupported: {
                    if #available(macOS 13.0, *) {
                        return true
                    }
                    return false
                }(),
                inputDevices: inputDevices(),
                processes: processAudioSources()
            )
            webcamSources = nil
        case .all:
            videoSources = try VideoSources(
                displays: displays(),
                applications: applications()
            )
            audioSources = AudioSources(
                systemAudioSupported: {
                    if #available(macOS 13.0, *) {
                        return true
                    }
                    return false
                }(),
                inputDevices: inputDevices(),
                processes: processAudioSources()
            )
            webcamSources = webcamDevices()
        }

        return SourceDiscoveryResponse(video: videoSources, audio: audioSources, webcams: webcamSources)
    }

    static func displays() throws -> [DisplaySource] {
        let maxDisplays: UInt32 = 32
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        let status = CGGetOnlineDisplayList(maxDisplays, &displayIDs, &displayCount)
        guard status == .success else {
            throw WorkerError.captureFailed("Failed to query online displays.")
        }

        let primaryDisplayID = CGMainDisplayID()

        return displayIDs.prefix(Int(displayCount)).enumerated().map { index, displayID in
            DisplaySource(
                index: index + 1,
                displayID: displayID,
                electronSourceId: "screen:\(displayID):0",
                name: displayName(for: displayID),
                isPrimary: displayID == primaryDisplayID,
                frame: RectJSON(CGDisplayBounds(displayID)),
                scaleFactor: displayScaleFactor(for: displayID)
            )
        }
    }

    static func applications() throws -> [AppSource] {
        let running = NSWorkspace.shared.runningApplications

        return running.compactMap { app -> AppSource? in
            guard let bundleIdentifier = app.bundleIdentifier,
                  app.activationPolicy == .regular else {
                return nil
            }

            let windows = windowSources(for: app.processIdentifier)
            return AppSource(
                name: app.localizedName ?? bundleIdentifier,
                bundleIdentifier: bundleIdentifier,
                processID: app.processIdentifier,
                windows: windows
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func inputDevices() -> [AudioInputSource] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        )

        return discoverySession.devices.map {
            AudioInputSource(
                name: $0.localizedName,
                uniqueID: $0.uniqueID,
                modelID: $0.modelID,
                connected: $0.isConnected
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func processAudioSources() -> [ProcessAudioSource] {
        if #available(macOS 14.2, *) {
            return ProcessAudioTap.discoverProcessAudioSources()
        }
        return []
    }

    static func webcamDevices() -> [WebcamSource] {
        let discoverySession: AVCaptureDevice.DiscoverySession
        if #available(macOS 14.0, *) {
            discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: .video,
                position: .unspecified
            )
        } else {
            discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
                mediaType: .video,
                position: .unspecified
            )
        }

        return discoverySession.devices.map { device in
            // Deduplicate formats by unique (width, height, maxFPS) combos,
            // keeping only the best frame rate range for each resolution.
            var seenResolutions = Set<String>()
            var uniqueFormats: [WebcamFormat] = []

            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let w = Int(dims.width)
                let h = Int(dims.height)
                guard w >= 128 && h >= 128 else { continue }

                for range in format.videoSupportedFrameRateRanges {
                    let key = "\(w)x\(h)@\(Int(range.maxFrameRate))"
                    if seenResolutions.contains(key) { continue }
                    seenResolutions.insert(key)
                    uniqueFormats.append(WebcamFormat(
                        width: w,
                        height: h,
                        minFPS: range.minFrameRate,
                        maxFPS: range.maxFrameRate
                    ))
                }
            }

            // Sort: highest resolution first, then highest fps
            uniqueFormats.sort {
                if $0.width != $1.width { return $0.width > $1.width }
                if $0.height != $1.height { return $0.height > $1.height }
                return $0.maxFPS > $1.maxFPS
            }

            return WebcamSource(
                name: device.localizedName,
                uniqueID: device.uniqueID,
                modelID: device.modelID,
                connected: device.isConnected,
                formats: uniqueFormats
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func windowSources(for processID: pid_t) -> [WindowSource] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowList.compactMap { entry in
            guard let windowPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == processID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }

            let x = bounds["X"] as? Double ?? 0
            let y = bounds["Y"] as? Double ?? 0
            let width = bounds["Width"] as? Double ?? 0
            let height = bounds["Height"] as? Double ?? 0

            let wid = entry[kCGWindowNumber as String] as? UInt32 ?? 0
            return WindowSource(
                windowID: wid,
                electronSourceId: "window:\(wid):0",
                title: entry[kCGWindowName as String] as? String ?? "",
                frame: RectJSON(CGRect(x: x, y: y, width: width, height: height)),
                isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            )
        }
        .filter { $0.frame.width > 0 && $0.frame.height > 0 }
    }

    private static func displayName(for displayID: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }

        if let localizedName = screen?.localizedName, !localizedName.isEmpty {
            return localizedName
        }

        return fallbackDisplayName(for: displayID)
    }

    private static func fallbackDisplayName(for displayID: CGDirectDisplayID) -> String {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return "Display \(displayID)"
        }

        let width = mode.pixelWidth
        let height = mode.pixelHeight
        let refresh = Int(mode.refreshRate)
        let builtin = CGDisplayIsBuiltin(displayID) == 1 ? "Built-in" : "External"
        return "\(builtin) Display \(width)x\(height)@\(refresh)Hz"
    }

    private static func displayScaleFactor(for displayID: CGDirectDisplayID) -> Double {
        let pointWidth = CGDisplayBounds(displayID).width
        guard pointWidth > 0,
              let mode = CGDisplayCopyDisplayMode(displayID) else {
            return 1.0
        }

        return Double(mode.pixelWidth) / pointWidth
    }
}
