import AppKit
import Combine
import AVKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ClipNotesApp: App {
    @StateObject private var session = Session()
    @StateObject private var store = CourseStore()

    var body: some Scene {
        Window("ClipNotes", id: "lesson") {
            CourseWorkspace(store: store, session: session)
                .frame(minWidth: 990, minHeight: 590)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1270, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Course Folder…") { store.open(folders: true) }.keyboardShortcut("o")
                Button("Import Videos…") { store.open(folders: false) }
                Button("Export Markdown…") { session.export() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(session.lesson == nil)
            }
        }
    }
}

@MainActor
final class Session: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var url: URL?
    @Published private(set) var lesson: Lesson?
    @Published var phase = ""
    @Published var error: String?
    @Published var active: Passage.ID?
    var title: String { url?.deletingPathExtension().lastPathComponent ?? "No lesson open" }

    func show(_ recording: Recording?, phase: String = "") {
        let source = recording?.sourceAvailable == true ? recording?.url : nil
        if url != recording?.url || (player.currentItem != nil) != (source != nil) {
            player.pause()
            player.replaceCurrentItem(with: source.map { AVPlayerItem(url: $0) })
            url = recording?.url
            active = nil
        }
        lesson = recording?.lesson
        error = recording?.failure
        self.phase = phase
    }

    func jump(to passage: Passage) {
        active = passage.id
        player.seek(to: CMTime(seconds: passage.start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func export() {
        guard let lesson else { return }
        let title = self.title
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = title + " Notes.md"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do { try lesson.markdown(title: title).write(to: url, atomically: true, encoding: .utf8) }
            catch {
                let alert = NSAlert(error: error)
                if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
                else { alert.runModal() }
            }
        }
    }
}

private struct LessonPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

typealias ViewState<Value> = SwiftUI.State<Value>

let canvas = Color(red: 0.062, green: 0.077, blue: 0.10)
let panel = Color(red: 0.095, green: 0.114, blue: 0.144)
let mint = Color(red: 0.62, green: 0.94, blue: 0.81)
let panelBorder = Color.white.opacity(0.09)

struct Workspace: View {
    @ObservedObject var session: Session
    @ViewState private var tab = "Notes"
    @ViewState private var query = ""
    let importVideos: () -> Void
    let retry: () -> Void
    let missing: Bool
    let relink: () -> Void

    var body: some View {
        HSplitView {
            videoPane.frame(minWidth: 345, idealWidth: 610, maxWidth: .infinity, maxHeight: .infinity)
            notesPane.frame(minWidth: 320, idealWidth: 445, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(canvas)
        .onChange(of: session.url) { _, _ in query = ""; tab = "Notes" }
    }

    private var videoPane: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionLabel("VIDEO", icon: "film")
            if session.url != nil {
                Text(session.title).font(.title2.weight(.semibold)).lineLimit(2)
                    .help(session.title)
                if missing {
                    VStack(spacing: 12) {
                        placeholder(icon: "externaldrive.badge.exclamationmark", title: "Video unavailable",
                                    message: "The transcript and notes are still available.")
                        Button("Relink video…", action: relink)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LessonPlayer(player: session.player)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxHeight: .infinity)
                    Label("Select a timestamp to play from that moment.", systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 13) {
                    Image(systemName: "film.stack").font(.system(size: 37, weight: .light))
                        .foregroundStyle(mint).accessibilityHidden(true)
                    Text("Drop a course folder here").font(.title2.weight(.semibold))
                    Text("Import MOV or MP4 recordings to get started.")
                        .foregroundStyle(.secondary)
                    Button("Choose course folder…", action: importVideos)
                        .controlSize(.large).buttonStyle(.borderedProminent).padding(.top, 5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(panel, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(panelBorder, style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
            }
        }
        .padding(20)
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionLabel("LESSON NOTES", icon: "text.alignleft")
            Picker("Lesson view", selection: $tab) {
                Text("Notes").tag("Notes")
                Text("Transcript").tag("Transcript")
            }
            .labelsHidden().pickerStyle(.segmented).disabled(session.lesson == nil)

            if let lesson = session.lesson {
                if tab == "Transcript" {
                    transcript(lesson)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 19) {
                            Text("Summary").font(.headline)
                            ForEach(lesson.summary) { passage in passageRow(passage) }
                            Text("Takeaways").font(.headline)
                            ForEach(lesson.takeaways) { passage in passageRow(passage) }
                        }
                        .padding(.trailing, 6).padding(.bottom, 5)
                    }
                }
            } else if !session.phase.isEmpty {
                placeholder(icon: "waveform", title: session.phase,
                            message: "You can watch the video while ClipNotes works.", busy: true)
            } else if let error = session.error {
                placeholder(icon: "exclamationmark.circle", title: "Couldn’t prepare notes", message: error)
                if session.url != nil && !missing { Button("Retry transcription", action: retry) }
            } else {
                placeholder(icon: "text.document", title: "Your notes will appear here",
                            message: "Open a recording to generate a searchable transcript and jump back to the moments that matter.")
            }
        }
        .padding(20)
        .background(panel)
    }

    private func transcript(_ lesson: Lesson) -> some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = term.isEmpty ? lesson.transcript : lesson.transcript.filter {
            $0.text.localizedStandardContains(term) || $0.timestamp.contains(term)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search transcript", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Search transcript")
                if !query.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
            }
            .padding(10).background(canvas, in: RoundedRectangle(cornerRadius: 8))
            Text(term.isEmpty ? "\(matches.count) passages" : "\(matches.count) of \(lesson.transcript.count) passages")
                .font(.caption).foregroundStyle(.secondary)
            if matches.isEmpty {
                placeholder(icon: "magnifyingglass", title: "No matching passages", message: "Try another word or timestamp.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(matches) { passage in passageRow(passage) }
                    }
                    .padding(.trailing, 6)
                }
            }
        }
    }

    private func passageRow(_ passage: Passage) -> some View {
        Button {
            if missing { relink() } else { session.jump(to: passage) }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Text(passage.timestamp)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(mint)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                Text(passage.text).font(.callout)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                Image(systemName: "play.fill").font(.caption2)
                    .foregroundStyle(.secondary).padding(.top, 5).accessibilityHidden(true)
            }
            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(session.active == passage.id ? mint.opacity(0.13) : canvas.opacity(0.65),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Play from \(passage.timestamp)")
        .accessibilityHint("Plays from this timestamp")
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(mint)
    }

    private func placeholder(icon: String, title: String, message: String, busy: Bool = false) -> some View {
        VStack(spacing: 11) {
            if busy { ProgressView().controlSize(.small) }
            else { Image(systemName: icon).font(.title2).foregroundStyle(mint).accessibilityHidden(true) }
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 260)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
