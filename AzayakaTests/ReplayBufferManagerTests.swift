import XCTest
import AVFoundation
import ScreenCaptureKit
@testable import Azayaka // Import Azayaka to access ReplayBufferManager

class ReplayBufferManagerTests: XCTestCase {

    var replayManager: ReplayBufferManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        replayManager = ReplayBufferManager()
    }

    override func tearDownWithError() throws {
        replayManager = nil
        try super.tearDownWithError()
    }

    // MARK: - Helper function to create dummy CMSampleBuffer
    
    // Creates a very minimal CMSampleBuffer for testing purposes.
    // For many tests, only the presentationTimeStamp and duration are critical.
    // This helper might need to be expanded if tests require more specific buffer contents or format descriptions.
    func createDummySampleBuffer(presentationTimeStampSeconds: Double, durationSeconds: Double, isVideo: Bool = true) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        let timeScale: CMTimeScale = 600 // A common timescale

        if isVideo {
            // Minimal video format description
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_H264, // A common codec type
                width: 1280, height: 720, // Common dimensions
                extensions: nil, 
                formatDescriptionOut: &formatDescription
            )
        } else { // Minimal audio format description
            var audioStreamBasicDescription = AudioStreamBasicDescription(
                mSampleRate: 48000.0,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &audioStreamBasicDescription,
                layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        }

        guard let validFormatDescription = formatDescription else {
            XCTFail("Failed to create format description for dummy sample buffer.")
            return nil
        }

        let presentationTimeStamp = CMTimeMakeWithSeconds(presentationTimeStampSeconds, preferredTimescale: timeScale)
        let duration = CMTimeMakeWithSeconds(durationSeconds, preferredTimescale: timeScale)

        var timingInfo = CMSampleTimingInfo(duration: duration, presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?

        // Create the sample buffer.
        // For tests not inspecting data, dataBuffer can be nil.
        // If data inspection becomes necessary, a dummy CMBlockBuffer would be needed.
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil, // No actual data for these tests
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: validFormatDescription,
            sampleCount: 1, // Number of samples in the buffer
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        if status != noErr {
            XCTFail("Failed to create dummy CMSampleBuffer. Status: \(status)")
            return nil
        }
        
        return sampleBuffer
    }

    // MARK: - Test Cases

    func testInitialization() {
        XCTAssertNotNil(replayManager, "ReplayBufferManager should initialize successfully.")
        XCTAssertEqual(replayManager.maxDurationSeconds, 30.0, "Default maxDurationSeconds should be 30.0.")
    }

    func testSetMaxDuration() {
        replayManager.maxDurationSeconds = 60.0
        XCTAssertEqual(replayManager.maxDurationSeconds, 60.0, "maxDurationSeconds should be settable.")
    }
    
    // MARK: - Adding Buffers Tests

    func testAddVideoBuffer() {
        guard let buffer = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 1.0, isVideo: true) else { return }
        replayManager.addSampleBuffer(buffer, type: .screen)
        let duration = replayManager.getCurrentBufferDuration(type: .screen)
        XCTAssertEqual(duration.seconds, 1.0, "Duration should be 1.0 second after adding one video buffer.")
    }

    func testAddAudioBuffer() {
        guard let buffer = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 1.0, isVideo: false) else { return }
        replayManager.addSampleBuffer(buffer, type: .audio) // App audio
        let duration = replayManager.getCurrentBufferDuration(type: .audio)
        XCTAssertEqual(duration.seconds, 1.0, "Duration should be 1.0 second after adding one app audio buffer.")
    }

    func testAddMicBuffer() {
        guard let buffer = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 1.0, isVideo: false) else { return }
        replayManager.addSampleBuffer(buffer, type: .microphone)
        let duration = replayManager.getCurrentBufferDuration(type: .microphone)
        XCTAssertEqual(duration.seconds, 1.0, "Duration should be 1.0 second after adding one mic audio buffer.")
    }
    
    func testAddMultipleVideoBuffers() {
        guard let buffer1 = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 1.0, isVideo: true),
              let buffer2 = createDummySampleBuffer(presentationTimeStampSeconds: 1.0, durationSeconds: 1.5, isVideo: true) else { return }
        replayManager.addSampleBuffer(buffer1, type: .screen)
        replayManager.addSampleBuffer(buffer2, type: .screen)
        let duration = replayManager.getCurrentBufferDuration(type: .screen)
        XCTAssertEqual(duration.seconds, 2.5, "Duration should be 2.5 seconds after adding two video buffers.")
    }

    // MARK: - Buffer Trimming Tests

    func testVideoBufferTrimming() {
        replayManager.maxDurationSeconds = 2.0
        // Add 3 buffers, total 3 seconds. Should trim to 2 seconds.
        guard let buffer1 = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 1.0, isVideo: true), // Will be trimmed
              let buffer2 = createDummySampleBuffer(presentationTimeStampSeconds: 1.0, durationSeconds: 1.0, isVideo: true),
              let buffer3 = createDummySampleBuffer(presentationTimeStampSeconds: 2.0, durationSeconds: 1.0, isVideo: true) else { return }

        replayManager.addSampleBuffer(buffer1, type: .screen) // PTS: 0, DUR: 1
        replayManager.addSampleBuffer(buffer2, type: .screen) // PTS: 1, DUR: 1 -> Total DUR: 2
        replayManager.addSampleBuffer(buffer3, type: .screen) // PTS: 2, DUR: 1 -> Total DUR: 3, should trim buffer1

        let duration = replayManager.getCurrentBufferDuration(type: .screen)
        XCTAssertEqual(duration.seconds, 2.0, accuracy: 0.01, "Video buffer duration should be trimmed to maxDurationSeconds (2.0s).")

        let (videoReplay, _, _) = replayManager.getReplayBuffers(forLast: 2.0)
        XCTAssertEqual(videoReplay.count, 2, "Should have 2 video buffers after trimming.")
        if videoReplay.count == 2 {
            // Check timestamps if possible (assuming createDummySampleBuffer stores them correctly for retrieval or inspection)
             XCTAssertEqual(videoReplay[0].presentationTimeStamp.seconds, 1.0, "First buffer after trim should be buffer2")
             XCTAssertEqual(videoReplay[1].presentationTimeStamp.seconds, 2.0, "Second buffer after trim should be buffer3")
        }
    }
    
    func testAudioBufferTrimming() {
        replayManager.maxDurationSeconds = 1.5
        guard let buffer1 = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 0.75, isVideo: false), // Will be trimmed
              let buffer2 = createDummySampleBuffer(presentationTimeStampSeconds: 0.75, durationSeconds: 0.75, isVideo: false),
              let buffer3 = createDummySampleBuffer(presentationTimeStampSeconds: 1.5, durationSeconds: 0.75, isVideo: false) else { return }

        replayManager.addSampleBuffer(buffer1, type: .audio)
        replayManager.addSampleBuffer(buffer2, type: .audio) // Total duration 1.5
        replayManager.addSampleBuffer(buffer3, type: .audio) // Total duration 2.25, should trim buffer1

        let duration = replayManager.getCurrentBufferDuration(type: .audio)
        XCTAssertEqual(duration.seconds, 1.5, accuracy: 0.01, "Audio buffer duration should be trimmed to maxDurationSeconds (1.5s).")

        let (_, audioReplay, _) = replayManager.getReplayBuffers(forLast: 1.5)
        XCTAssertEqual(audioReplay.count, 2, "Should have 2 audio buffers after trimming.")
         if audioReplay.count == 2 {
             XCTAssertEqual(audioReplay[0].presentationTimeStamp.seconds, 0.75, "First audio buffer after trim should be buffer2")
             XCTAssertEqual(audioReplay[1].presentationTimeStamp.seconds, 1.5, "Second audio buffer after trim should be buffer3")
        }
    }

    func testMicBufferTrimming() {
        replayManager.maxDurationSeconds = 1.0
        guard let buffer1 = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 0.5, isVideo: false),
              let buffer2 = createDummySampleBuffer(presentationTimeStampSeconds: 0.5, durationSeconds: 0.5, isVideo: false),
              let buffer3 = createDummySampleBuffer(presentationTimeStampSeconds: 1.0, durationSeconds: 0.5, isVideo: false) else { return }

        replayManager.addSampleBuffer(buffer1, type: .microphone)
        replayManager.addSampleBuffer(buffer2, type: .microphone) // Total duration 1.0
        replayManager.addSampleBuffer(buffer3, type: .microphone) // Total duration 1.5, should trim buffer1

        let duration = replayManager.getCurrentBufferDuration(type: .microphone)
        XCTAssertEqual(duration.seconds, 1.0, accuracy: 0.01, "Mic buffer duration should be trimmed to maxDurationSeconds (1.0s).")
        
        let (_, _, micReplay) = replayManager.getReplayBuffers(forLast: 1.0)
        XCTAssertEqual(micReplay.count, 2, "Should have 2 mic buffers after trimming.")
        if micReplay.count == 2 {
             XCTAssertEqual(micReplay[0].presentationTimeStamp.seconds, 0.5, "First mic buffer after trim should be buffer2")
             XCTAssertEqual(micReplay[1].presentationTimeStamp.seconds, 1.0, "Second mic buffer after trim should be buffer3")
        }
    }
    
    // MARK: - Get Replay Buffers Tests

    func testGetReplayBuffers_AllTypes_FullDuration() {
        // Add 3 seconds of buffers for each type
        for i in 0..<3 {
            guard let vBuf = createDummySampleBuffer(presentationTimeStampSeconds: Double(i), durationSeconds: 1.0, isVideo: true),
                  let aBuf = createDummySampleBuffer(presentationTimeStampSeconds: Double(i), durationSeconds: 1.0, isVideo: false),
                  let mBuf = createDummySampleBuffer(presentationTimeStampSeconds: Double(i), durationSeconds: 1.0, isVideo: false) else {
                XCTFail("Failed to create dummy buffers for getReplayBuffers test."); return
            }
            replayManager.addSampleBuffer(vBuf, type: .screen)
            replayManager.addSampleBuffer(aBuf, type: .audio)
            replayManager.addSampleBuffer(mBuf, type: .microphone)
        }

        let (videoReplay, audioReplay, micReplay) = replayManager.getReplayBuffers(forLast: 3.0)
        XCTAssertEqual(videoReplay.count, 3, "Should retrieve 3 video buffers for 3 seconds.")
        XCTAssertEqual(audioReplay.count, 3, "Should retrieve 3 audio buffers for 3 seconds.")
        XCTAssertEqual(micReplay.count, 3, "Should retrieve 3 mic buffers for 3 seconds.")
    }

    func testGetReplayBuffers_PartialDuration() {
        // Add 5 seconds of video buffers
        for i in 0..<5 {
            guard let buffer = createDummySampleBuffer(presentationTimeStampSeconds: Double(i), durationSeconds: 1.0, isVideo: true) else { return }
            replayManager.addSampleBuffer(buffer, type: .screen)
        }
        
        let (videoReplay, _, _) = replayManager.getReplayBuffers(forLast: 2.5) // Request last 2.5s
        XCTAssertEqual(videoReplay.count, 3, "Should retrieve 3 video buffers for the last 2.5 seconds (buffers at PTS 2, 3, 4).")
        // We expect buffers with PTS 2.0, 3.0, 4.0 (total duration 3s, but covers the 2.5s window from end)
        // Buffer at PTS 2 (covers 2.0 to 3.0)
        // Buffer at PTS 3 (covers 3.0 to 4.0)
        // Buffer at PTS 4 (covers 4.0 to 5.0)
        // Last timestamp is ~5.0. Start time for 2.5s window is ~2.5.
        // Buffers with PTS >= 2.5 are included.
        if videoReplay.count == 3 {
            XCTAssertEqual(videoReplay[0].presentationTimeStamp.seconds, 2.0, "First retrieved buffer should have PTS 2.0.")
            XCTAssertEqual(videoReplay[1].presentationTimeStamp.seconds, 3.0, "Second retrieved buffer should have PTS 3.0.")
            XCTAssertEqual(videoReplay[2].presentationTimeStamp.seconds, 4.0, "Third retrieved buffer should have PTS 4.0.")
        }
    }
    
    func testGetReplayBuffers_MoreThanAvailable() {
        guard let buffer = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 1.0, isVideo: true) else { return }
        replayManager.addSampleBuffer(buffer, type: .screen)
        
        let (videoReplay, _, _) = replayManager.getReplayBuffers(forLast: 5.0) // Request 5s, only 1s available
        XCTAssertEqual(videoReplay.count, 1, "Should retrieve all available buffers if requested duration is more than available.")
    }

    func testGetReplayBuffers_ZeroSeconds() {
        guard let buffer = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 1.0, isVideo: true) else { return }
        replayManager.addSampleBuffer(buffer, type: .screen)
        
        let (videoReplay, _, _) = replayManager.getReplayBuffers(forLast: 0.0)
        XCTAssertEqual(videoReplay.count, 0, "Should retrieve 0 buffers if requested duration is 0 seconds.")
    }
    
    func testGetReplayBuffers_Empty() {
        let (videoReplay, audioReplay, micReplay) = replayManager.getReplayBuffers(forLast: 10.0)
        XCTAssertTrue(videoReplay.isEmpty, "Video replay should be empty if no buffers were added.")
        XCTAssertTrue(audioReplay.isEmpty, "Audio replay should be empty if no buffers were added.")
        XCTAssertTrue(micReplay.isEmpty, "Mic replay should be empty if no buffers were added.")
    }

    // MARK: - Clear Buffers Test

    func testClearBuffers() {
        // Add some buffers
        guard let vBuf = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 1.0, isVideo: true),
              let aBuf = createDummySampleBuffer(presentationTimeStampSeconds: 0, durationSeconds: 1.0, isVideo: false) else { return }
        replayManager.addSampleBuffer(vBuf, type: .screen)
        replayManager.addSampleBuffer(aBuf, type: .audio)

        XCTAssertEqual(replayManager.getCurrentBufferDuration(type: .screen).seconds, 1.0, "Video duration should be 1.0 before clear.")
        XCTAssertEqual(replayManager.getCurrentBufferDuration(type: .audio).seconds, 1.0, "Audio duration should be 1.0 before clear.")

        replayManager.clearBuffers()

        XCTAssertEqual(replayManager.getCurrentBufferDuration(type: .screen).seconds, 0, "Video duration should be 0 after clear.")
        XCTAssertEqual(replayManager.getCurrentBufferDuration(type: .audio).seconds, 0, "Audio duration should be 0 after clear.")
        XCTAssertEqual(replayManager.getCurrentBufferDuration(type: .microphone).seconds, 0, "Mic duration should be 0 after clear.")

        let (videoReplay, audioReplay, micReplay) = replayManager.getReplayBuffers(forLast: 10.0)
        XCTAssertTrue(videoReplay.isEmpty, "Video replay should be empty after clear.")
        XCTAssertTrue(audioReplay.isEmpty, "Audio replay should be empty after clear.")
        XCTAssertTrue(micReplay.isEmpty, "Mic replay should be empty after clear.")
    }
}
