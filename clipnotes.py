"""Desktop entry point for the Windows and Linux ClipNotes preview."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import os
from pathlib import Path
import sys

from PySide6.QtCore import QStandardPaths, QTimer, QUrl, Qt
from PySide6.QtGui import QIcon
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtWidgets import (
    QApplication, QComboBox, QFileDialog, QHBoxLayout, QInputDialog, QLabel, QLineEdit,
    QListWidget, QListWidgetItem, QMainWindow, QMessageBox, QPushButton, QSlider,
    QSplitter, QTabWidget, QVBoxLayout, QWidget,
)

from clipnotes_data import Library, Transcriber, add_recordings, available, matches, relink_file, relink_folder, stamp, title

ROLE = Qt.ItemDataRole.UserRole
VIDEO_FILTER = "Video recordings (*.mov *.mp4)"


def button(label, action):
    widget = QPushButton(label)
    widget.clicked.connect(action)
    return widget


def page(*widgets):
    widget = QWidget()
    layout = QVBoxLayout(widget)
    for child in widgets:
        layout.addWidget(child)
    return widget


class ClipNotes(QMainWindow):
    def __init__(self, library, transcribe):
        super().__init__()
        self.library, self.transcribe = library, transcribe
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.job = None
        self.path = None
        self.target = None
        self.setWindowTitle("ClipNotes")
        self.setWindowIcon(QIcon(str(Path(__file__).with_name("ClipNotes.png"))))
        self.resize(1140, 720)
        self.setAcceptDrops(True)
        self.courses, self.videos = QComboBox(), QListWidget()
        self.videos.setAccessibleName("Course recordings")
        self.status = QLabel()
        sidebar = page(QLabel("Course library"), self.courses, self.videos, self.status,
                       button("Import folder…", self.import_folder), button("Import videos…", self.import_files),
                       button("Relink folder…", self.move_folder), button("Relink video…", self.move_file),
                       button("Retry failed recording", self.retry))
        self.tabs = QTabWidget()
        self.player = QMediaPlayer(self)
        self.audio = QAudioOutput(self)
        self.player.setAudioOutput(self.audio)
        self.video = QVideoWidget()
        self.video.setMinimumHeight(240)
        self.player.setVideoOutput(self.video)
        self.player.mediaStatusChanged.connect(self.finish_seek)
        self.player.errorOccurred.connect(lambda _error, message: self.statusBar().showMessage(message))
        self.position = QSlider(Qt.Orientation.Horizontal)
        self.position.setAccessibleName("Playback position")
        self.position.sliderMoved.connect(self.player.setPosition)
        self.player.positionChanged.connect(self.position.setValue)
        self.player.durationChanged.connect(lambda duration: self.position.setRange(0, min(duration, 2147483647)))
        controls = QWidget()
        bar = QHBoxLayout(controls)
        bar.addWidget(button("Play", self.player.play))
        bar.addWidget(button("Pause", self.player.pause))
        bar.addWidget(self.position)
        self.video_status = QLabel()
        self.transcript, self.results, self.guide = QListWidget(), QListWidget(), QListWidget()
        for listing in (self.transcript, self.results, self.guide):
            listing.setWordWrap(True)
            listing.itemActivated.connect(self.open_moment)
        self.lesson_search = QLineEdit(placeholderText="Search this transcript")
        self.lesson_search.textChanged.connect(self.refresh_moments)
        self.query = QLineEdit(placeholderText="Search across this course")
        self.query.textChanged.connect(self.refresh_moments)
        self.tabs.addTab(page(self.video_status, self.video, controls, self.lesson_search, self.transcript,
                              button("Play selected passage", lambda: self.open_moment(self.transcript.currentItem())),
                              button("Export transcript…", self.export)), "Lesson")
        self.tabs.addTab(page(self.query, self.results,
                              button("Play result", lambda: self.open_moment(self.results.currentItem())),
                              button("Save result", self.save_moment)), "Course Search")
        self.tabs.addTab(page(self.guide, button("Play saved moment", lambda: self.open_moment(self.guide.currentItem())),
                              button("Add or edit note…", self.edit_note)), "Study Guide")
        split = QSplitter()
        split.addWidget(sidebar)
        split.addWidget(self.tabs)
        split.setSizes([240, 900])
        self.setCentralWidget(split)
        self.courses.currentIndexChanged.connect(self.refresh_videos)
        self.videos.currentItemChanged.connect(self.select_video)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.tick)
        self.timer.start(400)
        self.refresh()

    def course(self):
        return next((course for course in self.library.courses if course["id"] == self.courses.currentData()), None)

    def selected(self):
        item, course = self.videos.currentItem(), self.course()
        return next((row for row in course["videos"] if row["id"] == item.data(ROLE)), None) if item and course else None

    def refresh(self, select=None):
        select = select or self.courses.currentData()
        self.courses.blockSignals(True)
        self.courses.clear()
        for course in self.library.courses:
            self.courses.addItem(course["title"], course["id"])
        self.courses.setCurrentIndex(max(0, self.courses.findData(select)))
        self.courses.blockSignals(False)
        self.refresh_videos()

    def refresh_videos(self):
        current = self.videos.currentItem()
        previous = current.data(ROLE) if current else None
        self.videos.blockSignals(True)
        self.videos.clear()
        course = self.course()
        if course:
            for row in course["videos"]:
                if not available(row["path"]):
                    state = "Missing video"
                elif row["error"]:
                    state = "Failed"
                elif row["moments"] is not None:
                    state = "Ready"
                else:
                    state = "Queued"
                item = QListWidgetItem(f"{title(row)} · {state}")
                item.setData(ROLE, row["id"])
                item.setToolTip(row["error"] or row["path"])
                self.videos.addItem(item)
                if row["id"] == previous:
                    self.videos.setCurrentItem(item)
            if self.videos.currentRow() < 0:
                self.videos.setCurrentRow(0)
        self.videos.blockSignals(False)
        self.select_video()

    def select_video(self):
        self.refresh_source()
        self.refresh_moments()

    def refresh_source(self):
        row = self.selected()
        path = row["path"] if row and available(row["path"]) else None
        if path != self.path:
            self.path, self.target = path, None
            self.player.setSource(QUrl.fromLocalFile(path) if path else QUrl())
        message = "Import a course folder to get started."
        if row:
            message = title(row)
            if not path:
                message += " · Video unavailable. Transcripts and notes are still here."
            elif row["error"]:
                message += " · " + row["error"]
        self.video_status.setText(message)

    def refresh_moments(self):
        for listing in (self.transcript, self.results, self.guide):
            listing.clear()
        course, row = self.course(), self.selected()
        if not course:
            return
        if row:
            query = self.lesson_search.text().strip().casefold()
            for moment in row["moments"] or []:
                if not query or query in moment["text"].casefold() or query in stamp(moment["start"]):
                    self.add_moment(self.transcript, row, moment)
        for recording, moment in matches(course, self.query.text()):
            self.add_moment(self.results, recording, moment)
        by_id = {record["id"]: record for record in course["videos"]}
        for index, entry in enumerate(course["guide"]):
            if entry["video"] in by_id:
                self.add_moment(self.guide, by_id[entry["video"]], entry["moment"], index, entry["note"])

    @staticmethod
    def add_moment(listing, row, moment, index=None, note=""):
        text = f"{stamp(moment['start'])} · {title(row)}\n{moment['text']}"
        if note:
            text += "\nNote: " + note
        item = QListWidgetItem(text)
        item.setData(ROLE, (row["id"], moment, index))
        listing.addItem(item)

    def open_moment(self, item):
        if item is None:
            return
        record_id, moment, _ = item.data(ROLE)
        for index in range(self.videos.count()):
            if self.videos.item(index).data(ROLE) == record_id:
                self.videos.setCurrentRow(index)
                break
        self.tabs.setCurrentIndex(0)
        self.refresh_source()
        if self.path is None:
            self.move_file()
        if self.path is not None:
            self.target = round(moment["start"] * 1000)
            self.finish_seek(self.player.mediaStatus())

    def finish_seek(self, status):
        ready = (QMediaPlayer.MediaStatus.LoadedMedia, QMediaPlayer.MediaStatus.BufferedMedia,
                 QMediaPlayer.MediaStatus.BufferingMedia, QMediaPlayer.MediaStatus.EndOfMedia)
        if self.target is not None and status in ready:
            position, self.target = self.target, None
            self.player.setPosition(position)
            self.player.play()

    def edit(self, change):
        original = deepcopy(self.library.courses)
        try:
            selected = change()
            self.library.save()
        except (OSError, ValueError) as error:
            self.library.courses = original
            self.refresh()
            QMessageBox.warning(self, "ClipNotes", str(error))
            return False
        self.refresh(selected)
        return True

    def add_paths(self, paths, folder=None):
        import uuid

        def change():
            course = self.course() if not folder else next(
                (entry for entry in self.library.courses if entry["folder"] == str(folder.resolve())), None)
            if course is None:
                course = dict(id=uuid.uuid4().hex, title=folder.name if folder else "My Course",
                              folder=str(folder.resolve()) if folder else None, videos=[], guide=[])
                self.library.courses.append(course)
            add_recordings(course, paths)
            if not course["videos"]:
                raise ValueError("No MOV or MP4 recordings found.")
            return course["id"]

        self.edit(change)

    def import_folder(self):
        folder = QFileDialog.getExistingDirectory(self, "Import course folder")
        if folder:
            self.add_paths([Path(folder)], Path(folder))

    def import_files(self):
        files, _ = QFileDialog.getOpenFileNames(self, "Import recordings", filter=VIDEO_FILTER)
        if files:
            self.add_paths([Path(file) for file in files])

    def dragEnterEvent(self, event):
        if any(url.isLocalFile() for url in event.mimeData().urls()):
            event.acceptProposedAction()

    def dropEvent(self, event):
        paths = [Path(url.toLocalFile()) for url in event.mimeData().urls() if url.isLocalFile()]
        for folder in (path for path in paths if path.is_dir()):
            self.add_paths([folder], folder)
        loose = [path for path in paths if not path.is_dir()]
        if loose:
            self.add_paths(loose)
        event.acceptProposedAction()

    def move_file(self):
        row = self.selected()
        if row:
            file, _ = QFileDialog.getOpenFileName(self, "Choose the original video at its new location", filter=VIDEO_FILTER)
            if file:
                self.edit(lambda: relink_file(self.course(), row, Path(file)))

    def move_folder(self):
        course = self.course()
        if course:
            folder = QFileDialog.getExistingDirectory(self, "Select the moved course folder")
            if folder:
                self.edit(lambda: relink_folder(course, Path(folder)))

    def retry(self):
        row = self.selected()
        if row and row["error"]:
            self.edit(lambda: row.update(error=None))

    def tick(self):
        self.refresh_source()
        if self.job:
            record_id, path, future = self.job
            if not future.done():
                return
            self.job = None
            row = next((row for course in self.library.courses for row in course["videos"]
                        if row["id"] == record_id and row["path"] == path), None)
            if row:
                try:
                    moments, error = future.result(), None
                except Exception as failure:
                    moments, error = None, str(failure) or type(failure).__name__
                if not self.edit(lambda: row.update(moments=moments, error=error)):
                    self.timer.stop()
                    return
        row = self.library.pending()
        if row:
            self.job = (row["id"], row["path"], self.executor.submit(self.transcribe, row["path"]))
        self.status.setText("Transcribing… First use downloads the model." if row else "")

    def save_moment(self):
        item, course = self.results.currentItem(), self.course()
        if item and course:
            record_id, moment, _ = item.data(ROLE)
            if not any(entry["video"] == record_id and entry["moment"]["start"] == moment["start"] for entry in course["guide"]):
                self.edit(lambda: course["guide"].append(dict(video=record_id, moment=moment, note="")))
            self.statusBar().showMessage("Saved to Study Guide", 2000)

    def edit_note(self):
        item = self.guide.currentItem()
        if item:
            _, _, index = item.data(ROLE)
            entry = self.course()["guide"][index]
            note, accepted = QInputDialog.getMultiLineText(self, "Study guide note", "Your note", entry["note"])
            if accepted:
                self.edit(lambda: entry.update(note=note))

    def export(self):
        row = self.selected()
        if row and row["moments"]:
            target, _ = QFileDialog.getSaveFileName(self, "Export transcript", title(row) + ".md", "Markdown (*.md)")
            if target:
                lines = [f"# {title(row)}", ""]
                lines += [f"- **{stamp(moment['start'])}** {moment['text']}" for moment in row["moments"]]
                try:
                    Path(target).write_text("\n".join(lines) + "\n", encoding="utf-8")
                except OSError as error:
                    QMessageBox.warning(self, "ClipNotes", str(error))


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("ClipNotes")
    smoke = "--smoke-test" in sys.argv
    root = Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppLocalDataLocation))
    try:
        library = Library(root / "courses.json")
    except (OSError, ValueError) as error:
        QMessageBox.critical(None, "ClipNotes", f"Could not open courses: {error}")
        return 1
    window = ClipNotes(library, Transcriber(root / "models"))
    window.show()
    if smoke:
        window.timer.stop()
        QTimer.singleShot(150, app.quit)
    code = app.exec()
    if window.job and not window.job[2].done():
        # The unfinished recording is already persisted as queued.
        os._exit(code)
    window.executor.shutdown(wait=False, cancel_futures=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
