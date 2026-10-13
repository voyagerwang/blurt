#!/usr/bin/env python3
"""Exercise camera App lifecycle with synthetic frames and no camera, screen or mic access.

The source's launch footer is omitted, so the resident application never starts.
Configuration and workspace paths point into a temporary directory. Preview and
recorder capture boundaries are replaced by controlled in-memory doubles, while
the production App setup/start/selection/recording-control callbacks stay intact.
No SCStream construction/start, microphone setup, or writer configuration remains
in the generated executable. Picker display and global hotkeys are also isolated.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from camera_test_isolation import isolate_camera_capture, isolate_camera_panel


def replace_method(source: str, signature: str, following: str, body: str) -> str:
    """Replace an audited method using exact adjacent boundaries; fail on drift."""
    if source.count(signature) != 1:
        raise SystemExit(f"Isolation boundary changed: {signature}")
    start = source.index(signature)
    end = source.find(following, start + len(signature))
    if end < 0:
        raise SystemExit(f"Isolation end boundary changed: {following}")
    indent = signature[: len(signature) - len(signature.lstrip())]
    return source[:start] + signature + "\n" + body + "\n" + indent + "}\n\n" + source[end:]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1] / "skills/blurt/recorder/macos/BlurtRecorder.swift")
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "results")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("These native recorder checks require macOS and Xcode Command Line Tools")
    args.output.mkdir(parents=True, exist_ok=True)
    original = args.source.read_text()
    marker = "// A second copy of the app (double-click while it's running)"
    if original.count(marker) != 1:
        raise SystemExit("Launch boundary changed; review the harness before running")
    source = original.split(marker, 1)[0]
    source = isolate_camera_panel(isolate_camera_capture(source))
    with tempfile.TemporaryDirectory(prefix="blurt-camera-lifecycle-") as temporary:
        root = Path(temporary)
        replacements = {
            'let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".blurt/config.json")':
                f'let configURL = URL(fileURLWithPath: {json.dumps(str(root / "config.json"))})',
            'let homeDir = FileManager.default.homeDirectoryForCurrentUser':
                f'let homeDir = URL(fileURLWithPath: {json.dumps(str(root / "home"))})',
        }
        for old, new in replacements.items():
            if source.count(old) != 1:
                raise SystemExit(f"Isolation boundary changed: {old}")
            source = source.replace(old, new, 1)
        boundaries = [
            ("    func applicationDidFinishLaunching(_ n: Notification) {", "    func hotkey(",
             '        fatalError("TEST SAFETY: real application launch attempted")'),
            ("    func toast(_ text: String) {", "    func permissionHelp() {",
             "        entryToasts.append(text)"),
            ("    func startRecording(useLast: Bool, narrationScript: String? = nil) {", "    func takeEnded(",
             '        fatalError("TEST SAFETY: legacy recording start attempted")'),
            ("    func start(region: CGRect) {", "    func stop() {",
             "        entryPreviewStarts += 1\n        entryPreviewRegions.append(region)"),
            ("    func prepare(completion: @escaping (Error?) -> Void) {", "    func configure(",
             "        if opts.narrationScript != nil { setPrompterEnabled(opts.prompterEnabled, notify: false) }\n        entryPrepareCalls += 1\n        entryPendingPrepareCompletion = completion"),
            ("    func configure(_ content: SCShareableContent) throws {", "    func setupLegacyMic() throws {",
             '        fatalError("TEST SAFETY: recorder configure attempted")'),
            ("    func setupLegacyMic() throws {", "    // --- run",
             '        fatalError("TEST SAFETY: microphone setup attempted")'),
            ("    func start() {", "    func showChrome() {",
             "        entrySyntheticRecorderStarts += 1\n        started = true"),
            ("    func stop(discard: Bool = false, restart: Bool = false) {", "}\n\n// MARK: - Hotkeys",
             "        entrySyntheticRecorderStops += 1\n        stopping = true\n        onWillStop?(restart)\n        cleanupChrome()"),
            ("    func saveNarration(_ dir: URL, duration: Double) {", "    /// Hand the recording",
             '        entrySavedNarrationScript = try? String(contentsOf: dir.appendingPathComponent("script.txt"), encoding: .utf8)'),
            ("    func show(preselect: CGRect?) {", "    func screenFrame(",
             "        entryPickerShows += 1\n        toolbar.controller = self\n        if let preselect = preselect { selection = toNS(preselect) }"),
            ("func registerHotkey(_ k: HK, key: Int, mods: Int) {", "func unregisterHotkey(_ k: HK) {", "    // Isolated: no global key registration."),
            ("func unregisterHotkey(_ k: HK) {", "let optShift =", "    // Isolated: no global key registration."),
            ("func activateApp() {", "func hostNow()", "    // Isolated: do not activate over the user's application."),
        ]
        for signature, following, body in boundaries:
            source = replace_method(source, signature, following, body)
        visibility_double = '''
    // Test-only logical visibility: these windows never reach the window server.
    private var entryLogicalVisible = false
    override var isVisible: Bool { entryLogicalVisible }
    override func makeKeyAndOrderFront(_ sender: Any?) { entryLogicalVisible = true }
    override func orderFrontRegardless() { entryLogicalVisible = true }
    override func orderFront(_ sender: Any?) { entryLogicalVisible = true }
    override func orderOut(_ sender: Any?) { entryLogicalVisible = false }
'''
        for declaration in [
            "private final class NarrationSetupWindow: NSWindow {",
            "private final class StandalonePrompterWindow: NSWindow {",
            "final class TeleprompterPanel: NSPanel, NSWindowDelegate {",
        ]:
            if source.count(declaration) != 1:
                raise SystemExit(f"Window isolation boundary changed: {declaration}")
            source = source.replace(declaration, declaration + visibility_double, 1)
        # Defense in depth: even accidental navigation must have no live capture
        # constructor/start remaining in the generated source.
        forbidden = ["SCShareableContent.get", "SCStream(filter:", ".startCapture", "captureSession?.startRunning()", "AVCaptureDeviceInput(device:"]
        if any(token in source for token in forbidden):
            raise SystemExit("Capture safety check failed; review unisolated capture code")
        source += "\n" + (Path(__file__).parent / "CameraLifecycleHarness.swift").read_text()
        main_swift = root / "main.swift"
        main_swift.write_text(source)
        binary = root / "camera-lifecycle-tests"
        compiled = subprocess.run([
            "xcrun", "swiftc", str(main_swift), "-o", str(binary),
            "-framework", "AppKit", "-framework", "AVFoundation", "-framework", "Carbon",
            "-framework", "CoreMedia", "-framework", "ScreenCaptureKit", "-framework", "ServiceManagement",
        ], text=True, capture_output=True, timeout=120)
        (args.output / "camera-lifecycle-compile.log").write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise SystemExit(f"Compilation failed: {args.output / 'camera-lifecycle-compile.log'}")
        proc = subprocess.run([str(binary), "--lang", "zh"], text=True, capture_output=True, timeout=25)
        (args.output / "camera-lifecycle-test.log").write_text(proc.stdout + proc.stderr)
        reports = []
        for line in proc.stdout.splitlines():
            try:
                reports.append(json.loads(line))
            except json.JSONDecodeError:
                pass
        summary = {
            "source": str(args.source),
            "source_sha256": hashlib.sha256(original.encode()).hexdigest(),
            "passed": proc.returncode == 0 and bool(reports) and reports[-1].get("passed") is True,
            "process_exit": proc.returncode,
            "reports": reports,
            "real_config_accessed": False,
            "screen_or_microphone_recording_started": False,
            "camera_started": False,
            "test_windows_shown_on_user_desktop": False,
            "isolated_boundaries": [signature.strip() for signature, _, _ in boundaries],
            "production_callbacks_retained": ["mNarration", "updateNarrationCamera", "updateNarrationCameraLayout", "refreshNarrationCamera", "closeNarrationCamera", "startNarrationRecording", "begin", "closeNarrationControls", "mStandalonePrompter", "applicationWillTerminate"],
            "limitations": [
                "Tests actual AppKit callback behavior; does not inspect pixels behind macOS lock/privacy overlays.",
                "Preview images are synthetic; recorder preparation/start/stop are controlled doubles with no capture/writer/microphone.",
                "Recorder preparation retains its real teleprompter initialization before the isolated capture boundary.",
                "Picker selection/confirmation callbacks are real, but picker display and global hotkeys are isolated.",
                "Window visibility is an in-memory test double so tests never cover or contaminate the user's ongoing recording.",
                "Export dialog is isolated; successful take completion writes only temporary metadata/script files.",
                "Does not test cross-Space window movement, actual recording exclusion, or MP4 encoding.",
            ],
        }
        (args.output / "camera-lifecycle-summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"passed": summary["passed"], "report": str(args.output / "camera-lifecycle-summary.json"), "checks": len(reports[-1].get("checks", [])) if reports else 0}, ensure_ascii=False))
        raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
