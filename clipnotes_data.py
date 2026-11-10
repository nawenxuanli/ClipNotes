"""Durable course data for the portable ClipNotes client."""
import json
import os
from pathlib import Path
import re
import tempfile
import uuid

FORMATS = {".mov", ".mp4"}
COMMON = set("how to a an the do i can you what is are use where does explain me about for of and".split())


def available(path):
    path = Path(path)
    return path.suffix.lower() in FORMATS and path.is_file() and os.access(path, os.R_OK)


def title(record):
    return Path(record["path"]).stem


def stamp(seconds):
    minutes, seconds = divmod(int(seconds), 60)
    return f"{minutes}:{seconds:02}"


def words(text):
    return set(re.findall(r"[^\W_]+", text.casefold()))


def matches(course, query):
    terms = words(query)
    required = terms - COMMON or terms
    if required:
        for record in course["videos"]:
            for moment in record.get("moments") or []:
                if required <= words(moment["text"]):
                    yield record, moment


def recordings(paths):
    for path in paths:
        if path.is_dir():
            yield from (p for p in sorted(path.rglob("*")) if available(p))
        elif available(path):
            yield path


def add_recordings(course, paths):
    known = {os.path.normcase(row["path"]) for row in course["videos"]}
    for path in recordings(paths):
        path = str(path.resolve())
        key = os.path.normcase(path)
        if key not in known:
            known.add(key)
            course["videos"].append(dict(id=uuid.uuid4().hex, path=path, moments=None, error=None))


def relink_file(course, record, path):
    path = path.resolve()
    if not available(path):
        raise ValueError("Choose a readable MOV or MP4 recording.")
    if any(row is not record and os.path.normcase(row["path"]) == os.path.normcase(str(path))
           for row in course["videos"]):
        raise ValueError("That video is already linked to another recording.")
    if str(path) != record["path"]:
        record.update(path=str(path), error=None)


def relink_folder(course, path):
    if not course.get("folder"):
        raise ValueError("This course has no original folder. Relink its recordings individually.")
    root, path = Path(course["folder"]), path.resolve()
    changes = []
    for row in course["videos"]:
        try:
            relative = Path(row["path"]).relative_to(root)
        except ValueError:
            continue
        target = (path / relative).resolve()
        if not target.is_relative_to(path) or not available(target):
            raise ValueError(f"Missing {relative}. Relink reorganized videos individually first.")
        changes.append((row, target))
    if not changes:
        raise ValueError("No recordings are linked to the original folder.")
    changed = {row["id"]: str(target) for row, target in changes}
    paths = [os.path.normcase(changed.get(row["id"], row["path"])) for row in course["videos"]]
    if len(set(paths)) != len(paths):
        raise ValueError("The folder would link multiple recordings to the same file.")
    for row, target in changes:
        if str(target) != row["path"]:
            row.update(path=str(target), error=None)
    course["folder"] = str(path)


class Library:
    def __init__(self, path):
        self.path = path
        try:
            self.courses = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            self.courses = []

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        pending = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.path.parent, delete=False) as stream:
                pending = Path(stream.name)
                json.dump(self.courses, stream, ensure_ascii=False)
                stream.flush()
                os.fsync(stream.fileno())
            pending.replace(self.path)
        finally:
            if pending is not None:
                pending.unlink(missing_ok=True)

    def pending(self):
        return next((row for course in self.courses for row in course["videos"]
                     if row["moments"] is None and not row["error"] and available(row["path"])), None)


class Transcriber:
    def __init__(self, model_root):
        self.model_root = model_root
        self.model = None

    def __call__(self, path):
        from faster_whisper import WhisperModel

        if self.model is None:
            self.model = WhisperModel("base", device="cpu", compute_type="int8",
                                      download_root=str(self.model_root))
        segments, _ = self.model.transcribe(path, beam_size=3, vad_filter=True)
        moments = [dict(start=max(0, segment.start), text=segment.text.strip())
                   for segment in segments if segment.text.strip()]
        if not moments:
            raise ValueError("No speech was detected.")
        return moments
