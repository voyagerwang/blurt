# Native narration recorder tests

These standalone checks exercise the macOS narration recorder without recording
the desktop or microphone. They require macOS, Python 3, and Xcode Command Line
Tools. They use only the Python standard library and Apple frameworks.

From the repository root, run:

```sh
python3 tests/test_narration_entry.py
python3 tests/run_synthetic.py
python3 tests/test_setup_displays.py
python3 tests/test_floating_chrome.py
python3 tests/test_standalone_prompter.py
python3 tests/test_standalone_ui.py
```

Each runner reads `skills/blurt/recorder/macos/BlurtRecorder.swift`. Use `--source`
to test another checkout and `--output` to choose an output directory. Reports,
logs, generated images, and generated MP4 files default to `tests/results/`, which
is ignored by Git. Temporary Swift sources and executables are removed afterward.

These are explicit macOS checks, separate from `test_smoke.py`. Importing them via
`python3 -m unittest discover -s tests -v` does not compile or run native code, so
they do not add a macOS dependency to Linux smoke-test discovery.

## Coverage

- `test_standalone_prompter.py` exercises the real standalone entry and lifecycle,
  editing, hidden settings/panel recovery, independent visibility preferences,
  display selection, transitions to/from narration, all feedback-recording
  entry points, busy-state guards, preferred-mode reopening, and teardown. It
  rejects session-directory creation and removes capture/microphone boundaries.
- `test_standalone_ui.py` checks the independent editor in Chinese and English,
  including live updates, immediate draft flush on close, display selection,
  control bounds, transparent corners, and the preparation-only mode switch.
- `test_narration_entry.py` uses the production menu, preview, setup, selection,
  start, restart, and finish callbacks. It checks preview gating, draft retention,
  recording-time editing, prompter toggles, and cancellation. With two attached
  displays it also checks independent recording/prompter targets, display-pinned
  preview and recorder options, and picker clipping and keyboard boundaries. The
  multi-display section reports a skip reason when only one display is available.
- `run_synthetic.py` passes generated image buffers and a generated 440 Hz PCM
  tone through the production writer, buffer handling, and finalization paths. It
  decodes the resulting H.264/AAC MP4 and checks its content, frame/sample counts,
  and duration. It also checks cancellation before start, an already-cancelled
  writer, and a write failure induced by a file-size limit in the test subprocess.
- `test_setup_displays.py` uses synthetic display identifiers and image content
  to check independent display selectors, disabled/missing display states,
  callbacks, and readable Chinese/English layouts at normal and minimum sizes.
- `test_floating_chrome.py` renders the picker and recording controls offscreen in
  Chinese and English. It checks transparent corners, dark edges, control bounds,
  narration-mode widths, and whether background dragging preserves button clicks.

## Isolation and limits

The runners extract current production code into temporary programs. Exact source
boundaries isolate capture, microphone, window ordering, application activation,
and configuration as appropriate for each test. Boundary changes cause a failure
and require reviewing the harness. The entry test uses temporary configuration
and workspace paths; UI tests use in-memory settings. The MP4 test uses temporary
configuration and only generated media.

No runner requests capture permission or launches the resident Blurt application.
Window visibility in the entry/setup tests is a logical test double; raster tests
render their own views without showing windows. Multi-display entry checks read
display metadata, not desktop pixels. Keyboard checks call the offscreen picker
directly and never post system keyboard events.

Passing these tests does not verify actual ScreenCaptureKit application exclusion,
live microphone capture, cross-Space behavior, or external-display disconnects
during a real recording. Those need a separately controlled manual test. A live
desktop-capture integration runner is deliberately not part of this default suite.
