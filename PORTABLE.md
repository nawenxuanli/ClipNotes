# ClipNotes desktop preview

Source preview for Windows and Linux. The existing macOS app has its own Swift build and library. This preview keeps its course data separate.

Use 64-bit Python 3.11 in a virtual environment, install `requirements.txt`, then run `python clipnotes.py`. On Linux, install Qt's desktop runtime libraries for your distribution. Import a course folder or drag in recordings. The first transcription downloads the Whisper base model, and speech processing runs locally. The player uses Qt Multimedia and playback depends on codec support.

## Build and test

- Run `python -m unittest -v test_clipnotes.py` for local persistence, search, pending work, and relinking checks.
- Run `python clipnotes.py --smoke-test` to check that the Qt window starts.
- On Windows, install `pyinstaller==6.12.0` and run `python -m PyInstaller --noconfirm --windowed --name ClipNotes --collect-all faster_whisper --collect-all av --collect-all ctranslate2 --collect-all onnxruntime clipnotes.py` from this folder. Keep the entire `dist/ClipNotes` directory together.
- For Store packaging, install the Windows SDK and run `./package-windows.ps1 -Identity '<Package/Identity/Name>' -Publisher '<Package/Identity/Publisher>' -PublisherDisplayName '<publisher display name>'` with the values from the Partner Center product identity. The resulting unsigned MSIX is a submission candidate. Test the installer and app on Windows before submitting.
