import Foundation
import NaturalLanguage

struct Recording: Codable, Identifiable, Sendable {
    var id = UUID()
    var path: String
    let language: String
    var lesson: Lesson?
    var failure: String?

    var url: URL { URL(fileURLWithPath: path) }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var sourceAvailable: Bool { ImportGroup.isReadableVideo(url) }
}

struct GuideEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    let recordingID: UUID
    let passage: Passage
    var note = ""
}

struct Course: Codable, Identifiable, Sendable {
    var id = UUID()
    let title: String
    var folderPath: String?
    var recordings: [Recording] = []
    var guide: [GuideEntry] = []

    mutating func relinkFolder(to folder: URL) throws {
        guard let folderPath else { throw RelinkError.noFolder }
        let previous = URL(fileURLWithPath: folderPath).standardizedFileURL.pathComponents
        let destination = folder.standardizedFileURL.resolvingSymlinksInPath()
        var updated = recordings
        var count = 0
        for index in recordings.indices {
            let source = recordings[index].url.standardizedFileURL.pathComponents
            guard source.count > previous.count, source.starts(with: previous) else { continue }
            let relative = source.dropFirst(previous.count)
            let target = relative.reduce(destination) { $0.appendingPathComponent($1) }
                .resolvingSymlinksInPath()
            guard target.pathComponents.starts(with: destination.pathComponents),
                  ImportGroup.isReadableVideo(target) else {
                throw RelinkError.missingFile(relative.joined(separator: "/"))
            }
            updated[index].path = target.path
            if target.path != recordings[index].path { updated[index].failure = nil }
            count += 1
        }
        guard count > 0 else { throw RelinkError.noFolder }
        guard Set(updated.map(\.path)).count == updated.count else { throw RelinkError.alreadyLinked }
        recordings = updated
        self.folderPath = destination.path
    }

    func search(_ query: String) -> [SearchHit] {
        let words = Self.words(query)
        let common = Set(["how", "to", "a", "an", "the", "do", "i", "can", "you", "what", "is", "are", "use", "where", "does", "explain", "me", "about", "for", "of", "and"])
        let keywords = Set(words).subtracting(common)
        let required = keywords.isEmpty ? Set(words) : keywords
        guard !required.isEmpty else { return [] }

        let phrase = words.joined(separator: " ")
        return recordings.flatMap { recording in
            (recording.lesson?.transcript ?? []).compactMap { passage -> SearchHit? in
                let spoken = Self.words(passage.text)
                guard required.isSubset(of: Set(spoken)) else { return nil }
                let normalized = " " + spoken.joined(separator: " ") + " "
                return SearchHit(recordingID: recording.id, title: recording.title, passage: passage,
                                 exactPhrase: normalized.contains(" " + phrase + " "))
            }
        }.sorted {
            if $0.exactPhrase != $1.exactPhrase { return $0.exactPhrase }
            let order = $0.title.localizedStandardCompare($1.title)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.passage.start < $1.passage.start
        }
    }

    private static func words(_ text: String) -> [String] {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        return tokenizer.tokens(for: normalized.startIndex..<normalized.endIndex)
            .map { String(normalized[$0]) }
    }
}

enum RelinkError: LocalizedError {
    case noFolder, invalidFile, alreadyLinked, missingFile(String)

    var errorDescription: String? {
        switch self {
        case .noFolder: "This course has no recordings linked to its original folder."
        case .invalidFile: "Choose a readable MOV or MP4 recording."
        case .alreadyLinked: "That file is already linked to another recording in this course."
        case .missingFile(let path):
            "The selected folder is missing “\(path)”. Relink any renamed or reorganized recordings individually, then try the folder again."
        }
    }
}

struct SearchHit: Identifiable, Sendable {
    struct ID: Hashable {
        let recordingID: UUID
        let start: Double
    }

    let recordingID: UUID
    let title: String
    let passage: Passage
    let exactPhrase: Bool
    var id: ID { ID(recordingID: recordingID, start: passage.start) }
}

struct CourseFile: Codable {
    var courses: [Course] = []

    static func read(from url: URL) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Self() }
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

struct ImportGroup: Sendable {
    let folder: URL?
    let files: [URL]

    static func scan(_ urls: [URL]) throws -> [Self] {
        var groups: [Self] = []
        var loose: [URL] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        for url in urls where url.isFileURL {
            let url = url.standardizedFileURL.resolvingSymlinksInPath()
            let values = try url.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                let files = try videos(in: url, keys: keys)
                if !files.isEmpty { groups.append(Self(folder: url, files: files)) }
            } else if values.isRegularFile == true, supports(url) {
                loose.append(url)
            }
        }
        if !loose.isEmpty { groups.append(Self(folder: nil, files: loose)) }
        return groups
    }

    static func supports(_ url: URL) -> Bool {
        ["mov", "mp4"].contains(url.pathExtension.lowercased())
    }

    static func isReadableVideo(_ url: URL) -> Bool {
        supports(url) && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func videos(in folder: URL, keys: Set<URLResourceKey>) throws -> [URL] {
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in scanError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }

        var videos: [URL] = []
        for case let file as URL in enumerator where supports(file) {
            if try file.resourceValues(forKeys: keys).isRegularFile == true {
                videos.append(file.standardizedFileURL.resolvingSymlinksInPath())
            }
        }
        if let scanError { throw scanError }
        return videos.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
