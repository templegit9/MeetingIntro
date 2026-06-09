import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Owns the audio capture lifecycle for a single meeting recording.
///
/// Two parallel capture pipelines, both writing to the same `.m4a`:
/// - **System audio** via `SCStream` (ScreenCaptureKit). This is the only public API
///   on macOS that captures the audio your apps play through the speakers (no virtual
///   loopback driver required).
/// - **Microphone** via `AVCaptureSession` + `AVCaptureAudioDataOutput`. Standalone
///   pipeline that's available on every macOS we support. We'd prefer SCStream's own
///   `captureMicrophone` but that needs macOS 15; this keeps us on macOS 14.
///
/// Output: a single `.m4a` file with two audio tracks (system + microphone). Most
/// players (QuickTime, VLC, Finder Preview) mix them on playback.
@MainActor
final class RecordingController: NSObject, ObservableObject {

    enum RecordingError: LocalizedError {
        case permissionDenied(String)
        case alreadyRecording
        case noShareableContent
        case writerSetupFailed(Error)
        case startupFailed(Error)

        var errorDescription: String? {
            switch self {
            case .permissionDenied(let what):
                return "\(what) permission was denied. Grant it in System Settings → Privacy & Security."
            case .alreadyRecording:
                return "A recording is already in progress."
            case .noShareableContent:
                return "Could not get the current display from ScreenCaptureKit."
            case .writerSetupFailed(let e):
                return "Could not open the recording file: \(e.localizedDescription)"
            case .startupFailed(let e):
                return "Could not start audio capture: \(e.localizedDescription)"
            }
        }
    }

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var currentMeetingTitle: String?
    @Published private(set) var currentFileURL: URL?

    // MARK: - Permissions

    /// Whether MeetingIntro currently holds Screen Recording permission — required by
    /// `SCStream` to capture system audio. `CGPreflightScreenCaptureAccess` reads the
    /// TCC state without side effects (no prompt). System audio capture is the only
    /// public API on macOS 14 that grabs app playback, so without this the recording
    /// has no "Them" track and fails to start.
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Trigger the system Screen Recording permission prompt (first call) or no-op if
    /// already decided. Returns the resulting grant state. macOS only surfaces the
    /// prompt once per app; after that the user must toggle it in System Settings, so
    /// the Settings UI also offers a direct deep link.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Whether microphone capture is currently authorized (the "You" track).
    static var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var stream: SCStream?
    private var sysHandler: SystemAudioHandler?
    private var micSession: AVCaptureSession?
    private var micHandler: MicHandler?

    private var assetWriter: AVAssetWriter?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

    private let writeQueue = DispatchQueue(label: "com.oluyinka.MeetingIntro.recording.write", qos: .userInitiated)

    // MARK: - Public API

