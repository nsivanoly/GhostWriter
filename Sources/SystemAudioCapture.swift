import ScreenCaptureKit
import AVFoundation
import Foundation

// MARK: - System Audio Capture (ScreenCaptureKit)

/// Captures system audio using ScreenCaptureKit (macOS 13+).
/// Requires Screen Recording permission — prompts automatically on first use.
/// Output format: 16kHz, 16-bit signed integer, mono — same as AudioCapture.

final class SystemAudioCapture: NSObject {

    var onAudioBuffer: ((Data) -> Void)?
    private(set) var isRunning = false

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.ghostwriter.systemaudio", qos: .userInteractive)

    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    }()

    // MARK: - Public API

    func start() async throws {
        guard !isRunning else { return }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Minimise video bandwidth — we only need audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()

        self.stream = stream
        isRunning = true
        print("🖥️ System audio capture started (ScreenCaptureKit)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        print("🖥️ System audio capture stopped")
    }

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "No display found for screen capture"
            }
        }
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCapture: SCStreamOutput {

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRunning else { return }
        guard let pcmBuffer = extractPCMBuffer(from: sampleBuffer) else { return }
        guard let data = convertToTarget(pcmBuffer) else { return }
        onAudioBuffer?(data)
    }

    private func extractPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return nil }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcmBuffer
    }

    private func convertToTarget(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(outputFrameCount, 1)
        ) else { return nil }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, let int16Data = outputBuffer.int16ChannelData else { return nil }
        return Data(
            bytes: int16Data[0],
            count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        )
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCapture: SCStreamDelegate {

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ System audio stream stopped with error: \(error.localizedDescription)")
        isRunning = false
    }
}
