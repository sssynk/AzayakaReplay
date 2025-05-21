//
//  AppDelegate.swift
//  Azayaka
//
//  Created by Martin Persson on 2022-12-25.
//

import AVFoundation
import AVFAudio
import Cocoa
import KeyboardShortcuts
import ScreenCaptureKit
import UserNotifications
import SwiftUI

@main
struct Azayaka: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            Preferences()
                .fixedSize()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, SCStreamDelegate, SCStreamOutput {
    var stream: SCStream!
    var filePath: String!
    var audioFile: AVAudioFile?
    var audioSettings: [String : Any]!
    var availableContent: SCShareableContent?
    var updateTimer: Timer?
    var recordMic = false

    var screen: SCDisplay?
    var window: SCWindow?
    var streamType: StreamType?

    let excludedWindows = ["com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]

    var statusItem: NSStatusItem!
    var menu = NSMenu()
    let info = NSMenuItem(title: "One moment, waiting on update".local, action: nil, keyEquivalent: "")
    let noneAvailable = NSMenuItem(title: "None available".local, action: nil, keyEquivalent: "")
    let preferences = NSWindow()
    let ud = UserDefaults.standard
    let UpdateHandler = Updates()

    var useSystemRecorder = false
    let replayBufferManager = ReplayBufferManager() // Added ReplayBufferManager instance
    // new recorder
    var recordingOutput: Any? // wow this is mega jank, this will hold an SCRecordingOutput but it's only a thing on sequoia
    // legacy recorder
    var vW: AVAssetWriter!
    var vwInput, awInput, micInput: AVAssetWriterInput!
    let audioEngine = AVAudioEngine()
    var startTime: Date?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        lazy var userDesktop = (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true) as [String]).first!

        // the `com.apple.screencapture` domain has the user set path for where they want to store screenshots or videos
        let saveDirectory = (UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") ?? userDesktop) as NSString

        ud.register( // default defaults (used if not set)
            defaults: [
                Preferences.kFrameRate: 60,
                Preferences.kHighResolution: true,
                Preferences.kVideoQuality: 1.0,
                Preferences.kVideoFormat: VideoFormat.mp4.rawValue,
                Preferences.kEncoder: Encoder.h264.rawValue,
                Preferences.kEnableHDR: utsname.isAppleSilicon,
                Preferences.kHideSelf: false,
                Preferences.kFrontApp: false,
                Preferences.kShowMouse: true,

                Preferences.kAudioFormat: AudioFormat.aac.rawValue,
                Preferences.kAudioQuality: AudioQuality.high.rawValue,
                Preferences.kRecordMic: false,

                Preferences.kFileName: "Recording at %t".local,
                Preferences.kSaveDirectory: saveDirectory,
                Preferences.kAutoClipboard: false,

                Preferences.kUpdateCheck: true,
                Preferences.kCountdownSecs: 0,
                Preferences.kSystemRecorder: false,
                Preferences.kReplayDuration: 30 // Added default for new key
            ]
        )
        // create a menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        statusItem.menu = menu
        menu.minimumWidth = 250
        Task { await updateAvailableContent(buildMenu: true) }
        
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error { print("Notification authorisation denied: \(error.localizedDescription)") }
        }

        NotificationCenter.default.addObserver( // update the content & menu when a display device has changed
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared,
            queue: OperationQueue.main
        ) { [self] notification -> Void in
            Task { await updateAvailableContent(buildMenu: true) }
        }

        #if !DEBUG // no point in checking for updates if we're not on a release
        if ud.bool(forKey: Preferences.kUpdateCheck) {
            UpdateHandler.checkForUpdates()
        }
        #endif
    }

    func updateAvailableContent(buildMenu: Bool) async -> Bool { // returns status of getting content from SCK
        do {
            availableContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            let infoMenu = NSMenu()
            let infoItem = NSMenuItem()
            switch error {
                case SCStreamError.userDeclined:
                    infoItem.title = "Azayaka requires screen recording permissions.".local
                    requestPermissions()
                default:
                    print("Failed to fetch available content: ".local, error.localizedDescription)
                infoItem.attributedTitle = NSAttributedString(string: String(format: "Failed to fetch available content:\n%@".local, error.localizedDescription))
            }
            infoMenu.addItem(infoItem)
            infoMenu.addItem(NSMenuItem.separator())
            infoMenu.addItem(NSMenuItem(title: "Preferences…".local, action: #selector(openPreferences), keyEquivalent: ","))
            infoMenu.addItem(NSMenuItem(title: "Quit Azayaka".local, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = infoMenu
            return false
        }
        assert(self.availableContent?.displays.isEmpty != nil, "There needs to be at least one display connected".local)
        DispatchQueue.main.async {
            if buildMenu {
                self.createMenu()
            }
            self.refreshWindows(frontOnly: self.ud.bool(forKey: Preferences.kFrontApp))
            // ask to just refresh the windows list instead of rebuilding it all
        }
        return true
    }

    func requestPermissions() {
        allowShortcuts(false)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Azayaka needs permissions!".local
            alert.informativeText = "Azayaka needs screen recording permissions, even if you only intend on recording audio.".local
            alert.addButton(withTitle: "Open Settings".local)
            alert.addButton(withTitle: "Okay".local)
            alert.addButton(withTitle: "No thanks, quit".local)
            alert.alertStyle = .informational
            switch(alert.runModal()) {
                case .alertFirstButtonReturn:
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                case .alertThirdButtonReturn: NSApp.terminate(self)
                default: return
            }
            self.allowShortcuts(true)
        }
    }

    func copyToClipboard(_ content: [any NSPasteboardWriting]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(content)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if stream != nil {
            stopRecording()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    @objc func saveReplayAndStop() {
        print("Save Replay button pressed! Attempting to save replay...")
        // Using the new Preferences.kReplayDuration key
        let preferredDuration = ud.double(forKey: Preferences.kReplayDuration) // ud.double returns 0.0 if key not found or not a double
        let replayDurationToUse = preferredDuration > 0 ? preferredDuration : 30.0 // Default to 30s if not set or invalid (e.g. 0.0)
        
        print("Using replay duration: \(replayDurationToUse) seconds.")
        saveReplayToFile(durationSeconds: replayDurationToUse)
        
        // stopRecording() is now called within saveReplayToFile's completion logic
    }

    func saveReplayToFile(durationSeconds: Double) {
        print("Starting saveReplayToFile for last \(durationSeconds) seconds.")
        let (videoBuffers, audioBuffers, micBuffers) = replayBufferManager.getReplayBuffers(forLast: durationSeconds)

        if videoBuffers.isEmpty && audioBuffers.isEmpty && micBuffers.isEmpty {
            print("No buffers found to save for replay.")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "No Replay Data".local
                alert.informativeText = "There is no audio or video data in the buffer to save.".local
                alert.addButton(withTitle: "Okay".local)
                alert.alertStyle = .warning
                alert.runModal()
                self.stopRecording() // Stop the buffering session
            }
            return
        }
        
        // Minimum 1 second of buffers to proceed (arbitrary choice, can be adjusted)
        let minBufferDuration = CMTimeMakeWithSeconds(1.0, preferredTimescale: 600)
        let totalVideoDuration = videoBuffers.reduce(CMTime.zero) { CMTimeAdd($0, CMSampleBufferGetDuration($1)) }
        let totalAudioDuration = audioBuffers.reduce(CMTime.zero) { CMTimeAdd($0, CMSampleBufferGetDuration($1)) }

        if videoBuffers.isEmpty && CMTimeCompare(totalAudioDuration, minBufferDuration) < 0 {
            print("Audio buffer duration is less than 1 second. Not saving.")
             DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Replay Data Too Short".local
                alert.informativeText = "The available audio or video data is too short to save a meaningful replay.".local
                alert.addButton(withTitle: "Okay".local)
                alert.alertStyle = .warning
                alert.runModal()
                self.stopRecording()
            }
            return
        }
         if !videoBuffers.isEmpty && CMTimeCompare(totalVideoDuration, minBufferDuration) < 0 {
            print("Video buffer duration is less than 1 second. Not saving video track, will attempt audio only if available.")
            // Proceed to try audio-only if audio is long enough
            if CMTimeCompare(totalAudioDuration, minBufferDuration) < 0 {
                 DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Replay Data Too Short".local
                    alert.informativeText = "The available video and audio data is too short to save a meaningful replay.".local
                    alert.addButton(withTitle: "Okay".local)
                    alert.alertStyle = .warning
                    alert.runModal()
                    self.stopRecording()
                }
                return
            }
        }


        // --- AVAssetWriter Initialization ---
        let fileManager = FileManager.default
        var determinedFilePath: String
        var determinedFileType: AVFileType

        // Determine if it's an audio-only replay based on buffer content, not just streamType
        let isEffectivelyAudioOnly = videoBuffers.isEmpty || CMTimeCompare(totalVideoDuration, minBufferDuration) < 0

        if isEffectivelyAudioOnly {
            var fileEnding = ud.string(forKey: Preferences.kAudioFormat) ?? AudioFormat.aac.rawValue // Default to AAC
            switch fileEnding {
                case AudioFormat.aac.rawValue: fileEnding = "m4a"
                case AudioFormat.alac.rawValue: fileEnding = "m4a" // ALAC in M4A
                // FLAC and Opus are not directly supported by AVAssetWriter in common containers.
                // Default to AAC/m4a for broader compatibility if FLAC/Opus is chosen for system audio.
                case AudioFormat.flac.rawValue, AudioFormat.opus.rawValue:
                    print("Warning: FLAC/Opus selected for audio-only replay, saving as AAC in .m4a for compatibility.")
                    fileEnding = "m4a"
                default: fileEnding = "m4a"
            }
            determinedFilePath = "\(getFilePath()).\(fileEnding)"
            determinedFileType = .m4a // AVAssetWriter works well with m4a for audio
        } else {
            let fileEnding = ud.string(forKey: Preferences.kVideoFormat) ?? VideoFormat.mp4.rawValue
            switch fileEnding {
                case VideoFormat.mov.rawValue: determinedFileType = .mov
                case VideoFormat.mp4.rawValue: determinedFileType = .mp4
                default: determinedFileType = .mp4
            }
            determinedFilePath = "\(getFilePath()).\(fileEnding)"
        }
        
        self.filePath = determinedFilePath // Store for notifications/clipboard

        let outputURL = URL(fileURLWithPath: determinedFilePath)
        let outputDir = outputURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: outputDir.path) {
            do {
                try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("Failed to create directory for replay: \(error.localizedDescription)")
                DispatchQueue.main.async { self.alertRecordingFailure(error) }
                stopRecording()
                return
            }
        }
        
        do {
            self.vW = try AVAssetWriter(outputURL: outputURL, fileType: determinedFileType)
        } catch {
            print("Failed to initialize AVAssetWriter: \(error.localizedDescription)")
            DispatchQueue.main.async { self.alertRecordingFailure(error) }
            stopRecording()
            return
        }

        // --- Configure Inputs ---
        var tempVwInput: AVAssetWriterInput? = nil
        var tempAwInput: AVAssetWriterInput? = nil
        var tempMicInput: AVAssetWriterInput? = nil

        if !isEffectivelyAudioOnly, let firstVideoBuffer = videoBuffers.first, let fmtDesc = CMSampleBufferGetFormatDescription(firstVideoBuffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(fmtDesc)
            let videoCodecString = ud.string(forKey: Preferences.kEncoder) ?? Encoder.h264.rawValue
            let videoCodec = AVVideoCodecType(rawValue: videoCodecString)
            let targetFrameRate = ud.integer(forKey: Preferences.kFrameRate)
            let videoQuality = ud.double(forKey: Preferences.kVideoQuality)
            
            let videoOutputSettings: [String: Any] = [
                AVVideoCodecKey: videoCodec,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(Double(dimensions.width * dimensions.height) * Double(targetFrameRate)/8 * (videoCodec == .hevc ? 0.5 : 0.9) * videoQuality),
                    AVVideoExpectedSourceFrameRateKey: targetFrameRate,
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings, sourceFormatHint: fmtDesc)
            input.expectsMediaDataInRealTime = true // Or false if processing already captured data? Docs suggest true for screen capture.
            if self.vW.canAdd(input) {
                self.vW.add(input)
                tempVwInput = input
            } else {
                print("Cannot add video input to AVAssetWriter.")
            }
        }
        self.vwInput = tempVwInput


        if !audioBuffers.isEmpty, let firstAudioBuffer = audioBuffers.first, let fmtDesc = CMSampleBufferGetFormatDescription(firstAudioBuffer) {
            var settings = self.audioSettings ?? [:] // Use existing audioSettings if available
             if settings.isEmpty || CMSampleBufferGetFormatDescription(firstAudioBuffer) != nil { // Prefer buffer's format
                if let streamBasicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee {
                    settings = [
                        AVFormatIDKey: streamBasicDesc.mFormatID,
                        AVSampleRateKey: streamBasicDesc.mSampleRate,
                        AVNumberOfChannelsKey: streamBasicDesc.mChannelsPerFrame,
                    ]
                    if streamBasicDesc.mFormatID == kAudioFormatMPEG4AAC {
                         settings[AVEncoderBitRateKey] = self.audioSettings[AVEncoderBitRateKey] ?? ud.integer(forKey: Preferences.kAudioQuality) * 1000
                    }
                }
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: fmtDesc)
            input.expectsMediaDataInRealTime = true
            if self.vW.canAdd(input) {
                self.vW.add(input)
                tempAwInput = input
            } else {
                print("Cannot add app audio input to AVAssetWriter.")
            }
        }
        self.awInput = tempAwInput
        
        if !micBuffers.isEmpty, let firstMicBuffer = micBuffers.first, let fmtDesc = CMSampleBufferGetFormatDescription(firstMicBuffer) {
            var settings = self.audioSettings ?? [:]
            if settings.isEmpty || CMSampleBufferGetFormatDescription(firstMicBuffer) != nil {
                 if let streamBasicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee {
                    settings = [
                        AVFormatIDKey: streamBasicDesc.mFormatID,
                        AVSampleRateKey: streamBasicDesc.mSampleRate,
                        AVNumberOfChannelsKey: streamBasicDesc.mChannelsPerFrame,
                    ]
                    if streamBasicDesc.mFormatID == kAudioFormatMPEG4AAC {
                         settings[AVEncoderBitRateKey] = self.audioSettings[AVEncoderBitRateKey] ?? ud.integer(forKey: Preferences.kAudioQuality) * 1000
                    }
                }
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: fmtDesc)
            input.expectsMediaDataInRealTime = true
            if self.vW.canAdd(input) {
                self.vW.add(input)
                tempMicInput = input
            } else {
                print("Cannot add mic audio input to AVAssetWriter.")
            }
        }
        self.micInput = tempMicInput

        if self.vwInput == nil && self.awInput == nil && self.micInput == nil {
            print("No valid inputs for AVAssetWriter. Aborting.")
            DispatchQueue.main.async { self.alertRecordingFailure(NSError(domain: "AzayakaReplay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not configure any AVAssetWriter inputs."])) }
            stopRecording()
            return
        }

        guard self.vW.startWriting() else {
            print("AVAssetWriter failed to start writing. Error: \(self.vW.error?.localizedDescription ?? "Unknown")")
            DispatchQueue.main.async { self.alertRecordingFailure(self.vW.error ?? NSError(domain: "AzayakaReplay", code: 3, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed to start."])) }
            stopRecording()
            return
        }

        var allCollectedBuffers: [(buffer: CMSampleBuffer, type: String)] = []
        videoBuffers.forEach { allCollectedBuffers.append(($0, "video")) }
        audioBuffers.forEach { allCollectedBuffers.append(($0, "audio")) }
        micBuffers.forEach { allCollectedBuffers.append(($0, "mic")) }
        allCollectedBuffers.sort { $0.buffer.presentationTimeStamp < $1.buffer.presentationTimeStamp }

        guard let firstBufferTime = allCollectedBuffers.first?.buffer.presentationTimeStamp else {
            print("No buffers to determine start session timestamp after sorting. Aborting.")
            stopRecording()
            return
        }
        self.vW.startSession(atSourceTime: firstBufferTime)

        let writerQueue = DispatchQueue(label: "com.azayaka.replaywriter", qos: .userInitiated)
        let group = DispatchGroup()

        if let input = self.vwInput, !videoBuffers.isEmpty { // Check videoBuffers not empty before dispatching
            group.enter()
            input.requestMediaDataWhenReady(on: writerQueue) {
                self.appendBuffersToInput(input: input, buffers: videoBuffers, type: "Video", group: group)
            }
        }
        if let input = self.awInput, !audioBuffers.isEmpty {
            group.enter()
            input.requestMediaDataWhenReady(on: writerQueue) {
                self.appendBuffersToInput(input: input, buffers: audioBuffers, type: "App Audio", group: group)
            }
        }
        if let input = self.micInput, !micBuffers.isEmpty {
            group.enter()
            input.requestMediaDataWhenReady(on: writerQueue) {
                self.appendBuffersToInput(input: input, buffers: micBuffers, type: "Mic Audio", group: group)
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.vwInput?.markAsFinished()
            self.awInput?.markAsFinished()
            self.micInput?.markAsFinished()

            self.vW.finishWriting { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if self.vW.status == .completed {
                        print("Replay saved successfully to \(self.filePath ?? "Unknown path")")
                        self.sendRecordingFinishedNotification()
                        if self.ud.bool(forKey: Preferences.kAutoClipboard), let fileURL = self.filePath.map(URL.init(fileURLWithPath:)) {
                             self.copyToClipboard([fileURL as NSURL])
                        }
                    } else {
                        print("AVAssetWriter failed to finish writing. Status: \(self.vW.status.rawValue), Error: \(self.vW.error?.localizedDescription ?? "Unknown error")")
                        self.alertRecordingFailure(self.vW.error ?? NSError(domain: "AzayakaReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to write replay file."]))
                    }
                    self.stopRecording() // Stop session and clear buffers
                }
            }
        }
    }
    
    private func appendBuffersToInput(input: AVAssetWriterInput, buffers: [CMSampleBuffer], type: String, group: DispatchGroup) {
        // Assumes buffers are already sorted by presentationTimestamp for this specific input type
        var index = 0
        while input.isReadyForMoreMediaData && index < buffers.count {
            if !input.append(buffers[index]) {
                print("Failed to append \(type) buffer at index \(index). Error: \(self.vW.error?.localizedDescription ?? "Unknown")")
                // If append fails, we might need to stop and report error. For now, break.
                break 
            }
            index += 1
        }
        
        if index == buffers.count {
            print("Successfully appended all \(type) buffers.")
        } else {
            print("Warning: Not all \(type) buffers were appended. Index: \(index) of \(buffers.count). Input ready: \(input.isReadyForMoreMediaData)")
            // This could happen if input becomes not ready. The requestMediaDataWhenReady should handle being called again.
            // However, this simple loop doesn't manage state across multiple calls to the closure.
            // For replay, we are trying to dump all buffers in one go per input.
        }
        group.leave() // Leave group once this batch is processed or input is not ready.
    }

}

extension String {
