import AVFoundation
import Foundation
import Speech

struct Passage: Identifiable, Codable, Sendable {
    let start: Double
    let end: Double
    let text: String
    var id: Double { start }

    var timestamp: String {
        let seconds = Int(start)
        let clock = String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60)
        return seconds >= 3600 ? "\(seconds / 3600):\(clock)" : clock
    }
}

struct Lesson: Codable, Sendable {
    let transcript: [Passage]
    let summary: [Passage]
    let takeaways: [Passage]

    init(transcript: [Passage]) {
        self.transcript = transcript
        let markers = /(?i)\b(first|second|third|step|because|important|remember|to summarize|for example|you should|make sure)\b/
        let stopWords = Set("about after again also been before could from have here just like more only some than that their them then there these they this those through very want what when where which will with would your".split(separator: " ").map(String.init))
        let keywords = transcript.map { passage in
            Set(passage.text.lowercased().split { !$0.isLetter }.map(String.init)
                .filter { $0.count > 3 && !stopWords.contains($0) })
        }
        var frequency: [String: Int] = [:]
        for words in keywords {
            for word in words { frequency[word, default: 0] += 1 }
        }

        var ranked: [(index: Int, score: Int)] = []
        for (index, passage) in transcript.enumerated() {
            let topical = keywords[index].reduce(0) { $0 + min(4, frequency[$1, default: 0] - 1) }
            let cue = passage.text.firstMatch(of: markers) == nil ? 0 : 7
            let length = min(4, passage.text.split(separator: " ").count / 4)
            ranked.append((index, topical + cue + length))
        }
        ranked.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }

        // Prefer useful excerpts from across the lesson, with no repeated text.
        var chosen: [Int] = []
        let separation = min(35, (transcript.last?.end ?? 0) / 8)
        for candidate in ranked where chosen.count < 5 {
            let passage = transcript[candidate.index]
            guard !chosen.contains(where: {
                abs(transcript[$0].start - passage.start) < separation
                    || transcript[$0].text == passage.text
            }) else { continue }
            chosen.append(candidate.index)
        }
        takeaways = chosen.sorted().map { transcript[$0] }
        summary = chosen.prefix(2).sorted().map { transcript[$0] }
    }

    func markdown(title: String) -> String {
        func escaped(_ text: String) -> String {
            var escaped = ""
            for character in text {
                if "\\`*_{}[]<>#+-!|".contains(character) { escaped.append("\\") }
                escaped.append(character)
            }
            return escaped
        }
        func bullets(_ passages: [Passage]) -> String {
            passages.map { "- **\($0.timestamp)** \(escaped($0.text))" }.joined(separator: "\n")
        }
        return """
        # \(escaped(title.replacingOccurrences(of: "\n", with: " ")))

        ## Summary

        \(bullets(summary))

        ## Takeaways

        \(bullets(takeaways))

        ## Transcript

        \(bullets(transcript))

        """ + "\n"
    }
}

enum LessonError: LocalizedError {
    case missingVideo, missingAudio, exportUnavailable, unsupportedDevice, unsupportedLanguage, noSpeech

    var errorDescription: String? {
        switch self {
        case .missingVideo: "This file does not contain a video track."
        case .missingAudio: "This video has no audio track."
        case .exportUnavailable: "ClipNotes could not extract audio from this video."
        case .unsupportedDevice: "On-device transcription is unavailable on this Mac."
        case .unsupportedLanguage: "There is no speech model for the selected language."
        case .noSpeech: "ClipNotes could not find speech in this recording. Check the audio and selected language."
        }
    }
}

enum LessonProcessor {
    static func process(
        video: URL,
        locale: Locale,
        status: @Sendable (String) async -> Void = { _ in }
    ) async throws -> Lesson {
        let asset = AVURLAsset(url: video)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw LessonError.missingVideo }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw LessonError.missingAudio }
        guard SpeechTranscriber.isAvailable else { throw LessonError.unsupportedDevice }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LessonError.unsupportedLanguage
        }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await status("Downloading speech model…")
            try await install.downloadAndInstall()
        }
        try Task.checkCancellation()

        await status("Extracting lesson audio…")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipnotes-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audioRange = try await track.load(.timeRange)
        let composition = AVMutableComposition()
        guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LessonError.exportUnavailable
        }
        try audio.insertTimeRange(audioRange, of: track, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw LessonError.exportUnavailable
        }
        try await exporter.export(to: temporary, as: .m4a)

        await status("Transcribing speech on this Mac…")
        let audioFile = try AVAudioFile(forReading: temporary)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let offset = audioRange.start.seconds

        async let passages: [Passage] = collect(from: transcriber, offset: offset)
        do {
            if let end = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let transcript = try await passages.sorted { $0.start < $1.start }
        guard !transcript.isEmpty else { throw LessonError.noSpeech }
        return Lesson(transcript: transcript)
    }

    private static func collect(from transcriber: SpeechTranscriber, offset: Double) async throws -> [Passage] {
        var passages: [Passage] = []
        var text = ""
        var start: Double?
        var end = 0.0

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start, !trimmed.isEmpty {
                passages.append(Passage(start: start, end: max(start, end), text: trimmed))
            }
            text = ""
            start = nil
        }

        for try await result in transcriber.results where result.isFinal {
            let fallback = result.range
            for run in result.text.runs {
                let phrase = String(result.text[run.range].characters)
                let range = run.audioTimeRange ?? fallback
                let begin = max(0, range.start.seconds + offset)
                let finish = range.end.seconds + offset
                guard begin.isFinite, finish.isFinite else { continue }
                let spoken = !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if spoken, start != nil, begin > end + 1.3 { flush() }
                if spoken, start == nil { start = begin }
                text += phrase
                end = max(begin, finish)
                let last = phrase.trimmingCharacters(in: .whitespacesAndNewlines).last
                if let last, ".!?".contains(last) { flush() }
            }
            if text.count > 180 { flush() }
            if !text.isEmpty && text.last?.isWhitespace == false { text += " " }
        }
        flush()
        // A recognizer can assign multiple short passages to the same start time.
        var unique: [Passage] = []
        for passage in passages {
            if let last = unique.last, last.start == passage.start {
                unique[unique.count - 1] = Passage(
                    start: last.start, end: max(last.end, passage.end), text: last.text + " " + passage.text
                )
            } else {
                unique.append(passage)
            }
        }
        return unique
    }
}
