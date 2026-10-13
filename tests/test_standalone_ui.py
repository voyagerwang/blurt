#!/usr/bin/env python3
"""Offscreen standalone prompter UI checks; no application launch or capture."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1] / 'skills/blurt/recorder/macos/BlurtRecorder.swift')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent / 'results')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('These native checks require macOS and Xcode Command Line Tools')
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    source = args.source.read_text()
    classes = source[source.index('final class PillButton:'):source.index('// Paint the capsule itself:')]
    classes += source[source.index('final class IconButton:'):source.index('final class HUD:')]
    classes += source[source.index('struct NarrationDisplayOption {'):source.index('private final class TeleprompterTextView:')]
    for declaration in ['private final class NarrationSetupWindow: NSWindow {', 'private final class StandalonePrompterWindow: NSWindow {']:
        if classes.count(declaration) != 1:
            raise SystemExit('Window isolation boundary changed; review the test')
        classes = classes.replace(declaration, declaration + '''
    private var testVisible = false
    override var isVisible: Bool { testVisible }
    override func makeKeyAndOrderFront(_ sender: Any?) { testVisible = true }
    override func orderFrontRegardless() { fatalError("TEST SAFETY: no live window ordering") }
    override func orderFront(_ sender: Any?) { fatalError("TEST SAFETY: no live window ordering") }
    override func orderOut(_ sender: Any?) { testVisible = false }
''', 1)
    if any(token in classes for token in ['SCStream', 'AVCapture', 'CGWindowListCreateImage']):
        raise SystemExit('Unexpected capture API in UI test extraction')
    prefix = '''import AppKit
struct TestOptions { var lang = "zh" }
var opts = TestOptions()
func L(_ zh: String, _ en: String) -> String { opts.lang == "zh" ? zh : en }
let accent = NSColor(calibratedRed: 1, green: 0.36, blue: 0.24, alpha: 1)
let chromeSharing: NSWindow.SharingType = .none
var isolatedConfig: [String: Any] = [:]
var writtenKeys: [String] = []
func recordConfig() -> [String: Any] { isolatedConfig }
func setRecordConfig(_ key: String, _ value: Any?) { isolatedConfig[key] = value; writtenKeys.append(key) }
func activateApp() {}
'''
    tail = r'''
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var checks: [String] = []
func check(_ value: Bool, _ label: String) { if !value { fatalError(label) }; checks.append(label) }
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
func shownWindow(_ title: String) -> NSWindow { app.windows.first { $0.isVisible && $0.title == title }! }
func choose(_ id: CGDirectDisplayID, _ target: NSButton) {
    let item = NSMenuItem(title: "Synthetic display", action: nil, keyEquivalent: "")
    item.representedObject = NSNumber(value: id)
    _ = NSApp.sendAction(NSSelectorFromString("selectDisplayItem:"), to: target, from: item)
}
func setScript(_ value: String, in editor: NSTextView, owner: StandalonePrompterController) {
    editor.string = value
    owner.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
}
func render(_ content: NSView, name: String) {
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let corners = [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)]
    check(corners.allSatisfy { bitmap.colorAt(x: $0.0, y: $0.1)!.alphaComponent == 0 }, "transparent window corners " + name)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
}
for language in ["zh", "en"] {
    opts.lang = language
    isolatedConfig = ["narration_script": "Synthetic shared script", "narration_prompter_enabled": false, "narration_microphone_enabled": false]
    writtenKeys = []
    let standalone = StandalonePrompterController()
    check(standalone.prompterEnabled, "independent prompter defaults on regardless of recording toggle " + language)
    check(standalone.scriptValue == "Synthetic shared script", "shares narration script " + language)
    var changes: [(String, Bool)] = []
    var ids: [CGDirectDisplayID] = []
    var hides = 0
    standalone.onChange = { changes.append(($0, $1)) }
    standalone.onSelectDisplay = { ids.append($0) }
    standalone.onHide = { hides += 1 }
    let options = [NarrationDisplayOption(id: 11, title: L("内建显示屏", "Built-in Display")),
                   NarrationDisplayOption(id: 22, title: L("示例外接显示屏", "Example External Display"))]
    standalone.setDisplayOptions(options, selected: 22)
    standalone.show()
    let window = shownWindow(L("提词器设置 · Blurt", "Teleprompter settings · Blurt"))
    let content = window.contentView!
    check(!window.isOpaque && window.backgroundColor.alphaComponent == 0 && window.collectionBehavior.contains(.moveToActiveSpace), "clear borderless window on current Space " + language)
    let editor = descendants(content).compactMap { $0 as? NSTextView }.first!
    let scroll = descendants(content).compactMap { $0 as? NSScrollView }.first!
    let selector = descendants(content).compactMap { $0 as? NarrationDisplaySelector }.first!
    let toggle = descendants(content).compactMap { $0 as? NarrationToggleButton }.first!
    let done = descendants(content).compactMap { $0 as? PillButton }.first!
    check(editor.isEditable && editor.allowsUndo && !editor.isRichText, "plain script editing and undo available " + language)
    check(selector.selectedDisplayID == 22 && changes.isEmpty && ids.isEmpty, "host display update is callback-free " + language)
    check(!descendants(content).compactMap { $0 as? NSButton }.contains { $0.title.contains("录制") || $0.title.lowercased().contains("record") }, "standalone settings have no recording controls " + language)
    for (name, size) in [("default", NSSize(width: 700, height: 650)), ("min", NSSize(width: 580, height: 520))] {
        window.setContentSize(size)
        content.layoutSubtreeIfNeeded()
        check(scroll.frame.height >= 190 && selector.frame.width >= 250, "editor and selector readable " + language + name)
        check(content.subviews.allSatisfy { content.bounds.contains($0.frame) }, "settings controls stay inside window " + language + name)
        render(content, name: "standalone-" + language + "-" + name)
    }
    setScript("Live synthetic edit", in: editor, owner: standalone)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
    check(changes.last?.0 == "Live synthetic edit" && changes.last?.1 == true, "debounced changes reach live prompter " + language)
    check(isolatedConfig["narration_script"] as? String == "Live synthetic edit", "live edit saves shared script " + language)
    toggle.performClick(nil)
    check(!standalone.prompterEnabled && isolatedConfig["standalone_prompter_enabled"] as? Bool == false, "toggle saves independent enabled setting " + language)
    choose(11, selector)
    check(ids == [11] && !standalone.prompterEnabled, "display change preserves hidden prompter " + language)
    setScript("Finish flushes newest draft", in: editor, owner: standalone)
    done.performClick(nil)
    check(!window.isVisible && hides == 1 && changes.last?.0 == "Finish flushes newest draft", "Done hides only settings and flushes immediately " + language)
    check(!standalone.prompterEnabled, "Done preserves enabled state " + language)
    standalone.show()
    check(shownWindow(window.title) === window && editor.string == "Finish flushes newest draft", "reopen retains same editor and draft " + language)
    standalone.setPrompterEnabled(true)
    setScript("Escape draft", in: editor, owner: standalone)
    window.cancelOperation(nil)
    check(!window.isVisible && hides == 2 && standalone.prompterEnabled && changes.last?.0 == "Escape draft", "Escape flushes settings while prompter remains enabled " + language)
    standalone.show()
    let closeButton = descendants(content).compactMap { $0 as? IconButton }.first!
    setScript("Close control draft", in: editor, owner: standalone)
    closeButton.performClick(nil)
    check(!window.isVisible && hides == 3 && changes.last?.0 == "Close control draft", "close control hides and flushes " + language)
    standalone.show()
    check(!standalone.windowShouldClose(window) && !window.isVisible && hides == 4, "window close follows hide semantics " + language)
    standalone.show()
    setScript("Released draft", in: editor, owner: standalone)
    standalone.close()
    check(!window.isVisible && hides == 4 && standalone.scriptValue == "Released draft" && changes.last?.0 == "Released draft", "teardown flushes and releases without hide callback " + language)
    standalone.show()
    check(shownWindow(window.title) !== window && standalone.scriptValue == "Released draft", "released controller can rebuild without losing draft " + language)
    standalone.close()
    check(writtenKeys.allSatisfy { $0 == "narration_script" || $0 == "standalone_prompter_enabled" }, "standalone writes only shared script and independent enabled preference " + language)
    check(isolatedConfig["narration_prompter_enabled"] as? Bool == false && isolatedConfig["narration_microphone_enabled"] as? Bool == false, "recording preferences untouched " + language)
    isolatedConfig["standalone_prompter_enabled"] = false
    let restored = StandalonePrompterController()
    check(!restored.prompterEnabled, "restores standalone disabled state " + language)
    restored.close()

    let setup = NarrationSetupController()
    var standaloneRequests = 0
    var dispatchedDraft = ""
    setup.onUseStandalone = { standaloneRequests += 1; dispatchedDraft = isolatedConfig["narration_script"] as? String ?? "" }
    setup.show()
    let prep = shownWindow(L("录制准备 · Blurt", "Recording setup · Blurt"))
    prep.setContentSize(NSSize(width: 940, height: 680))
    let prepContent = prep.contentView!
    prepContent.layoutSubtreeIfNeeded()
    let entry = descendants(prepContent).compactMap { $0 as? PillButton }.first { $0.title == L("仅用提词器", "Teleprompter only") }!
    check(entry.isEnabled && !entry.isHidden && prepContent.bounds.contains(entry.frame), "standalone entry visible in preparation " + language)
    let footerControls = prepContent.subviews.compactMap { $0 as? NSButton }.filter { abs($0.frame.midY - entry.frame.midY) < 1 }
    check(footerControls.allSatisfy { $0 === entry || !$0.frame.intersects(entry.frame) }, "standalone entry does not overlap footer controls at minimum size " + language)
    let prepEditor = descendants(prepContent).compactMap { $0 as? NSTextView }.first!
    prepEditor.string = "Switching preserves latest draft"
    setup.textDidChange(Notification(name: NSText.didChangeNotification, object: prepEditor))
    entry.performClick(nil)
    check(standaloneRequests == 1 && dispatchedDraft == prepEditor.string, "mode switch flushes draft before callback " + language)
    setup.setRecordingMode(true)
    check(entry.isHidden && !entry.isEnabled, "standalone entry hidden and disabled during take " + language)
    _ = NSApp.sendAction(entry.action!, to: entry.target, from: entry)
    check(standaloneRequests == 1, "direct action cannot switch during recording " + language)
    setup.setRecordingMode(false)
    setup.cancel()
}
let report: [String: Any] = ["passed": true, "checks": checks, "check_count": checks.count,
                            "windows_shown": false, "screen_or_microphone_capture": false, "real_config_accessed": false]
let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("standalone-prompter-report.json"))
print("PASS: \(checks.count) standalone prompter checks")
'''
    with tempfile.TemporaryDirectory(prefix='blurt-standalone-ui-') as temporary:
        build = Path(temporary)
        harness = build / 'main.swift'
        harness.write_text(prefix + classes + tail)
        binary = build / 'standalone-ui'
        result = subprocess.run(['xcrun', 'swiftc', str(harness), '-o', str(binary)], text=True, capture_output=True, timeout=120)
        (root / 'standalone-compile.log').write_text(result.stdout + result.stderr)
        if result.returncode:
            raise SystemExit(f"Compilation failed: {root / 'standalone-compile.log'}")
        result = subprocess.run([str(binary), str(root)], text=True, capture_output=True, timeout=30)
        (root / 'standalone-test.log').write_text(result.stdout + result.stderr)
        print(result.stdout)
        if result.returncode:
            raise SystemExit(f"Tests failed: {root / 'standalone-test.log'}")
    report_path = root / 'standalone-prompter-report.json'
    report = json.loads(report_path.read_text())
    report['source_sha256'] = hashlib.sha256(source.encode()).hexdigest()
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
