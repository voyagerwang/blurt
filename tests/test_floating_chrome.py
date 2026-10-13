#!/usr/bin/env python3
"""Offscreen AppKit raster checks for HUD/picker capsules, with inert collaborators."""
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
    classes = source[source.index('final class PillButton:'):source.index('// MARK: - Recording chrome:')]
    classes += source[source.index('final class LevelView:'):source.index('func overlayWindow(')]
    # A safety net: future edits cannot accidentally order test HUDs onto the desktop.
    if classes.count('final class HUD: NSPanel {') != 1:
        raise SystemExit("Window isolation boundary changed; review the test before running")
    classes = classes.replace('final class HUD: NSPanel {', '''final class HUD: NSPanel {
        override func orderFrontRegardless() { fatalError("TEST SAFETY: no HUD window ordering") }
        override func makeKeyAndOrderFront(_ sender: Any?) { fatalError("TEST SAFETY: no HUD window ordering") }
        override func orderFront(_ sender: Any?) { fatalError("TEST SAFETY: no HUD window ordering") }
    ''', 1)
    prefix = '''import AppKit
    struct TestOptions { var lang = "zh"; var narrationScript: String? }
    var opts = TestOptions()
    func L(_ zh: String, _ en: String) -> String { opts.lang == "zh" ? zh : en }
    let accent = NSColor(calibratedRed: 1, green: 0.36, blue: 0.24, alpha: 1)
    let amber = NSColor(calibratedRed: 1, green: 0.76, blue: 0.24, alpha: 1)
    let chromeSharing: NSWindow.SharingType = .none
    func toNS(_ rect: CGRect) -> NSRect { rect }
    func activateApp() { fatalError("TEST SAFETY: activation is not permitted") }
    final class Recorder: NSObject {
        var isPaused = false
        var prompterVisible = true
        var onEditNarration: (() -> Void)?
        func togglePause() { isPaused.toggle() }
        func stop(discard: Bool = false, restart: Bool = false) { fatalError("TEST SAFETY: recording is not present") }
        func setPrompterEnabled(_ enabled: Bool) { prompterVisible = enabled }
    }
    final class PickerController {
        var selectionOnly = false
        func fullScreen() {}
        func useLast() {}
        func finish(_ confirmed: Bool) {}
    }
    '''
    tail = r'''
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    var checks: [String] = []
    var cases: [[String: Any]] = []
    func verify(_ value: Bool, _ name: String) {
        if !value { fatalError("FAILED: " + name) }
        checks.append(name)
    }
    func raster(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
        let alpha = corners.map { rep.colorAt(x: $0.0, y: $0.1)!.alphaComponent }
        verify(alpha.allSatisfy { $0 == 0 }, "all four corners are transparent: " + name)
        let topCenter = rep.colorAt(x: w / 2, y: 2)!.usingColorSpace(.deviceRGB)!
        verify(topCenter.redComponent < 0.2 && topCenter.greenComponent < 0.2 && topCenter.blueComponent < 0.2,
               "capsule edge is dark without a white outline: " + name)
        verify(!view.subviews.contains { $0 is NSVisualEffectView }, "no visual-effect backing: " + name)
        for subview in view.subviews {
            verify(view.bounds.contains(subview.frame), "child stays within capsule: " + name + " / " + String(describing: type(of: subview)))
        }
        let out = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png")
        try! rep.representation(using: .png, properties: [:])!.write(to: out)
        cases.append(["name": name, "width_points": view.bounds.width, "height_points": view.bounds.height,
                      "corner_alpha": alpha, "image": out.path])
    }
    for language in ["zh", "en"] {
        opts.lang = language
        var hudWidths: [CGFloat] = []
        for narration in [false, true] {
            opts.narrationScript = narration ? "Synthetic script" : nil
            let recorder = Recorder()
            let hud = HUD(rec: recorder)
            verify(!hud.isVisible && !hud.isOpaque && hud.backgroundColor.alphaComponent == 0,
                   "HUD window remains hidden and clear: " + language + " / \(narration)")
            hud.update(elapsed: 94, paused: false, level: 0.62)
            let mode = narration ? "narration" : "feedback"
            let surface = hud.contentView!
            verify(surface is BlurtFloatingSurfaceView, "HUD uses painted capsule: " + mode)
            verify(hud.isMovable && hud.isMovableByWindowBackground && surface.mouseDownCanMoveWindow,
                   "HUD background permits window dragging: " + mode)
            let controls = surface.subviews.compactMap { $0 as? NSButton }
            verify(controls.allSatisfy { !$0.mouseDownCanMoveWindow }, "HUD controls keep clicks instead of dragging: " + mode)
            verify(controls.count == (narration ? 5 : 3), "HUD includes expected mode controls: " + mode)
            let finish = controls.first { $0 is PillButton }!
            verify(abs(surface.bounds.width - finish.frame.maxX - 8) < 0.01, "HUD finish has eight-point right inset: " + mode)
            raster(surface, "hud-" + language + "-" + mode)
            hud.update(elapsed: 94, paused: true, level: 0)
            raster(surface, "hud-" + language + "-" + mode + "-paused")
            hudWidths.append(surface.bounds.width)
        }
        verify(abs(hudWidths[1] - hudWidths[0] - 72) < 0.01, "narration HUD adds two 36-point control slots: " + language)
        for selectionOnly in [false, true] {
            for hasLast in [false, true] {
                let controller = PickerController()
                controller.selectionOnly = selectionOnly
                let toolbar = PickerToolbar(frame: .zero)
                toolbar.controller = controller
                toolbar.layoutButtons(hasLast: hasLast)
                verify(!toolbar.mouseDownCanMoveWindow, "picker toolbar does not add background dragging")
                let mode = selectionOnly ? "selection" : "recording"
                let name = "picker-" + language + "-" + mode + (hasLast ? "-last" : "")
                let controls = toolbar.subviews.compactMap { $0 as? NSButton }
                verify(controls.count == (hasLast ? 4 : 3), "picker has expected controls: " + name)
                verify(abs(toolbar.bounds.width - controls.last!.frame.maxX - 6) < 0.01, "picker right inset is six points: " + name)
                verify(controls.last!.title == (selectionOnly ? L("使用此区域", "Use this area") : L("开始录制", "Start recording")), "picker mode label matches action: " + name)
                raster(toolbar, name)
            }
        }
    }
    let report: [String: Any] = ["passed": true, "check_count": checks.count, "checks": checks, "cases": cases,
                                "windows_shown": false, "screen_or_microphone_capture": false, "real_config_accessed": false]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("floating-chrome-report.json"))
    print("PASS: \(checks.count) native AppKit checks across \(cases.count) offscreen raster cases")
    '''
    with tempfile.TemporaryDirectory(prefix="blurt-floating-chrome-") as temporary:
        build = Path(temporary)
        harness = build / "main.swift"
        harness.write_text(prefix + classes + tail)
        binary = build / "floating-chrome-harness"
        compiled = subprocess.run(["xcrun", "swiftc", str(harness), "-o", str(binary)],
                                  text=True, capture_output=True, timeout=120)
        (root / "floating-chrome-compile.log").write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise SystemExit(f"Compilation failed: {root / 'floating-chrome-compile.log'}")
        result = subprocess.run([str(binary), str(root)], text=True, capture_output=True, timeout=30)
        (root / "floating-chrome-test.log").write_text(result.stdout + result.stderr)
        print(result.stdout)
        if result.returncode:
            raise SystemExit(f"Test failed: {root / 'floating-chrome-test.log'}")
    report_path = root / "floating-chrome-report.json"
    report = json.loads(report_path.read_text())
    report["source_sha256"] = hashlib.sha256(source.encode()).hexdigest()
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
