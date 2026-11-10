import AppKit
import SwiftUI

struct CourseWorkspace: View {
    @ObservedObject var store: CourseStore
    @ObservedObject var session: Session
    @ViewState private var page: Page = .lessons
    @ViewState private var searchQuery = ""
    @ViewState private var selectedRecording: UUID?
    @ViewState private var dropping = false
    @ViewState private var sourceRefresh = 0
    @ViewState private var editor: NoteDraft?

    private enum Page: String, CaseIterable {
        case lessons = "Lessons"
        case search = "Course Search"
        case guide = "Study Guide"
    }

    private struct NoteDraft: Identifiable {
        let courseID: UUID
        let entry: GuideEntry
        var id: UUID { entry.id }
    }

    private let languages = [
        ("English (US)", "en-US"), ("English (UK)", "en-GB"), ("Mandarin (China)", "zh-CN"),
        ("Spanish (Spain)", "es-ES"), ("French (France)", "fr-FR"), ("German", "de-DE"),
        ("Japanese", "ja-JP"), ("Korean", "ko-KR")
    ]

    private var recording: Recording? {
        store.course?.recordings.first(where: { $0.id == selectedRecording })
    }

    private var progress: String {
        guard let recording, recording.lesson == nil, recording.failure == nil else { return "" }
        return store.processing == recording.id ? store.phase : "Waiting in the import queue…"
    }

    private struct DisplayState: Equatable {
        let id: UUID?
        let ready: Bool
        let path: String?
        let available: Bool
        let failure: String?
        let phase: String
    }

    private var display: DisplayState {
        let _ = sourceRefresh
        return DisplayState(id: recording?.id, ready: recording?.lesson != nil,
                     path: recording?.path, available: recording?.sourceAvailable == true,
                     failure: recording?.failure, phase: progress)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                VStack(spacing: 0) {
                    Picker("Course view", selection: $page) {
                        ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 400)
                    .padding(14)
                    Divider()
                    content
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(canvas)
        .tint(mint)
        .task { store.processQueue() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSources()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            refreshSources()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            refreshSources()
        }
        .onChange(of: store.selectedCourse, initial: true) { _, _ in
            selectedRecording = store.course?.recordings.first?.id
            searchQuery = ""
            page = .lessons
        }
        .onChange(of: display, initial: true) { _, _ in session.show(recording, phase: progress) }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !store.scanning else { return false }
            store.importURLs(urls)
            return true
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).strokeBorder(mint, lineWidth: 3)
                    .padding(5).allowsHitTesting(false)
            }
        }
        .alert("ClipNotes", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.error ?? "") }
        .sheet(item: $editor) { draft in
            GuideNoteEditor(note: draft.entry.note) { note in
                store.editGuide(courseID: draft.courseID, entryID: draft.entry.id, note: note)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(canvas)
                .frame(width: 34, height: 34).background(mint, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text("ClipNotes").font(.title3.bold())
            Spacer()
            Menu {
                ForEach(languages, id: \.1) { language in
                    Button {
                        store.language = language.1
                    } label: {
                        if store.language == language.1 { Label(language.0, systemImage: "checkmark") }
                        else { Text(language.0) }
                    }
                }
            } label: {
                Label(languages.first { $0.1 == store.language }?.0 ?? "Language", systemImage: "globe")
            }
            .fixedSize()
            .help("Spoken language for new imports and retries")
            Menu("Import", systemImage: "folder.badge.plus") {
                Button("Import Course Folder…") { store.open(folders: true) }
                Button("Import Videos…") { store.open(folders: false) }
                Divider()
                Button("Relink Course Folder…", action: store.chooseCourseFolder)
                    .disabled(store.course?.folderPath == nil)
                Button("Relink Selected Video…") {
                    if let recording { store.chooseReplacement(for: recording) }
                }
                .disabled(recording == nil)
            }
            .disabled(store.scanning)
            Button("Export Markdown", systemImage: "square.and.arrow.up", action: session.export)
                .disabled(session.lesson == nil)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("COURSE LIBRARY")
                .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(mint)
            if !store.data.courses.isEmpty {
                Picker("Course", selection: $store.selectedCourse) {
                    ForEach(store.data.courses) { course in
                        Text(course.title).tag(Optional(course.id))
                    }
                }
                .labelsHidden()
            }
            if let course = store.course {
                let ready = course.recordings.filter { $0.lesson != nil }.count
                let missing = course.recordings.filter { !$0.sourceAvailable }.count
                Text("\(ready) of \(course.recordings.count) searchable" + (missing == 0 ? "" : " · \(missing) missing"))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(course.recordings) { recording in
                            Button {
                                selectedRecording = recording.id
                                page = .lessons
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: statusIcon(recording))
                                        .foregroundStyle(recording.failure == nil ? mint : .orange)
                                        .accessibilityHidden(true)
                                    Text(recording.title).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(8)
                                .background(selectedRecording == recording.id ? mint.opacity(0.15) : canvas.opacity(0.65),
                                            in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .help(recording.failure ?? recording.path)
                        }
                    }
                }
            } else {
                Text("Drop a folder to create a course. Videos in subfolders are included.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            if store.scanning {
                HStack { ProgressView().controlSize(.small); Text("Finding recordings…").font(.caption) }
            } else if store.processing != nil {
                HStack { ProgressView().controlSize(.small); Text("Processing recordings").font(.caption) }
            }
        }
        .padding(13)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(panel)
    }

    private func refreshSources() {
        sourceRefresh += 1
        store.processQueue()
    }

    private func statusIcon(_ recording: Recording) -> String {
        if !recording.sourceAvailable { return "externaldrive.badge.exclamationmark" }
        if recording.failure != nil { return "exclamationmark.circle" }
        if recording.lesson != nil { return "checkmark.circle" }
        return store.processing == recording.id ? "waveform" : "clock"
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .lessons:
            Workspace(session: session, importVideos: { store.open(folders: true) }, retry: {
                if let recording { store.retry(recording) }
            }, missing: recording != nil && !display.available, relink: {
                if let recording { store.chooseReplacement(for: recording) }
            })
        case .search:
            CourseSearch(course: store.course, query: $searchQuery, open: play, save: store.save, isSaved: store.isSaved)
                .id(store.selectedCourse)
        case .guide:
            guide
        }
    }

    private func play(_ passage: Passage, _ recordingID: UUID) {
        guard let source = store.course?.recordings.first(where: { $0.id == recordingID }) else { return }
        guard source.sourceAvailable else {
            store.chooseReplacement(for: source)
            return
        }
        selectedRecording = recordingID
        session.show(source)
        session.jump(to: passage)
        page = .lessons
    }

    @ViewBuilder private var guide: some View {
        if let course = store.course, !course.guide.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("Study Guide").font(.title2.bold())
                    ForEach(course.guide) { entry in
                        let title = course.recordings.first { $0.id == entry.recordingID }?.title ?? "Source recording"
                        VStack(alignment: .leading, spacing: 8) {
                            MomentButton(title: title, passage: entry.passage) {
                                play(entry.passage, entry.recordingID)
                            }
                            if !entry.note.isEmpty {
                                Text(entry.note).font(.callout).textSelection(.enabled)
                                    .padding(.horizontal, 10).padding(.bottom, 2)
                            }
                            HStack {
                                Button(entry.note.isEmpty ? "Add note…" : "Edit note…", systemImage: "pencil") {
                                    editor = NoteDraft(courseID: course.id, entry: entry)
                                }
                                Button("Remove", systemImage: "bookmark.slash") {
                                    store.editGuide(courseID: course.id, entryID: entry.id, note: nil)
                                }
                            }
                            .padding(.horizontal, 10).padding(.bottom, 10)
                        }
                        .background(panel, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("Your study guide is empty", systemImage: "bookmark",
                                   description: Text("Save a moment from Course Search to collect it here."))
        }
    }
}

