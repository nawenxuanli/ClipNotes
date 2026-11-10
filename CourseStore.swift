import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class CourseStore: ObservableObject {
    @Published private(set) var data = CourseFile()
    @Published private(set) var processing: UUID?
    @Published private(set) var phase = ""
    @Published private(set) var scanning = false
    @Published var selectedCourse: UUID?
    @Published var error: String?
    @Published var language = "en-US"

    private let location: URL
    private var readable = true
    private var worker: Task<Void, Never>?

    init() {
        let root = URL.applicationSupportDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.clipnotes.desktop", isDirectory: true)
        location = root.appendingPathComponent("Courses.json")
        do {
            data = try CourseFile.read(from: location)
            selectedCourse = data.courses.first?.id
        } catch {
            readable = false
            self.error = "Couldn’t open your courses. \(error.localizedDescription)"
        }
    }

    var course: Course? { data.courses.first { $0.id == selectedCourse } }

    func open(folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        if !folders { panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie] }
        panel.begin { response in
            if response == .OK { self.importURLs(panel.urls) }
        }
    }

    func importURLs(_ urls: [URL]) {
        guard readable, !scanning, !urls.isEmpty else { return }
        scanning = true
        let destination = selectedCourse
        let language = self.language
        Task {
            defer { scanning = false }
            do {
                let groups = try await Task.detached(priority: .userInitiated) { try ImportGroup.scan(urls) }.value
                guard !groups.isEmpty else {
                    error = "No MOV or MP4 recordings were found."
                    return
                }
                var updated = data
                var firstCourse: UUID?
                for group in groups {
                    let index = updated.courses.firstIndex { course in
                        if let folder = group.folder { return course.folderPath == folder.path }
                        return course.id == destination
                    } ?? updated.courses.endIndex
                    if index == updated.courses.endIndex {
                        updated.courses.append(Course(title: group.folder?.lastPathComponent ?? "My Course",
                                                      folderPath: group.folder?.path))
                    }
                    var knownPaths = Set(updated.courses[index].recordings.map(\.path))
                    for file in group.files where knownPaths.insert(file.path).inserted {
                        updated.courses[index].recordings.append(Recording(path: file.path, language: language))
                    }
                    if firstCourse == nil { firstCourse = updated.courses[index].id }
                }
                if commit(updated) {
                    selectedCourse = firstCourse
                    processQueue()
                }
            } catch {
                self.error = "Couldn’t scan the selected recordings. \(error.localizedDescription)"
            }
        }
    }

    func chooseReplacement(for recording: Recording) {
        guard let courseID = selectedCourse else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
        panel.prompt = "Relink"
        panel.message = "Choose the original video for “\(recording.title)” so saved timestamps stay accurate."
        panel.begin { response in
            guard response == .OK, let file = panel.url else { return }
            self.relink(recordingID: recording.id, courseID: courseID, to: file)
        }
    }

    func chooseCourseFolder() {
        guard let courseID = selectedCourse else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Relink"
        panel.message = "Choose the moved course folder. ClipNotes will match each video by its path inside that folder."
        panel.begin { response in
            guard response == .OK, let folder = panel.url,
                  let index = self.data.courses.firstIndex(where: { $0.id == courseID }) else { return }
            var updated = self.data
            do {
                try updated.courses[index].relinkFolder(to: folder)
                if self.commit(updated) { self.processQueue() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func relink(recordingID: UUID, courseID: UUID, to file: URL) {
        let target = file.standardizedFileURL.resolvingSymlinksInPath()
        guard ImportGroup.isReadableVideo(target) else {
            error = RelinkError.invalidFile.localizedDescription
            return
        }
        guard let course = data.courses.first(where: { $0.id == courseID }) else { return }
        guard !course.recordings.contains(where: { $0.id != recordingID && $0.path == target.path }) else {
            error = RelinkError.alreadyLinked.localizedDescription
            return
        }
        if updateRecording(recordingID, edit: {
            $0.path = target.path
            $0.failure = nil
        }) { processQueue() }
    }

    func processQueue() {
        guard readable, worker == nil else { return }
        worker = Task {
            defer { processing = nil; phase = ""; worker = nil }
            while let next = nextRecording() {
                processing = next.id
                phase = "Preparing lesson…"
                var lesson: Lesson?
                var failure: String?
                do {
                    lesson = try await LessonProcessor.process(video: next.url, locale: Locale(identifier: next.language)) { status in
                        await MainActor.run { self.phase = status }
                    }
                } catch {
                    failure = error.localizedDescription
                }
                guard data.courses.contains(where: { course in
                    course.recordings.contains { $0.id == next.id && $0.path == next.path }
                }) else { continue }
                guard updateRecording(next.id, edit: {
                    $0.lesson = lesson
                    $0.failure = failure
                }) else { return }
            }
        }
    }

    func retry(_ recording: Recording) {
        let replacement = Recording(id: recording.id, path: recording.path, language: language)
        if updateRecording(recording.id, edit: { $0 = replacement }) { processQueue() }
    }

    func save(_ passage: Passage, recordingID: UUID) {
        guard let index = data.courses.firstIndex(where: { $0.id == selectedCourse }),
              data.courses[index].recordings.contains(where: { $0.id == recordingID }),
              !isSaved(passage, recordingID: recordingID) else { return }
        var updated = data
        updated.courses[index].guide.append(GuideEntry(recordingID: recordingID, passage: passage))
        _ = commit(updated)
    }

    func isSaved(_ passage: Passage, recordingID: UUID) -> Bool {
        course?.guide.contains { $0.recordingID == recordingID && $0.passage.start == passage.start } == true
    }

    @discardableResult
    func editGuide(courseID: UUID, entryID: UUID, note: String?) -> Bool {
        guard let index = data.courses.firstIndex(where: { $0.id == courseID }),
              let entry = data.courses[index].guide.firstIndex(where: { $0.id == entryID }) else { return false }
        var updated = data
        if let note { updated.courses[index].guide[entry].note = note }
        else { updated.courses[index].guide.remove(at: entry) }
        return commit(updated)
    }

    private func nextRecording() -> Recording? {
        for course in data.courses {
            if let next = course.recordings.first(where: { $0.lesson == nil && $0.failure == nil && $0.sourceAvailable }) { return next }
        }
        return nil
    }

    private func updateRecording(_ id: UUID, edit: (inout Recording) -> Void) -> Bool {
        for (index, course) in data.courses.enumerated() {
            guard let row = course.recordings.firstIndex(where: { $0.id == id }) else { continue }
            var updated = data
            edit(&updated.courses[index].recordings[row])
            return commit(updated)
        }
        return false
    }

    @discardableResult
    private func commit(_ updated: CourseFile) -> Bool {
        guard readable else { return false }
        do {
            try updated.write(to: location)
            data = updated
            return true
        } catch {
            self.error = "Couldn’t save your courses. \(error.localizedDescription)"
            return false
        }
    }
}
