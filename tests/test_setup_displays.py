#!/usr/bin/env python3
"""Focused offscreen setup display-selector checks; no live windows or capture."""
import argparse
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1] / "skills/blurt/recorder/macos/BlurtRecorder.swift")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "results")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("These native recorder checks require macOS and Xcode Command Line Tools")
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    source_path = args.source
    source = source_path.read_text()
    classes = source[source.index('final class PillButton:'):source.index('// Paint the capsule itself:')]
    classes += source[source.index('final class IconButton:'):source.index('final class HUD:')]
    classes += source[source.index('struct NarrationDisplayOption {'):source.index('private final class TeleprompterTextView:')]
    if classes.count('private final class NarrationSetupWindow: NSWindow {') != 1:
        raise SystemExit("Window isolation boundary changed; review the test before running")
    classes = classes.replace('private final class NarrationSetupWindow: NSWindow {', '''private final class NarrationSetupWindow: NSWindow {
        private var visibleForTests = false
        override var isVisible: Bool { visibleForTests }
        override func makeKeyAndOrderFront(_ sender: Any?) { visibleForTests = true }
        override func orderFrontRegardless() { fatalError("No live windows") }
        override func orderFront(_ sender: Any?) { fatalError("No live windows") }
        override func orderOut(_ sender: Any?) { visibleForTests = false }
    ''', 1)
    prefix = '''import AppKit
    struct TestOptions { var lang = "zh" }
    var opts = TestOptions()
    func L(_ zh: String, _ en: String) -> String { opts.lang == "zh" ? zh : en }
    let accent = NSColor(calibratedRed: 1, green: 0.36, blue: 0.24, alpha: 1)
    let chromeSharing: NSWindow.SharingType = .none
    var isolatedConfig: [String: Any] = [:]
    func recordConfig() -> [String: Any] { isolatedConfig }
    func setRecordConfig(_ key: String, _ value: Any?) { isolatedConfig[key] = value }
    func activateApp() {}
    '''
    tail = r'''
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    var checks: [String] = []
    func check(_ value: Bool, _ label: String) { if !value { fatalError(label) }; checks.append(label) }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func choose(_ id: CGDirectDisplayID, _ selector: NarrationDisplaySelector) {
        let item = NSMenuItem(title: "Synthetic display item", action: nil, keyEquivalent: "")
        item.representedObject = NSNumber(value: id)
        _ = NSApp.sendAction(NSSelectorFromString("selectDisplayItem:"), to: selector, from: item)
    }
    for language in ["zh", "en"] {
        opts.lang = language
        isolatedConfig = ["narration_prompter_enabled": false, "narration_script": L("在外接屏演示，在内建屏阅读提词。", "Present on the external display; read the script on the built-in display.")]
        let setup = NarrationSetupController()
        let displayOptions = [NarrationDisplayOption(id: 11, title: L("内建显示屏", "Built-in Retina Display")),
                              NarrationDisplayOption(id: 22, title: "Example External Display")]
        var recordedIDs: [CGDirectDisplayID] = [], prompterIDs: [CGDirectDisplayID] = []
        setup.onSelectRecordingDisplay = { recordedIDs.append($0) }
        setup.onSelectPrompterDisplay = { prompterIDs.append($0) }
        setup.setDisplayOptions(displayOptions, recording: 22, prompter: 11)
        setup.show()
        let window = app.windows.first { $0.isVisible && $0.title == L("录制准备 · Blurt", "Recording setup · Blurt") }!
        let content = window.contentView!
        let selectors = descendants(content).compactMap { $0 as? NarrationDisplaySelector }
        check(selectors.count == 2, "two independent display selectors " + language)
        let recording = selectors.first { $0.accessibilityLabel() == L("录制屏幕", "Recording display") }!
        let prompting = selectors.first { $0.accessibilityLabel() == L("提词器屏幕", "Prompter display") }!
        check(recording.selectedDisplayID == 22 && prompting.selectedDisplayID == 11, "restores separate display targets " + language)
        check(recordedIDs.isEmpty && prompterIDs.isEmpty, "host update emits no selection callbacks " + language)
        choose(11, recording)
        check(recordedIDs == [11] && prompterIDs.isEmpty, "recording selector only changes recording target " + language)
        choose(22, prompting)
        check(prompterIDs == [22] && !setup.prompterEnabled, "prompter display change preserves disabled prompter " + language)
        choose(22, prompting)
        choose(99, prompting)
        check(prompterIDs == [22], "duplicate and unknown display selections ignored " + language)
        setup.setDisplayOptions(displayOptions, recording: 22, prompter: 11)
        setup.setRegion(CGRect(x: 1440, y: 0, width: 1920, height: 1080), label: "External Display · 1920 × 1080")
        let preview = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
            NSColor(calibratedRed: 0.15, green: 0.22, blue: 0.35, alpha: 1).setFill(); rect.fill()
            NSAttributedString(string: "External display", attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: 36, y: 170))
            return true
        }
        setup.setPreview(preview)
        for (suffix, size) in [("default", NSSize(width: 1020, height: 740)), ("min", NSSize(width: 940, height: 680))] {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            let editor = descendants(content).compactMap { $0 as? NSScrollView }.first!
            check(editor.frame.height >= 145, "script editor remains readable " + language + suffix)
            for control in selectors {
                check(control.bounds.width >= 155, "display name control has enough width " + language + suffix)
                check(control.superview!.bounds.contains(control.frame), "display selector fits pane " + language + suffix)
            }
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("setup-displays-" + language + "-" + suffix + ".png")
            try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
        }
        setup.setRecordingMode(true)
        check(!recording.isEnabled && prompting.isEnabled, "recording display locks while prompter destination stays editable " + language)
        choose(11, recording)
        check(recordedIDs == [11], "recording target cannot be switched during a take " + language)
        choose(22, prompting)
        check(prompterIDs == [22, 22] && !setup.prompterEnabled, "prompter target remains independent during recording " + language)
        setup.setDisplayOptions([displayOptions[0]], recording: 22, prompter: 11)
        check(recording.title == L("屏幕已断开", "Display disconnected"), "missing display is explicit rather than silently replaced " + language)
        setup.setDisplayOptions([], recording: nil, prompter: nil)
        check(!recording.isEnabled && !prompting.isEnabled, "empty display list disables both selectors " + language)
        setup.setRecordingMode(false)
        setup.cancel()
    }
    let report: [String: Any] = ["passed": true, "checks": checks, "check_count": checks.count,
                                "windows_shown": false, "screen_or_microphone_capture": false, "real_config_accessed": false]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("setup-displays-report.json"))
    print("PASS: \(checks.count) focused display-selector checks")
    '''
    with tempfile.TemporaryDirectory(prefix="blurt-setup-displays-") as temporary:
        build = Path(temporary)
        harness = build / "main.swift"
        harness.write_text(prefix + classes + tail)
        binary = build / "setup-displays-harness"
        compiled = subprocess.run(["xcrun", "swiftc", str(harness), "-o", str(binary)],
                                  text=True, capture_output=True, timeout=120)
        (root / "setup-displays-compile.log").write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise SystemExit(f"Compilation failed: {root / 'setup-displays-compile.log'}")
        result = subprocess.run([str(binary), str(root)], text=True, capture_output=True, timeout=30)
        (root / "setup-displays-test.log").write_text(result.stdout + result.stderr)
        print(result.stdout)
        if result.returncode:
            raise SystemExit(f"Test failed: {root / 'setup-displays-test.log'}")
    report_path = root / "setup-displays-report.json"
    report = json.loads(report_path.read_text())
    report["source_sha256"] = hashlib.sha256(source.encode()).hexdigest()
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
