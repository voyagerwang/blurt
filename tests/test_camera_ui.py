#!/usr/bin/env python3
"""Isolated native camera controls and overlay geometry; never activates any camera."""
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
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent / 'results/camera-ui')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Requires macOS and Xcode Command Line Tools')
    source = args.source.read_text()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    classes = source[source.index('final class PillButton:'):source.index('// Paint the capsule itself:')]
    classes += source[source.index('final class IconButton:'):source.index('final class HUD:')]
    classes += source[source.index('struct NarrationDisplayOption {'):source.index('private final class TeleprompterTextView:')]
    classes += source[source.index('// MARK: - Camera overlay positioning'):source.index('// MARK: - Live recording preview')]
    for declaration in ['private final class NarrationSetupWindow: NSWindow {', 'private final class StandalonePrompterWindow: NSWindow {']:
        if classes.count(declaration) != 1:
            raise SystemExit('Window isolation boundary changed; review this test')
        classes = classes.replace(declaration, declaration + '''
    private var testVisible = false
    override var isVisible: Bool { testVisible }
    override func makeKeyAndOrderFront(_ sender: Any?) { testVisible = true }
    override func orderFrontRegardless() { fatalError("TEST SAFETY: no live window ordering") }
    override func orderFront(_ sender: Any?) { fatalError("TEST SAFETY: no live window ordering") }
    override func orderOut(_ sender: Any?) { testVisible = false }
''', 1)
    panel = 'final class CameraOverlayPanel: NSPanel {'
    classes = classes.replace(panel, panel + '''
    override func makeKeyAndOrderFront(_ sender: Any?) { fatalError("TEST SAFETY: no live window ordering") }
    override func orderFrontRegardless() { fatalError("TEST SAFETY: no live window ordering") }
    override func orderFront(_ sender: Any?) { fatalError("TEST SAFETY: no live window ordering") }
''', 1)
    if any(token in classes for token in ['SCStream', 'AVCapture', 'CGWindowListCreateImage']):
        raise SystemExit('Capture API unexpectedly included in UI test extraction')
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
let primaryHeight: CGFloat = 900
func toCG(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
func toNS(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
'''
    tail = r'''
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var checks: [String] = []
func check(_ value: Bool, _ label: String) { if !value { fatalError(label) }; checks.append(label) }
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
func inside(_ frame: CGRect, _ region: CGRect) -> Bool {
    frame.minX >= region.minX - 0.001 && frame.minY >= region.minY - 0.001 && frame.maxX <= region.maxX + 0.001 && frame.maxY <= region.maxY + 0.001
}
func render(_ content: NSView, name: String, transparentCorners: Bool) {
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let corners = [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)]
    check(corners.allSatisfy { let alpha = bitmap.colorAt(x: $0.0, y: $0.1)!.alphaComponent; return transparentCorners ? alpha == 0 : alpha > 0.99 }, "correct corner alpha " + name)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
}
func syntheticImage() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor(calibratedRed: 0.24, green: 0.48, blue: 0.65, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
    context.setFillColor(accent.cgColor); context.fillEllipse(in: CGRect(x: 90, y: 45, width: 130, height: 150))
    return context.makeImage()!
}
for language in ["zh", "en"] {
    opts.lang = language
    isolatedConfig = ["narration_script": "Synthetic camera test script. The teleprompter stays private."]
    let setup = NarrationSetupController()
    check(!setup.cameraEnabled && setup.cameraCircular && setup.cameraMirrored, "explicit camera off default " + language)
    var cameraChanges: [(Bool, String?, Bool, Bool)] = []
    var sizeChanges: [CGFloat] = []
    var starts = 0
    setup.onCameraChange = { cameraChanges.append(($0, $1, $2, $3)) }
    setup.onCameraSizeChange = { sizeChanges.append($0) }
    setup.onStart = { _, _, _, _ in starts += 1 }
    setup.setCameraDevices([(id: "built-in", name: L("内建摄像头", "Built-in Camera")), (id: "usb", name: "Synthetic USB Camera")], selected: nil)
    check(setup.cameraDeviceID == "built-in" && cameraChanges.isEmpty, "default selection aligns model without capture callback " + language)
    setup.show()
    let window = app.windows.first { $0.isVisible && $0.title == L("录制准备 · Blurt", "Recording setup · Blurt") }!
    let content = window.contentView!
    let all = descendants(content)
    let camera = all.compactMap { $0 as? NarrationToggleButton }.first { $0.symbol == "video.fill" }!
    let device = all.compactMap { $0 as? NSPopUpButton }.first!
    let shape = all.compactMap { $0 as? NSSegmentedControl }.first!
    let size = all.compactMap { $0 as? NSSlider }.first!
    let mirror = all.compactMap { $0 as? NSButton }.first { $0.title == L("镜像", "Mirror") }!
    let start = all.compactMap { $0 as? PillButton }.first { $0.title == L("开始录制", "Start recording") }!
    let script = all.compactMap { $0 as? NSScrollView }.first!
    for (name, dimensions) in [("default", NSSize(width: 1020, height: 740)), ("min", NSSize(width: 940, height: 680))] {
        window.setContentSize(dimensions); content.layoutSubtreeIfNeeded()
        check(content.subviews.allSatisfy { content.bounds.contains($0.frame) }, "top-level controls within window " + language + name)
        check(camera.superview!.subviews.allSatisfy { camera.superview!.bounds.contains($0.frame) }, "preview and camera controls within pane " + language + name)
        check(script.frame.height > 200 && device.frame.width > 260 && size.frame.width > 120, "script and camera controls usable at minimum " + language + name)
        check(!camera.frame.intersects(device.frame) && !shape.frame.intersects(size.frame), "camera rows do not overlap " + language + name)
        render(content, name: "camera-setup-" + language + "-" + name, transparentCorners: true)
    }
    setup.setRegion(CGRect(x: 0, y: 0, width: 1920, height: 1080), label: "Synthetic display")
    setup.setPreview(NSImage(cgImage: syntheticImage(), size: NSSize(width: 320, height: 240)))
    check(start.isEnabled, "screen ready starts without camera " + language)
    camera.performClick(nil)
    check(setup.cameraEnabled && cameraChanges.last?.0 == true && !start.isEnabled, "camera requires explicit toggle and first-frame readiness " + language)
    _ = NSApp.sendAction(start.action!, to: start.target, from: start)
    check(starts == 0, "direct start action cannot bypass camera readiness " + language)
    setup.setCameraStatus("Synthetic camera ready", ready: true)
    check(start.isEnabled, "camera ready unlocks start " + language)
    shape.selectedSegment = 1; _ = NSApp.sendAction(shape.action!, to: shape.target, from: shape)
    check(!setup.cameraCircular && cameraChanges.last?.2 == false, "square selection reaches compositor owner " + language)
    mirror.state = .off; _ = NSApp.sendAction(mirror.action!, to: mirror.target, from: mirror)
    check(!setup.cameraMirrored && cameraChanges.last?.3 == false, "mirror selection reaches compositor owner " + language)
    size.doubleValue = 0.37; _ = NSApp.sendAction(size.action!, to: size.target, from: size)
    check(near(sizeChanges.last ?? 0, 0.37), "size slider reaches overlay owner " + language)
    let priorSizes = sizeChanges.count
    setup.setCameraSize(0.6)
    check(near(CGFloat(size.doubleValue), 0.6) && sizeChanges.count == priorSizes, "host resize updates slider without loop " + language)
    setup.setCameraDevices([(id: "built-in", name: "Built-in Camera")], selected: "unplugged")
    check(setup.cameraDeviceID == "unplugged" && device.selectedItem?.title == L("所选摄像头不可用", "Selected camera unavailable"), "missing device remains visibly unavailable " + language)
    device.selectItem(at: 1); _ = NSApp.sendAction(device.action!, to: device.target, from: device)
    check(setup.cameraDeviceID == "built-in" && !start.isEnabled, "device change requires new ready frame " + language)
    setup.setRecordingMode(true)
    setup.setCameraStatus("Synthetic failure", ready: false)
    check(start.isEnabled && camera.isEnabled && device.isEnabled && shape.isEnabled && size.isEnabled, "camera changes remain available and finish never blocked during take " + language)
    camera.performClick(nil)
    check(!setup.cameraEnabled && start.isEnabled, "turn camera off without blocking recording finish " + language)
    setup.setRecordingMode(false); setup.cancel()

    isolatedConfig = [:]
    let overlay = CameraOverlayPanel()
    var layouts: [CGRect] = []
    var fractions: [CGFloat] = []
    overlay.onLayoutChange = { layouts.append($0) }
    overlay.onSizeChange = { fractions.append($0) }
    let regions = [CGRect(x: 1440, y: 0, width: 1920, height: 1080), CGRect(x: -1920, y: -200, width: 1600, height: 900), CGRect(x: 2750, y: 250, width: 640, height: 360)]
    overlay.setRegion(regions[0])
    check(abs(overlay.frame.width - 259.2) < 1 && near(overlay.frame.width, overlay.frame.height), "default camera occupies 24 percent of short edge " + language)
    check(overlay.normalizedRect.minX < 0.03 && overlay.normalizedRect.minY > 0.7, "default placement bottom-left in top-left coordinates " + language)
    let surface = overlay.contentView as! CameraOverlaySurface
    overlay.setImage(syntheticImage())
    for circular in [true, false] {
        overlay.setShape(circular: circular)
        render(surface, name: "camera-overlay-" + language + (circular ? "-circle" : "-square"), transparentCorners: circular)
    }
    check(overlay.sharingType == chromeSharing && !overlay.isOpaque && !overlay.canBecomeKey, "overlay chrome excluded and nonactivating " + language)
    for (index, region) in regions.enumerated() {
        overlay.setRegion(region)
        check(inside(toCG(overlay.frame), region), "overlay inside selected display or cropped region " + language + String(index))
        surface.onDrag?(.zero, true); surface.onDrag?(NSPoint(x: -10000, y: 10000), false)
        check(inside(toCG(overlay.frame), region), "drag clamps top-left " + language + String(index))
        surface.onDrag?(.zero, true); surface.onDrag?(NSPoint(x: 10000, y: -10000), false)
        check(inside(toCG(overlay.frame), region), "drag clamps bottom-right " + language + String(index))
        overlay.setSizeFraction(0.6)
        check(abs(overlay.frame.width - min(region.width, region.height) * 0.6) < 1 && inside(toCG(overlay.frame), region), "size slider clamps within capture region " + language + String(index))
        for corner in CameraResizeCorner.allCases {
            let bounds = toNS(region)
            let initial = NSRect(x: bounds.midX - 60, y: bounds.midY - 60, width: 120, height: 120)
            for delta in [NSPoint(x: -10000, y: -10000), NSPoint(x: 10000, y: 10000), NSPoint(x: 30, y: -20)] {
                let resized = corner.resizedFrame(from: initial, delta: delta, in: bounds)
                check(near(resized.width, resized.height) && inside(resized, bounds), "four-corner square resize stays inside " + language + String(index) + corner.label + String(Double(delta.x)))
                check(near(corner.isLeft ? resized.maxX : resized.minX, corner.isLeft ? initial.maxX : initial.minX) && near(corner.isTop ? resized.minY : resized.maxY, corner.isTop ? initial.minY : initial.maxY), "opposite resize corner fixed " + language + String(index) + corner.label + String(Double(delta.x)))
            }
        }
    }
    let handle = descendants(surface).compactMap { $0 as? CameraOverlayResizeHandle }.first!
    handle.onResize?(.zero, true); handle.onResize?(NSPoint(x: 15, y: -15), false)
    check(!layouts.isEmpty && !fractions.isEmpty && near(fractions.last!, overlay.frame.width / min(regions.last!.width, regions.last!.height)), "overlay resize publishes normalized position and size " + language)
    overlay.orderOut(nil)
    let savedFrame = overlay.normalizedRect
    let restored = CameraOverlayPanel(); restored.setRegion(regions.last!)
    check(near(restored.normalizedRect.minX, savedFrame.minX) && near(restored.normalizedRect.minY, savedFrame.minY) && near(restored.normalizedRect.width, savedFrame.width), "camera location and size restore " + language)
    let before = restored.frame
    restored.setRegion(.null); restored.setSizeFraction(.nan)
    check(restored.frame == before, "invalid geometry ignored " + language)
    restored.orderOut(nil)
}
let report: [String: Any] = ["passed": true, "checks": checks, "check_count": checks.count,
    "live_windows_shown": false, "camera_screen_or_microphone_capture": false, "real_config_accessed": false]
try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("camera-ui-report.json"))
print("PASS: \(checks.count) camera UI and geometry checks")
'''
    with tempfile.TemporaryDirectory(prefix='blurt-camera-ui-') as temporary:
        build = Path(temporary)
        harness = build / 'main.swift'
        harness.write_text(prefix + classes + tail)
        subprocess.run(['swiftc', str(harness), '-o', str(build / 'camera-ui')], check=True)
        subprocess.run([str(build / 'camera-ui'), str(output)], check=True)
    report_path = output / 'camera-ui-report.json'
    report = json.loads(report_path.read_text())
    report['source_sha256'] = hashlib.sha256(source.encode()).hexdigest()
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
