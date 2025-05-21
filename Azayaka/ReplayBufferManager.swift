import AVFoundation
import ScreenCaptureKit

class ReplayBufferManager {
    // MARK: - Properties

    private var videoBuffers: [CMSampleBuffer] = []
    private var audioBuffers: [CMSampleBuffer] = []
    // micBuffers will store microphone audio samples
    private var micBuffers: [CMSampleBuffer] = []

    private var videoTimestamps: [CMTime] = []
    private var audioTimestamps: [CMTime] = []
    // micTimestamps will store microphone audio timestamps
    private var micTimestamps: [CMTime] = []

    var maxDurationSeconds: Double = 30.0

    // MARK: - Methods

    func addSampleBuffer(_ buffer: CMSampleBuffer, type: SCStreamOutputType) {
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        let duration = CMSampleBufferGetDuration(buffer)

        switch type {
        case .screen:
            videoBuffers.append(buffer)
            videoTimestamps.append(presentationTimeStamp)
            trimBuffers(type: .screen, currentDuration: getCurrentBufferDuration(type: .screen).seconds + duration.seconds)
        case .audio:
            // Differentiate between app audio and microphone audio if necessary
            // For now, assuming SCStreamOutputType.audio refers to app audio
            audioBuffers.append(buffer)
            audioTimestamps.append(presentationTimeStamp)
            trimBuffers(type: .audio, currentDuration: getCurrentBufferDuration(type: .audio).seconds + duration.seconds)
        case .microphone:
            micBuffers.append(buffer)
            micTimestamps.append(presentationTimeStamp)
            // Use .microphone type for trimming and duration calculation
            trimBuffers(type: .microphone, currentDuration: getCurrentBufferDuration(type: .microphone).seconds + duration.seconds)
        @unknown default:
            print("Unhandled buffer type: \(type)")
        }
    }

    private func trimBuffers(type: SCStreamOutputType, currentDuration: Double) {
        var targetBuffers: [CMSampleBuffer]
        var targetTimestamps: [CMTime]

        switch type {
        case .screen:
            targetBuffers = videoBuffers
            targetTimestamps = videoTimestamps
        case .audio:
            targetBuffers = audioBuffers
            targetTimestamps = audioTimestamps
        case .microphone:
            targetBuffers = micBuffers
            targetTimestamps = micTimestamps
        @unknown default:
            print("Unhandled buffer type for trimming: \(type)")
            return
        }

        var duration = currentDuration
        while duration > maxDurationSeconds && !targetBuffers.isEmpty {
            let oldestBuffer = targetBuffers.removeFirst()
            let _ = targetTimestamps.removeFirst()
            duration -= CMSampleBufferGetDuration(oldestBuffer).seconds
        }
        // Update the actual buffers after removal
        switch type {
        case .screen:
            videoBuffers = targetBuffers
            videoTimestamps = targetTimestamps
        case .audio:
            audioBuffers = targetBuffers
            audioTimestamps = targetTimestamps
        case .microphone:
            micBuffers = targetBuffers
            micTimestamps = targetTimestamps
        @unknown default:
            print("Unhandled buffer type for updating after trimming: \(type)")
        }
    }

    func getReplayBuffers(forLast seconds: Double) -> (video: [CMSampleBuffer], audio: [CMSampleBuffer], mic: [CMSampleBuffer]) {
        let videoReplay = getBuffers(forLast: seconds, buffers: videoBuffers, timestamps: videoTimestamps)
        let audioReplay = getBuffers(forLast: seconds, buffers: audioBuffers, timestamps: audioTimestamps)
        let micReplay = getBuffers(forLast: seconds, buffers: micBuffers, timestamps: micTimestamps)
        return (videoReplay, audioReplay, micReplay)
    }

    private func getBuffers(forLast seconds: Double, buffers: [CMSampleBuffer], timestamps: [CMTime]) -> [CMSampleBuffer] {
        guard !buffers.isEmpty, let lastTimestamp = timestamps.last else {
            return []
        }

        let startTime = CMTimeSubtract(lastTimestamp, CMTimeMakeWithSeconds(seconds, preferredTimescale: lastTimestamp.timescale))
        var resultBuffers: [CMSampleBuffer] = []

        for (index, buffer) in buffers.enumer().reversed() {
            if timestamps[index] >= startTime {
                resultBuffers.insert(buffer, at: 0) // Prepend to maintain order
            } else {
                break // Buffers are ordered by time, so we can stop
            }
        }
        return resultBuffers
    }

    func clearBuffers() {
        videoBuffers.removeAll()
        audioBuffers.removeAll()
        micBuffers.removeAll()
        videoTimestamps.removeAll()
        audioTimestamps.removeAll()
        micTimestamps.removeAll()
    }

    func getCurrentBufferDuration(type: SCStreamOutputType) -> CMTime {
        let timestamps: [CMTime]
        switch type {
        case .screen:
            timestamps = videoTimestamps
        case .audio:
            timestamps = audioTimestamps
        case .microphone:
            timestamps = micTimestamps
        @unknown default:
            print("Unhandled buffer type for duration calculation: \(type)")
            return .zero
        }

        guard let firstTimestamp = timestamps.first, let lastTimestamp = timestamps.last else {
            return .zero
        }
        // Calculate duration from the actual buffer timestamps if available,
        // otherwise use the difference between the last and first timestamp.
        // This assumes buffers are ordered and contiguous for an accurate duration.
        // A more precise method would sum the durations of individual buffers.
        
        var totalDuration = CMTime.zero
        for buffer in (type == .screen ? videoBuffers : (type == .audio ? audioBuffers : micBuffers)) {
            totalDuration = CMTimeAdd(totalDuration, CMSampleBufferGetDuration(buffer))
        }
        // If summing individual durations is too complex or not performant enough,
        // the difference between last and first timestamp is a simpler approximation.
        // For now, using the sum of durations for accuracy.
        // return CMTimeSubtract(lastTimestamp, firstTimestamp)
        return totalDuration
    }
}
