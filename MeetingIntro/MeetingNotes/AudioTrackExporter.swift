import AVFoundation
import Foundation

/// Splits a dual-track MeetingIntro recording into two mono AAC files — one per
/// speaker side — so each can be transcribed independently for exact You/Them
/// attribution.
///
/// Track identification is by CHANNEL COUNT, not order (verified empirically on
/// real recordings): the system-audio pipeline writes stereo (them), the mic
/// pipeline writes mono (me). Output is 16 kHz mono 32 kbps AAC — small enough
/// that an hour stays well under Groq's 25 MB upload cap, and Whisper resamples
/// to 16 kHz anyway so nothing is lost.
enum AudioTrackExporter {

    struct ExportedTracks {
        /// System audio — the other participants. Nil if the source had no stereo track.
        let them: URL?
        /// Microphone — the user. Nil if the source had no mono track.
        let me: URL?
    }

    enum ExportError: LocalizedError {
        case noAudioTracks
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTracks: return "The recording contains no audio tracks."
            case .exportFailed(let detail): return "Track export failed: \(detail)"
            }
        }
    }

    /// Export each audio track of `sourceURL` to its own mono AAC file in a temp
    /// directory. Caller is responsible for deleting the outputs when done.
    static func split(_ sourceURL: URL) async throws -> ExportedTracks {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ExportError.noAudioTracks }

        var themURL: URL?
        var meURL: URL?

        for track in tracks {
            let channelCount = try await Self.channelCount(of: track)
            let exported = try await exportTrack(track, from: asset, label: channelCount >= 2 ? "them" : "me")
            if channelCount >= 2 {
                themURL = exported
            } else {
                meURL = exported
            }
        }
        return ExportedTracks(them: themURL, me: meURL)
    }

    private static func channelCount(of track: AVAssetTrack) async throws -> Int {
        let descriptions = try await track.load(.formatDescriptions)
        guard let desc = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return 1
        }
        return Int(asbd.mChannelsPerFrame)
    }

    private static func exportTrack(_ track: AVAssetTrack, from asset: AVAsset, label: String) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingintro-\(label)-\(UUID().uuidString).m4a")

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(readerOutput) else { throw ExportError.exportFailed("reader rejected track output") }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ])
        guard writer.canAdd(writerInput) else { throw ExportError.exportFailed("writer rejected input") }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw ExportError.exportFailed(reader.error?.localizedDescription ?? "could not start reading")
        }
        guard writer.startWriting() else {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)

        // Pump samples on a dedicated queue; bridge completion back via continuation.
        let queue = DispatchQueue(label: "com.oluyinka.MeetingIntro.trackexport")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sample)
                    } else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw ExportError.exportFailed(writer.error?.localizedDescription ?? "writer failed")
        }
        return outputURL
    }
}
