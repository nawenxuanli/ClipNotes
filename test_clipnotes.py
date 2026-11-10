import tempfile
import unittest
from pathlib import Path

from clipnotes_data import Library, add_recordings, available, matches, relink_file, relink_folder


class CourseTest(unittest.TestCase):
    def test_move_course_and_resume_pending(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            folder = root / "Course"
            nested = folder / "Week 2"
            nested.mkdir(parents=True)
            (folder / "Intro.mov").touch()
            (nested / "Reports.mp4").touch()
            course = dict(id="course", title="Course", folder=str(folder), videos=[], guide=[])
            add_recordings(course, [folder, folder])
            self.assertEqual(len(course["videos"]), 2)
            intro, reports = course["videos"]
            moment = dict(start=2.25, text="Use a pivot table to group sales by region.")
            intro["moments"] = [moment]
            course["guide"].append(dict(video=intro["id"], moment=moment, note="Review before class"))
            library = Library(root / "courses.json")
            library.courses.append(course)
            library.save()

            moved = folder.rename(root / "Moved Course")
            restarted = Library(library.path)
            course = restarted.courses[0]
            self.assertFalse(any(available(row["path"]) for row in course["videos"]))
            self.assertEqual(len(list(matches(course, "how to use a pivot table"))), 1)
            self.assertIsNone(restarted.pending())
            with self.assertRaises(ValueError):
                relink_folder(course, root)
            self.assertEqual(course["folder"], str(folder))

            relink_folder(course, moved)
            self.assertEqual(restarted.pending()["id"], reports["id"])
            renamed = (moved / "Intro.mov").rename(moved / "Lesson.mov")
            relink_file(course, course["videos"][0], renamed)
            restarted.save()
            final = Library(library.path).courses[0]
            self.assertEqual(final["guide"][0]["note"], "Review before class")
            self.assertEqual(final["guide"][0]["moment"]["start"], 2.25)
            self.assertEqual(final["videos"][0]["id"], intro["id"])
            self.assertTrue(all(available(row["path"]) for row in final["videos"]))


if __name__ == "__main__":
    unittest.main()