private struct CourseSearch: View {
    let course: Course?
    @Binding var query: String
    let open: (Passage, UUID) -> Void
    let save: (Passage, UUID) -> Void
    let isSaved: (Passage, UUID) -> Bool
    @ViewState private var hits: [SearchHit] = []
    @ViewState private var completed: Request?

    private struct Request: Equatable {
        let query: String
        let searchablePaths: [String]
    }

    private var request: Request {
        Request(query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                searchablePaths: course?.recordings.filter { $0.lesson != nil }.map(\.path) ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search this course").font(.title2.bold())
            TextField("Search course transcripts", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search course transcripts")
            if request.query.isEmpty {
                ContentUnavailableView("Find an explanation", systemImage: "magnifyingglass",
                                       description: Text("Enter keywords from any recording in this course."))
            } else if completed != request {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hits.isEmpty {
                ContentUnavailableView("No matching passages", systemImage: "magnifyingglass",
                                       description: Text("Try fewer keywords or check whether the recording is searchable."))
            } else {
                Text("\(hits.count) matching \(hits.count == 1 ? "moment" : "moments")")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(hits) { hit in
                            HStack {
                                MomentButton(title: hit.title, passage: hit.passage) { open(hit.passage, hit.recordingID) }
                                let saved = isSaved(hit.passage, hit.recordingID)
                                Button(saved ? "Saved" : "Save moment", systemImage: saved ? "bookmark.fill" : "bookmark") {
                                    save(hit.passage, hit.recordingID)
                                }
                                .disabled(saved)
                                .padding(.trailing, 10)
                            }
                            .background(panel, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: request) {
            let pending = request
            let snapshot = course
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                snapshot?.search(pending.query) ?? []
            }.value
            guard !Task.isCancelled else { return }
            hits = result
            completed = pending
        }
    }
}

private struct MomentButton: View {
    let title: String
    let passage: Passage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text(passage.timestamp)
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(mint)
                    .padding(5)
                    .background(mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(passage.text).font(.callout).lineLimit(3).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .multilineTextAlignment(.leading)
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays this recording from \(passage.timestamp)")
    }
}

private struct GuideNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState var note: String
    let save: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Study Guide Note").font(.headline)
            TextEditor(text: $note).accessibilityLabel("Study guide note")
                .frame(minHeight: 130)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Note") { if save(note) { dismiss() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 430)
    }
}