    func start(for meeting: MeetingEvent, saveDirectory: URL) async throws -> URL {
        if isRecording { throw RecordingError.alreadyRecording }

        // Pre-flight Screen Recording permission before touching the filesystem or
        // ScreenCaptureKit. Without it the SCShareableContent call below throws after
        // we've already created (and have to clean up) the output file — and the
        // coordinator would retry that churn on every meeting start.
        guard Self.hasScreenRecordingPermission else {
            throw RecordingError.permissionDenied("Screen Recording")
        }

        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let fileURL = Self.uniqueFileURL(in: saveDirectory, title: meeting.title)

        // 1. Asset writer with two audio inputs (one track per source).
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
        } catch {
            throw RecordingError.writerSetupFailed(error)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
        ]
        let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        sysInput.expectsMediaDataInRealTime = true
        let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96000,
        ])
        micInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(sysInput), writer.canAdd(micInput) else {
            throw RecordingError.writerSetupFailed(NSError(domain: "Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: "writer rejected audio inputs"]))
        }
        writer.add(sysInput)
        writer.add(micInput)
        guard writer.startWriting() else {
            throw RecordingError.writerSetupFailed(writer.error ?? NSError(domain: "Recording", code: 2))
        }

        // Shared session-start coordinator: whichever pipeline produces a sample
        // first sets `t0` on the writer; both pipelines wait until it's set before
        // appending.
        let starter = SessionStarter(writer: writer)

        // 2. SCStream for system audio.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            throw RecordingError.permissionDenied("Screen Recording")
        }
        guard let display = content.displays.first else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            throw RecordingError.noShareableContent
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Required video config — kept minimal since we never wire up a video output.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let sysHandler = SystemAudioHandler(input: sysInput, starter: starter)
        do {
            try stream.addStreamOutput(sysHandler, type: .audio, sampleHandlerQueue: writeQueue)
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            throw RecordingError.startupFailed(error)
        }

        // 3. AVCaptureSession for microphone.
        let micSession = AVCaptureSession()
        guard let micDevice = AVCaptureDevice.default(for: .audio),
              let micInputDevice = try? AVCaptureDeviceInput(device: micDevice),
              micSession.canAddInput(micInputDevice) else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            throw RecordingError.permissionDenied("Microphone")
        }
        micSession.addInput(micInputDevice)
        let micOutput = AVCaptureAudioDataOutput()
        let micHandler = MicHandler(input: micInput, starter: starter)
        micOutput.setSampleBufferDelegate(micHandler, queue: writeQueue)
        guard micSession.canAddOutput(micOutput) else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            throw RecordingError.startupFailed(NSError(domain: "Recording", code: 3, userInfo: [NSLocalizedDescriptionKey: "could not attach mic output"]))
        }
        micSession.addOutput(micOutput)

        // 4. Start both pipelines.
        micSession.startRunning()
        do {
            try await stream.startCapture()
        } catch {
            micSession.stopRunning()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            throw RecordingError.startupFailed(error)
        }

        // 5. Commit state.
        self.stream = stream
        self.sysHandler = sysHandler
        self.micSession = micSession
        self.micHandler = micHandler
        self.assetWriter = writer
        self.systemAudioInput = sysInput
        self.micAudioInput = micInput
        self.currentMeetingTitle = meeting.title
        self.currentFileURL = fileURL
        self.isRecording = true

        return fileURL
    }

    func stop() async {
        guard isRecording, let stream, let writer = assetWriter else { return }

        do { try await stream.stopCapture() } catch { /* ignore */ }
        micSession?.stopRunning()

        systemAudioInput?.markAsFinished()
        micAudioInput?.markAsFinished()
        await writer.finishWriting()

        self.stream = nil
        self.sysHandler = nil
        self.micSession = nil
        self.micHandler = nil
        self.assetWriter = nil
        self.systemAudioInput = nil
        self.micAudioInput = nil
        self.currentMeetingTitle = nil
        self.currentFileURL = nil
        self.isRecording = false
    }

    // MARK: - File naming

    private static func uniqueFileURL(in directory: URL, title: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let datePart = formatter.string(from: Date())
        let cleanTitle = sanitize(title)
        let base = "\(datePart) - \(cleanTitle)"
        var url = directory.appendingPathComponent("\(base).m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(n).m4a")
            n += 1
            if n > 99 { break }
        }
        return url
    }

    private static func sanitize(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?<>|*\"")
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "")
        let collapsed = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let truncated = String(trimmed.prefix(80))
        return truncated.isEmpty ? "Untitled Meeting" : truncated
    }
}

// MARK: - Session start coordinator

/// Threadsafe one-shot to call `writer.startSession(atSourceTime:)` exactly once,
/// using the PTS of whichever pipeline (system audio or mic) produces a sample first.
private final class SessionStarter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let lock = NSLock()
    private var started = false

    init(writer: AVAssetWriter) {
        self.writer = writer
    }

    /// Returns true iff session has been started (now or previously) — i.e., it's safe
    /// to append the sample.
    func ensureStarted(at pts: CMTime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if started { return true }
        guard pts.isValid, writer.status == .writing else { return false }
        writer.startSession(atSourceTime: pts)
        started = true
        return true
    }
}

// MARK: - System audio

private final class SystemAudioHandler: NSObject, SCStreamOutput {
    private let input: AVAssetWriterInput
    private let starter: SessionStarter

    init(input: AVAssetWriterInput, starter: SessionStarter) {
        self.input = input
        self.starter = starter
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard starter.ensureStarted(at: pts) else { return }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}

// MARK: - Microphone

private final class MicHandler: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let input: AVAssetWriterInput
    private let starter: SessionStarter

    init(input: AVAssetWriterInput, starter: SessionStarter) {
        self.input = input
        self.starter = starter
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard starter.ensureStarted(at: pts) else { return }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}
