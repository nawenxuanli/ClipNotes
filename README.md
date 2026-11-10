# ClipNotes 2.1

ClipNotes is a desktop workspace for recorded courses. This build runs on Apple silicon Macs with macOS 26 or later. Source is included.

## Import and study a course

1. Unzip the download and open ClipNotes.app.
2. Select the spoken language, then drop a folder into the window or use **Import > Import Course Folder**. ClipNotes includes MOV and MP4 files in subfolders and transcribes them on the Mac. The first use of a language may require an internet connection to download Apple's speech model.
3. Open **Course Search** to find matching transcript passages across the selected course. Results show the lecture title, a short excerpt, and a clickable timestamp. Search matches keywords within each passage.
4. Use **Save moment** to bookmark a result. In **Study Guide**, select **Add note** to attach your own text or click a saved timestamp to play the source.
5. In **Lessons**, browse a recording's summary, takeaways, and transcript. **Export Markdown** saves those three sections for the current lecture.

Courses, transcripts, and study notes are saved locally. ClipNotes links to the videos in their original folders. Transcripts, search results, and study guides remain available if a video moves or its drive is disconnected.

## Restore a video link

- If you renamed or moved one recording, choose **Relink video** in Lessons or click its saved timestamp to select the original recording at its new location.
- If you moved the whole course, use **Import > Relink Course Folder** and select the new folder. ClipNotes matches the original paths inside that folder. Relink renamed or reorganized files individually first.
- For an external drive, reconnect it to restore videos at their original paths. If the paths changed, use the relink controls.
- Pending recordings resume when ClipNotes reopens. Select a failed recording in Lessons and choose **Retry transcription**.

## Build from source

With the macOS 26 SDK or later and the Apple command-line developer tools installed, run `bash build.sh` from the project folder. The app appears under `build/ClipNotes.app`.

## Compare ClipNotes with scrubbing

Pick three real lesson recordings. Write two comparable prompts per recording and mark the correct explanation's start and end times ahead of the session. Use prompts such as “Find where the instructor explains why step two matters.”

- Give each participant one prompt per lesson with ClipNotes and the other prompt with the video player alone. Alternate the order and swap which prompts use ClipNotes across participants.
- Start the timer when the prompt appears. For ClipNotes, have transcription ready before timing and record preparation time separately.
- Stop when the participant plays the explanation or after 90 seconds. Record seconds, whether they found the right passage, and any transcript or timestamp errors.
- Compare median time on successful attempts and report the success rate for each method. Track timeouts separately.

The Mac app was tested with a 2:26 MOV golf lesson. It produced 50 transcript passages, two summary excerpts, and five takeaways. Search, playback from a timestamp, and Markdown export were checked. The timed participant study is pending.
