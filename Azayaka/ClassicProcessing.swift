//
//  ClassicProcessing.swift
//  Azayaka
//
//  Created by Martin Persson on 2024-08-08.
//

import ScreenCaptureKit

// This file contains code related to the "classic" recorder. It uses an
// AVAssetWriter instead of the ScreenCaptureKit recorder found in macOS Sequoia.
// System audio-only recording still uses this.

extension AppDelegate {
    func initClassicRecorder(conf: SCStreamConfiguration, encoder: AVVideoCodecType, filePath: String, fileType: AVFileType) {
        replayBufferManager.clearBuffers() // Clear buffers at the start of a new recording session
        startTime = nil

        // vW = try? AVAssetWriter.init(outputURL: URL(fileURLWithPath: filePath), fileType: fileType) // Deferred
        let fpsMultiplier: Double = Double(ud.integer(forKey: Preferences.kFrameRate))/8
        let encoderMultiplier: Double = encoder == .hevc ? 0.5 : 0.9
        let targetBitrate = (Double(conf.width) * Double(conf.height) * fpsMultiplier * encoderMultiplier * ud.double(forKey: Preferences.kVideoQuality))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: encoder,
            AVVideoWidthKey: conf.width,
            AVVideoHeightKey: conf.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(targetBitrate),
                AVVideoExpectedSourceFrameRateKey: ud.integer(forKey: Preferences.kFrameRate)
            ] as [String : Any]
        ]
        vwInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings)
        awInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
        vwInput.expectsMediaDataInRealTime = true
        awInput.expectsMediaDataInRealTime = true
        
        if vW.canAdd(vwInput) {
            vW.add(vwInput)
        }
        
        if vW.canAdd(awInput) {
            vW.add(awInput)
        }
        
        recordMic = ud.bool(forKey: Preferences.kRecordMic)
        if recordMic {
            micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
            micInput.expectsMediaDataInRealTime = true
            
            if vW.canAdd(micInput) {
                vW.add(micInput)
            }
        }

        // on macOS 15, the system recorder will handle mic recording directly with SCK + AVAssetWriter
        if #unavailable(macOS 15), recordMic {
            let input = audioEngine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.inputFormat(forBus: 0)) { [weak self] (buffer, time) in
                guard let self = self else { return }
                if self.startTime != nil { // Ensure buffering/recording has started
                    if let sampleBuffer = buffer.asSampleBuffer {
                        // Add microphone samples to the ReplayBufferManager
                        self.replayBufferManager.addSampleBuffer(sampleBuffer, type: .microphone)
                    } else {
                        print("Failed to convert AVAudioPCMBuffer to CMSampleBuffer for microphone audio.")
                    }
                }
            }
            try! audioEngine.start()
        }

        // vW.startWriting() // Deferred
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return } // Ensure buffer is valid before processing

        // Add all valid buffers to the ReplayBufferManager
        replayBufferManager.addSampleBuffer(sampleBuffer, type: outputType)

        // The old logic for vW, vwInput, awInput, micInput, and audioFile writing is now removed.
        // startTime logic will be handled when saving the replay.
        
        // Check for startTime for the overall recording session (buffering start)
        // This does not start AVAssetWriter session, that's deferred.
        if startTime == nil { // General startTime for the buffering session
            startTime = Date.now
            // If specific first-buffer actions are needed, they could go here,
            // but not AVAssetWriter session start.
        }

        switch outputType {
            case .screen:
                // if screen == nil && window == nil { break } // This check might be relevant for UI state, not buffer handling
                guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                      let attachments = attachmentsArray.first else {
                    print("Could not get attachments for screen sample.")
                    return
                }
                guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                      let status = SCFrameStatus(rawValue: statusRawValue),
                      status == .complete else {
                    // According to Apple's docs, we should not use incomplete frames.
                    // print("Frame status not complete for screen sample: \(status.rawValue)")
                    return // Don't add incomplete frames to the buffer
                }
                // Screen buffer specific logic (e.g. setting initial startTime for writer session later)
                // if vW != nil && vW?.status == .writing, sessionStartTime == nil { // sessionStartTime would be specific to AVAssetWriter
                //     sessionStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                //     vW.startSession(atSourceTime: sessionStartTime)
                // }
                // Removed: vwInput.append(sampleBuffer)
                break
            case .audio:
                // Removed: audioFile!.write(from: samples) logic for .systemaudio
                // Removed: awInput.append(sampleBuffer)
                break
            case .microphone:
                // Removed: micInput.append(sampleBuffer)
                break
            @unknown default:
                print("Unknown stream type encountered: \(outputType)")
        }
    }
}

// https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos
// For Sonoma updated to https://developer.apple.com/forums/thread/727709
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? self.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = self.formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}

// Based on https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c
extension AVAudioPCMBuffer {
    var asSampleBuffer: CMSampleBuffer? {
        let asbd = self.format.streamDescription
        var sampleBuffer: CMSampleBuffer? = nil
        var format: CMFormatDescription? = nil

        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(asbd.pointee.mSampleRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(self.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer!,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: self.mutableAudioBufferList
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
