@preconcurrency import AVFoundation
import Foundation
import ScrecCore
import ScrecRender
import Speech

/// On-device speech-to-text for captions (Phase 5 item 3) with Apple's `SpeechAnalyzer` / `SpeechTranscriber`.
/// Audio never leaves the Mac. Each language needs Apple's speech model; missing models are downloaded only when
/// the user asks for it (`downloadModel`). Needs macOS 26 or newer (Screc itself runs from macOS 15; older
/// systems show a note instead of the captions controls).
@available(macOS 26, *)
public enum Transcriber {
    public enum TranscriberError: LocalizedError {
        case noVoiceTrack, unsupportedLanguage(String), modelMissing(String)
        public var errorDescription: String? {
            switch self {
            case .noVoiceTrack: "This recording has no microphone or system audio to transcribe."
            case let .unsupportedLanguage(l): "Speech recognition does not support \(l)."
            case let .modelMissing(l): "The speech model for \(l) is not installed yet. Download it first."
            }
        }
    }

    public static func supportedLanguages() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
    }

    public static func isInstalled(_ locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
        return installed.contains(locale.identifier)
    }

    /// The supported locale closest to `locale` (e.g. en-CH → en_US is not automatic; this asks the system).
    public static func supported(_ locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Downloads and installs Apple's speech model for a language. Progress 0…1.
    public static func downloadModel(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let observation = request.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        progress(1)
    }

    /// Transcribes the microphone (or, without one, the system audio) of a bundle in source time.
    public static func transcribe(bundle: URL, locale: Locale) async throws -> Transcript {
        let candidates = [BundleLayout.mic, BundleLayout.system]
        guard let name = candidates.first(where: { FileManager.default.fileExists(atPath: bundle.appendingPathComponent($0).path) }) else {
            throw TranscriberError.noVoiceTrack
        }
        guard await isInstalled(locale) else { throw TranscriberError.modelMissing(locale.identifier) }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let file = try AVAudioFile(forReading: bundle.appendingPathComponent(name))
        // The analyzer must stay alive while results are read.
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        var words: [Transcript.Word] = []
        for try await result in transcriber.results {
            for run in result.text.runs {
                let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let r = run.audioTimeRange {
                    words.append(.init(text: text, start: r.start.seconds, end: r.end.seconds))
                } else if !words.isEmpty {
                    words[words.count - 1].text += text          // punctuation without its own time
                }
            }
        }
        _ = analyzer
        let raw = Transcript(language: locale.identifier, source: name, words: words.sorted { $0.start < $1.start })
        return try await AudioLevels.refine(raw, bundle: bundle)
    }
}
