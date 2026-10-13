// BlurtRecorder — native macOS recorder for blurt (ScreenCaptureKit + AVAssetWriter).
//
// Flow: region picker (drag / click a window / F = full screen) → 3-2-1 countdown → recording with a floating
// control bar (timer, mic level, pause, marker, stop) that is never captured. Output: H.264/AAC mp4 + events.jsonl
// (pauses, markers, clicks, cursor samples). Built on first use by record.py with `swiftc`.
//
// Control: HUD buttons, global hotkeys (⌥⇧P pause/resume, ⌥⇧M marker, ⌥⇧S stop), stdin lines
// ("pause" | "resume" | "toggle" | "marker" | "stop"), or SIGTERM/SIGINT (= stop).
// stdout: one JSON object per line: ready, selected, countdown, recording, paused, resumed, marker, level?, stopped,
// cancelled, error.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import CoreImage
import ScreenCaptureKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Options & utilities

struct Options {
    var out = ""
    var events: String? = nil
    var standalone = false         // launched as an app (no --out): lives in the menu bar, records into a workspace
    var fps = 30
    var maxWidth = 2560
    var countdown = 3
    var lang = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? "zh" : "en"
    var region: CGRect? = nil      // skip picker (global top-left points)
    var lastRegion: CGRect? = nil  // offered in the picker
    var preselect: CGRect? = nil   // picker opens with this selection (testing / "last region")
    var mic = true
    var micName: String? = nil
    var narrationScript: String? = nil
    var prompterEnabled = true
    var recordingDisplayID: CGDirectDisplayID?
    var recordingDisplayFrame: CGRect?

    static func parse() -> Options {
        var o = Options()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        func rect(_ s: String?) -> CGRect? {
            guard let p = s?.split(separator: ",").compactMap({ Double($0) }), p.count == 4 else { return nil }
            return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
        }
        while let a = it.next() {
            switch a {
            case "--out": o.out = it.next() ?? o.out
            case "--events": o.events = it.next()
            case "--fps": o.fps = Int(it.next() ?? "") ?? o.fps
            case "--max-width": o.maxWidth = Int(it.next() ?? "") ?? o.maxWidth
            case "--countdown": o.countdown = Int(it.next() ?? "") ?? o.countdown
            case "--lang": o.lang = it.next() ?? o.lang
            case "--region": o.region = rect(it.next())
            case "--last-region": o.lastRegion = rect(it.next())
            case "--preselect": o.preselect = rect(it.next())
            case "--no-mic": o.mic = false
            case "--mic": o.micName = it.next()
            default: break
            }
        }
        if o.out.isEmpty { o.standalone = true }
        return o
    }
}

// MARK: - Config shared with record.py (~/.blurt/config.json)

let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".blurt/config.json")

func readConfig() -> [String: Any] {
    guard let d = try? Data(contentsOf: configURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

func recordConfig() -> [String: Any] { readConfig()["record"] as? [String: Any] ?? [:] }

func setRecordConfig(_ key: String, _ value: Any?) {
    var cfg = readConfig()
    var rec = cfg["record"] as? [String: Any] ?? [:]
    rec[key] = value
    cfg["record"] = rec
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: configURL) }
}

func saveLastRegion(_ r: CGRect) { setRecordConfig("last_region", [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]) }

func lastRegionFromConfig() -> CGRect? {
    guard let r = recordConfig()["last_region"] as? [Double], r.count == 4 else { return nil }
    return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
}

var opts = Options.parse()
func L(_ zh: String, _ en: String) -> String { opts.lang == "zh" ? zh : en }

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let s = String(data: d, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}

/// Global coordinates: AppKit uses bottom-left origin, CoreGraphics / ScreenCaptureKit use top-left.
var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
func toCG(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
func toNS(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }

func narrationDisplayID(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}
func narrationDisplayUUID(_ id: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
}
func narrationScreen(_ id: CGDirectDisplayID?) -> NSScreen? {
    guard let id = id else { return nil }
    return NSScreen.screens.first { narrationDisplayID($0) == id }
}

/// Legacy sharing hint only. Blurt's SCContentFilter excludes this entire application, including later windows.
/// Other recording apps choose their own filters and may capture these windows.
let chromeSharing: NSWindow.SharingType = ProcessInfo.processInfo.environment["BLURT_DEBUG_CHROME"] == nil ? .none : .readOnly

func activateApp() {
    if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
}

func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

let accent = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.24, alpha: 1)   // coral
let amber = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.24, alpha: 1)

func pill(_ text: String, font: NSFont, fg: NSColor, bg: NSColor, at p: NSPoint, pad: CGFloat = 8) -> NSRect {
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg])
    let sz = s.size()
    let r = NSRect(x: p.x, y: p.y, width: sz.width + pad * 2, height: sz.height + pad)
    bg.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    s.draw(at: NSPoint(x: r.minX + pad, y: r.minY + pad / 2))
    return r
}

// MARK: - Region picker

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { contentView?.keyDown(with: event) }
    override func cancelOperation(_ sender: Any?) { (contentView as? PickerView)?.controller?.finish(false) }
}

final class PickerController {
    var windows: [KeyWindow] = []
    var selection: NSRect?          // global AppKit coords
    var snapped = false             // selection came from clicking a window (or F / last area): drag = draw new
    var hovered: NSRect?
    var onDone: ((CGRect?) -> Void)?
    var selectionOnly = false
    var targetDisplayID: CGDirectDisplayID?
    let toolbar = PickerToolbar()
    var toolbarHost: NSView?

    func show(preselect: CGRect?) {
        for screen in NSScreen.screens where targetDisplayID == nil || narrationDisplayID(screen) == targetDisplayID {
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.acceptsMouseMovedEvents = true
            let v = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.controller = self
            v.screen = screen
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        toolbar.controller = self
        if let p = preselect { selection = toNS(p) }
        activateApp()
        let mouse = NSEvent.mouseLocation
        let keyWin = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first
        keyWin?.makeKeyAndOrderFront(nil)
        if let w = keyWin { w.makeFirstResponder(w.contentView) }
        refresh()
        emit(["event": "ready"])
    }

    func screenFrame(containing p: NSPoint) -> NSRect {
        if let target = narrationScreen(targetDisplayID) { return target.frame }
        return (NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.screens[0]).frame
    }

    func refresh() {
        windows.forEach { $0.contentView?.needsDisplay = true }
        placeToolbar()
    }

    func placeToolbar() {
        toolbar.removeFromSuperview()
        guard let sel = selection, sel.width >= 8, sel.height >= 8,
              let win = windows.first(where: { $0.frame.intersects(sel) }), let host = win.contentView else { return }
        toolbar.layoutButtons(hasLast: opts.lastRegion != nil)
        let size = toolbar.frame.size
        let local = NSRect(origin: NSPoint(x: sel.minX - win.frame.minX, y: sel.minY - win.frame.minY), size: sel.size)
        var origin = NSPoint(x: local.midX - size.width / 2, y: local.minY - size.height - 14)
        if origin.y < 12 { origin.y = local.maxY + 14 }                            // no room below → above
        if origin.y + size.height > host.bounds.height - 12 { origin.y = local.minY + 14 } // inside, bottom
        origin.x = max(12, min(origin.x, host.bounds.width - size.width - 12))
        toolbar.setFrameOrigin(origin)
        host.addSubview(toolbar)
        toolbarHost = host
    }

    func finish(_ start: Bool) {
        var result: CGRect?
        if start, let selection = selection {
            if let targetID = targetDisplayID {
                // Confirm against the chosen display again: keyboard nudges or
                // a changed screen layout must never retarget the recording.
                if let screen = narrationScreen(targetID) {
                    let clipped = toCG(selection).integral.intersection(toCG(screen.frame))
                    if !clipped.isNull, clipped.width >= 8, clipped.height >= 8 { result = clipped }
                }
            } else {
                result = toCG(selection).integral
            }
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        onDone?(result)
    }

    func fullScreen() {
        selection = screenFrame(containing: NSEvent.mouseLocation)
        snapped = true
        refresh()
    }

    func useLast() {
        if let l = opts.lastRegion {
            let r = targetDisplayID == nil ? toNS(l) : toNS(l).intersection(screenFrame(containing: NSEvent.mouseLocation))
            guard !r.isNull, r.width >= 8, r.height >= 8 else { return }
            selection = r; snapped = true; refresh()
        }
    }
}

final class PickerView: NSView {
    weak var controller: PickerController?
    weak var screen: NSScreen?
    enum Mode { case none, create(NSPoint), move(NSPoint, NSRect), resize(Int, NSRect) }
    var mode: Mode = .none
    var downAt: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    func global(_ e: NSEvent) -> NSPoint { window!.convertPoint(toScreen: e.locationInWindow) }
    func local(_ r: NSRect) -> NSRect { r.offsetBy(dx: -window!.frame.minX, dy: -window!.frame.minY) }

    func handles(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.maxX, y: r.midY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
    }

    override func draw(_ dirty: NSRect) {
        guard let c = controller else { return }
        let hole = (c.selection ?? c.hovered).map(local)
        let dim = NSBezierPath(rect: bounds)
        if let h = hole {
            dim.append(NSBezierPath(rect: h))
            dim.windingRule = .evenOdd
        }
        NSColor(white: 0, alpha: 0.42).setFill()
        dim.fill()
        // Fully transparent pixels let clicks fall through to the app underneath — keep the hole a hair opaque.
        if let h = hole {
            NSColor(white: 0, alpha: 0.012).setFill()
            NSBezierPath(rect: h).fill()
        }

        if let sel = c.selection.map(local) {
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let b = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            b.lineWidth = 1.5
            b.stroke()
            for p in handles(sel) {
                let r = NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                NSColor.white.setFill()
                NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
                accent.setStroke()
                let hb = NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5)
                hb.lineWidth = 1
                hb.stroke()
            }
            let scale = screen?.backingScaleFactor ?? 2
            let label = "\(Int(sel.width)) × \(Int(sel.height))  ·  \(Int(sel.width * scale))×\(Int(sel.height * scale))px"
            let f = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            var at = NSPoint(x: sel.minX, y: sel.maxY + 8)
            if at.y + 26 > bounds.height { at.y = sel.maxY - 30; at.x = sel.minX + 8 }
            _ = pill(label, font: f, fg: .white, bg: NSColor(white: 0.08, alpha: 0.82), at: at)
        } else if let h = hole {
            accent.withAlphaComponent(0.9).setStroke()
            let b = NSBezierPath(rect: h.insetBy(dx: 1.5, dy: 1.5))
            b.lineWidth = 3
            b.setLineDash([10, 6], count: 2, phase: 0)
            b.stroke()
            let f = NSFont.systemFont(ofSize: 12, weight: .semibold)
            _ = pill(L("单击选中这个窗口 · 或直接拖拽框选", "Click to pick this window · or drag to draw"), font: f, fg: .white,
                     bg: accent.withAlphaComponent(0.92), at: NSPoint(x: h.minX + 10, y: max(10, h.maxY - 34)))
        }

        // hint on every screen, top centre
        let hint = c.selectionOnly
            ? L("拖拽框选录制区域 · 单击选中窗口 · F 全屏 · ⏎ 确认 · Esc 返回", "Drag an area · Click a window · F full screen · ⏎ confirm · Esc back")
            : L("拖拽框选录制区域 · 单击选中窗口 · F 全屏 · ⏎ 开始 · Esc 取消", "Drag to select an area · Click a window · F full screen · ⏎ start · Esc cancel")
        let f = NSFont.systemFont(ofSize: 13, weight: .medium)
        let w = NSAttributedString(string: hint, attributes: [.font: f]).size().width + 28
        _ = pill(hint, font: f, fg: .white, bg: NSColor(white: 0.06, alpha: 0.78),
                 at: NSPoint(x: bounds.midX - w / 2, y: bounds.height - 64), pad: 14)
    }

    override func mouseMoved(with e: NSEvent) {
        guard let c = controller, c.selection == nil else { return }
        let r = windowRect(at: global(e))
        if r != c.hovered { c.hovered = r; c.refresh() }
    }

    func windowRect(at p: NSPoint) -> NSRect? {
        let cg = CGPoint(x: p.x, y: primaryHeight - p.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = Int(getpid())
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int) != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width > 40, r.height > 40, r.contains(cg) {
                return toNS(r).intersection(controller!.screenFrame(containing: p))
            }
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) {
        guard let c = controller else { return }
        let p = global(e)
        downAt = p
        if e.clickCount == 2, let s = c.selection, s.contains(p) { c.finish(true); return }
        if let s = c.selection {
            for (i, h) in handles(s).enumerated() where hypot(h.x - p.x, h.y - p.y) < 10 {
                mode = .resize(i, s); return
            }
            if s.contains(p) && !c.snapped { mode = .move(p, s); return }
        }
        mode = .create(p)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let c = controller else { return }
        let p = global(e)
        let bounds = c.screenFrame(containing: downAt)
        switch mode {
        case .create(let s):
            guard hypot(p.x - s.x, p.y - s.y) > 4 else { return }
            drawRect(from: s, to: p, in: bounds)
        case .move(let s, let r):
            var n = r.offsetBy(dx: p.x - s.x, dy: p.y - s.y)
            n.origin.x = min(max(n.minX, bounds.minX), bounds.maxX - n.width)
            n.origin.y = min(max(n.minY, bounds.minY), bounds.maxY - n.height)
            c.selection = n
        case .resize(let i, let r):
            var (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
            if [0, 6, 7].contains(i) { x0 = p.x }
            if [2, 3, 4].contains(i) { x1 = p.x }
            if [0, 1, 2].contains(i) { y0 = p.y }
            if [4, 5, 6].contains(i) { y1 = p.y }
            c.selection = NSRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
                .intersection(bounds)
            c.snapped = false
        case .none: break
        }
        c.refresh()
    }

    func drawRect(from s: NSPoint, to p: NSPoint, in bounds: NSRect) {
        guard let c = controller else { return }
        let q = NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        c.selection = NSRect(x: min(s.x, q.x), y: min(s.y, q.y), width: abs(q.x - s.x), height: abs(q.y - s.y))
        c.snapped = false
        c.hovered = nil
    }

    override func mouseUp(with e: NSEvent) {
        guard let c = controller else { return }
        if case .create(let s) = mode {
            let p = global(e)
            if hypot(p.x - s.x, p.y - s.y) <= 4 {
                if let h = c.hovered ?? windowRect(at: s) { c.selection = h; c.snapped = true; c.hovered = nil }
            } else {
                drawRect(from: s, to: p, in: c.screenFrame(containing: downAt))   // drag events can be coalesced
            }
        }
        if let s = c.selection, s.width < 16 || s.height < 16 { c.selection = nil }
        mode = .none
        c.refresh()
    }

    override func keyDown(with e: NSEvent) {
        guard let c = controller else { return }
        switch Int(e.keyCode) {
        case kVK_Escape:
            if c.selection != nil && e.modifierFlags.contains(.shift) { c.selection = nil; c.refresh() } else { c.finish(false) }
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: if c.selection != nil { c.finish(true) }
        case kVK_ANSI_F: c.fullScreen()
        case kVK_ANSI_L: c.useLast()
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            guard var s = c.selection else { return }
            let d: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            switch Int(e.keyCode) {
            case kVK_LeftArrow: s.origin.x -= d
            case kVK_RightArrow: s.origin.x += d
            case kVK_UpArrow: s.origin.y += d
            default: s.origin.y -= d
            }
            if let target = narrationScreen(c.targetDisplayID) {
                s.size.width = min(s.width, target.frame.width)
                s.size.height = min(s.height, target.frame.height)
                s.origin.x = max(target.frame.minX, min(s.minX, target.frame.maxX - s.width))
                s.origin.y = max(target.frame.minY, min(s.minY, target.frame.maxY - s.height))
            }
            c.selection = s
            c.refresh()
        default: super.keyDown(with: e)
        }
    }
}

final class PillButton: NSButton {
    var fill: NSColor = NSColor(white: 1, alpha: 0.12)
    var fg: NSColor = .white
    var hovering = false { didSet { needsDisplay = true } }

    convenience init(_ title: String, symbol: String? = nil, fill: NSColor, fg: NSColor = .white, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.fill = fill
        self.fg = fg
        self.target = target
        self.action = action
        isBordered = false
        if let s = symbol { image = NSImage(systemSymbolName: s, accessibilityDescription: title) }
        let w = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            .size().width + (symbol == nil ? 28 : 46)
        setFrameSize(NSSize(width: w, height: 32))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override var allowsVibrancy: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        (hovering ? fill.blended(withFraction: 0.18, of: .white) ?? fill : fill).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        let s = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: fg])
        var x = (bounds.width - s.size().width) / 2
        if let img = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .bold).applying(.init(paletteColors: [fg]))) {
            x += 9
            let sz = img.size
            img.draw(in: NSRect(x: x - 9 - sz.width, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height))
        }
        s.draw(at: NSPoint(x: x, y: (bounds.height - s.size().height) / 2))
    }
}

// Paint the capsule itself: visual-effect materials can composite a rectangular
// backing through clear window corners even when their layer is rounded.
class BlurtFloatingSurfaceView: NSView {
    var permitsWindowDrag = false
    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { false }
    override var mouseDownCanMoveWindow: Bool { permitsWindowDrag }
    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.075, alpha: 0.97).setFill()
        let radius = min(bounds.height / 2, 24)
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

final class PickerToolbar: BlurtFloatingSurfaceView {
    weak var controller: PickerController?
    private var built = false

    func layoutButtons(hasLast: Bool) {
        if built { return }
        built = true
        appearance = NSAppearance(named: .darkAqua)
        var buttons: [NSButton] = []
        buttons.append(PillButton(L("全屏", "Full screen"), symbol: "arrow.up.left.and.arrow.down.right",
                                  fill: NSColor(white: 1, alpha: 0.1), target: self, action: #selector(full)))
        if hasLast {
            buttons.append(PillButton(L("上次区域", "Last area"), symbol: "clock.arrow.circlepath",
                                      fill: NSColor(white: 1, alpha: 0.1), target: self, action: #selector(last)))
        }
        buttons.append(PillButton(L("取消", "Cancel"), fill: NSColor(white: 1, alpha: 0.1), target: self, action: #selector(cancel)))
        buttons.append(PillButton(controller?.selectionOnly == true ? L("使用此区域", "Use this area") : L("开始录制", "Start recording"), symbol: "record.circle.fill", fill: accent,
                                  target: self, action: #selector(start)))
        var x: CGFloat = 6
        for b in buttons {
            b.setFrameOrigin(NSPoint(x: x, y: 6))
            addSubview(b)
            x += b.frame.width + 6
        }
        setFrameSize(NSSize(width: x, height: 44))
    }
    @objc func full() { controller?.fullScreen() }
    @objc func last() { controller?.useLast() }
    @objc func cancel() { controller?.finish(false) }
    @objc func start() { controller?.finish(true) }
}

// MARK: - Recording chrome: border, countdown, HUD

final class BorderView: NSView {
    var color: NSColor = accent { didSet { needsDisplay = true } }
    override func draw(_ dirty: NSRect) {
        color.setStroke()
        let b = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        b.lineWidth = 2.5
        b.stroke()
    }
}

final class CountdownView: NSView {
    var n = 3 { didSet { needsDisplay = true } }
    var onSkip: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onSkip?() }
    override func draw(_ dirty: NSRect) {
        let d: CGFloat = 132
        let r = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        NSColor(white: 0.05, alpha: 0.72).setFill()
        NSBezierPath(ovalIn: r).fill()
        accent.setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3))
        ring.lineWidth = 3
        ring.stroke()
        let s = NSAttributedString(string: "\(n)", attributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.white])
        s.draw(at: NSPoint(x: r.midX - s.size().width / 2, y: r.midY - s.size().height / 2))
        let sub = NSAttributedString(string: L("准备，开喷", "Get ready to blurt"), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
        _ = pill(sub.string, font: NSFont.systemFont(ofSize: 13, weight: .medium), fg: .white,
                 bg: NSColor(white: 0.05, alpha: 0.72), at: NSPoint(x: bounds.midX - (sub.size().width + 24) / 2, y: r.minY - 40), pad: 12)
        let hint = L("⌥⇧P 暂停 / 继续   ·   ⌥⇧S 完成   ·   点一下跳过倒计时",
                     "⌥⇧P pause / resume   ·   ⌥⇧S finish   ·   click to skip")
        let hf = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let hw = NSAttributedString(string: hint, attributes: [.font: hf]).size().width + 24
        _ = pill(hint, font: hf, fg: NSColor(white: 1, alpha: 0.85), bg: NSColor(white: 0.05, alpha: 0.6),
                 at: NSPoint(x: bounds.midX - hw / 2, y: r.minY - 76), pad: 12)
    }
}

final class LevelView: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    var muted = false { didSet { needsDisplay = true } }
    override func draw(_ dirty: NSRect) {
        let bars = 5
        let w: CGFloat = 3, gap: CGFloat = 2.5
        for i in 0..<bars {
            let th = Float(i + 1) / Float(bars + 1)
            let h = CGFloat(4 + i * 3)
            let r = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            (muted ? NSColor(white: 1, alpha: 0.2) : (level >= th ? NSColor.systemGreen : NSColor(white: 1, alpha: 0.22))).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

final class IconButton: NSButton {
    var tint: NSColor = .white { didSet { needsDisplay = true } }
    var bg: NSColor = NSColor(white: 1, alpha: 0.1)
    var hovering = false { didSet { needsDisplay = true } }
    var symbol = "" { didSet { needsDisplay = true } }
    convenience init(symbol: String, tip: String, bg: NSColor = NSColor(white: 1, alpha: 0.1), target: AnyObject, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        self.symbol = symbol
        self.bg = bg
        toolTip = tip
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override var allowsVibrancy: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirty: NSRect) {
        (hovering ? bg.blended(withFraction: 0.25, of: .white) ?? bg : bg).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                .applying(.init(paletteColors: [tint]))) else { return }
        let s = img.size
        img.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
    }
}

final class HUD: NSPanel {
    let dot = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    let time = NSTextField(labelWithString: "00:00")
    let status = NSTextField(labelWithString: "")
    let meter = LevelView(frame: NSRect(x: 0, y: 0, width: 26, height: 20))
    var pauseBtn: IconButton!
    var prompterBtn: IconButton?
    weak var rec: Recorder?

    init(rec: Recorder) {
        self.rec = rec
        super.init(contentRect: NSRect(x: 0, y: 0, width: 314, height: 48), styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = chromeSharing

        let fx = BlurtFloatingSurfaceView(frame: NSRect(x: 0, y: 0, width: 314, height: 48))
        fx.permitsWindowDrag = true
        fx.autoresizingMask = [.width, .height]
        contentView = fx

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.frame.origin = NSPoint(x: 18, y: 19)
        fx.addSubview(dot)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        time.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        time.textColor = .white
        time.frame = NSRect(x: 36, y: 14, width: 62, height: 20)
        fx.addSubview(time)
        status.font = .systemFont(ofSize: 10, weight: .semibold)
        status.textColor = amber
        status.frame = NSRect(x: 36, y: 3, width: 70, height: 12)
        fx.addSubview(status)

        meter.frame.origin = NSPoint(x: 104, y: 14)
        fx.addSubview(meter)

        let div = NSView(frame: NSRect(x: 140, y: 14, width: 1, height: 20))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        fx.addSubview(div)

        pauseBtn = IconButton(symbol: "pause.fill", tip: L("暂停 / 继续（⌥⇧P）", "Pause / resume (⌥⇧P)"), target: self, action: #selector(togglePause))
        let redo = IconButton(symbol: "arrow.counterclockwise", tip: L("重录或放弃…", "Restart or discard…"), target: self, action: #selector(redoRec))
        pauseBtn.frame.origin = NSPoint(x: 150, y: 8)
        redo.frame.origin = NSPoint(x: 186, y: 8)
        fx.addSubview(pauseBtn)
        fx.addSubview(redo)
        var nextX: CGFloat = 224
        if opts.narrationScript != nil {
            let prompt = IconButton(symbol: "text.bubble.fill", tip: L("显示 / 关闭提词器", "Show / hide teleprompter"), target: self, action: #selector(togglePrompter))
            prompt.frame.origin = NSPoint(x: nextX, y: 8)
            fx.addSubview(prompt)
            prompterBtn = prompt
            nextX += 36
            let settings = IconButton(symbol: "slider.horizontal.3", tip: L("录制设置与讲稿", "Recording controls and script"), target: self, action: #selector(editNarration))
            settings.frame.origin = NSPoint(x: nextX, y: 8)
            fx.addSubview(settings)
            nextX += 36
        }
        let done = PillButton(L("完成", "Finish"), symbol: "stop.fill", fill: accent, target: self, action: #selector(stopRec))
        done.toolTip = opts.narrationScript == nil
            ? L("结束录制，开始整理（⌥⇧S）", "Stop and process (⌥⇧S)")
            : L("结束录制并保存 MP4（⌥⇧S）", "Finish and save MP4 (⌥⇧S)")
        done.frame.origin = NSPoint(x: nextX, y: 8)
        fx.addSubview(done)
        let w = done.frame.maxX + 8
        setContentSize(NSSize(width: w, height: 48))
        fx.frame.size.width = w
    }

    func place(near region: CGRect) {
        let r = toNS(region)
        let screen = (NSScreen.screens.first(where: { $0.frame.intersects(r) }) ?? NSScreen.screens[0]).visibleFrame
        var o = NSPoint(x: r.midX - frame.width / 2, y: r.minY - frame.height - 14)
        if o.y < screen.minY + 8 { o.y = r.maxY + 14 }
        if o.y + frame.height > screen.maxY - 8 { o.y = r.minY + 16 }   // inside the region: excluded from capture
        o.x = max(screen.minX + 8, min(o.x, screen.maxX - frame.width - 8))
        setFrameOrigin(o)
    }

    func update(elapsed: Double, paused: Bool, level lv: Float) {
        let s = Int(elapsed)
        time.stringValue = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                                     : String(format: "%02d:%02d", s / 60, s % 60)
        status.stringValue = paused ? L("已暂停", "PAUSED") : ""
        pauseBtn.toolTip = paused ? L("继续录制（⌥⇧P）", "Resume (⌥⇧P)") : L("暂停（⌥⇧P）", "Pause (⌥⇧P)")
        time.frame.origin.y = paused ? 17 : 14
        dot.layer?.backgroundColor = (paused ? amber : NSColor.systemRed).cgColor
        pauseBtn.symbol = paused ? "play.fill" : "pause.fill"
        meter.level = paused ? 0 : lv
        prompterBtn?.symbol = rec?.prompterVisible == true ? "text.bubble.fill" : "text.bubble"
    }

    @objc func togglePause() { rec?.togglePause() }
    @objc func stopRec() { rec?.stop() }
    @objc func togglePrompter() { if let rec = rec { rec.setPrompterEnabled(!rec.prompterVisible) } }
    @objc func editNarration() { rec?.onEditNarration?() }
    @objc func redoRec() {
        guard let rec = rec else { return }
        let wasPaused = rec.isPaused
        if !wasPaused { rec.togglePause() }          // don't keep recording while the dialog is open
        let a = NSAlert()
        a.messageText = L("这段不满意？", "Not happy with this take?")
        a.informativeText = L("重新录制：删掉刚才录的内容，保留同一区域，倒计时后重新开始。\n放弃：删掉并退出。",
                              "Restart: delete what was recorded and start over in the same area.\nDiscard: delete and quit.")
        a.addButton(withTitle: L("重新录制", "Restart"))
        a.addButton(withTitle: L("继续录制", "Keep recording"))
        a.addButton(withTitle: L("放弃", "Discard"))
        activateApp()
        switch a.runModal() {
        case .alertFirstButtonReturn: rec.stop(discard: true, restart: true)
        case .alertThirdButtonReturn: rec.stop(discard: true)
        default: if !wasPaused { rec.togglePause() }
        }
    }
}

func overlayWindow(_ frame: NSRect, view: NSView) -> NSWindow {
    let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .statusBar
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.sharingType = chromeSharing
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    view.frame = NSRect(origin: .zero, size: frame.size)
    w.contentView = view
    return w
}

// MARK: - Narration setup and private teleprompter

// Recording preparation: preview first, optional teleprompter, local script draft.
// This fragment uses L, accent, chromeSharing, activateApp, recordConfig,
// setRecordConfig, PillButton and IconButton from BlurtRecorder.swift.

struct NarrationDisplayOption {
    let id: CGDirectDisplayID
    let title: String
}

// Keep the selected name compact while the menu exposes complete display names.
private final class NarrationDisplaySelector: NSButton {
    private var options: [NarrationDisplayOption] = []
    private(set) var selectedDisplayID: CGDirectDisplayID?
    var onSelect: ((CGDirectDisplayID) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        target = self
        action = #selector(showDisplayMenu)
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }

    func setOptions(_ options: [NarrationDisplayOption], selected: CGDirectDisplayID?) {
        self.options = options
        selectedDisplayID = selected
        if let item = options.first(where: { $0.id == selected }) { title = item.title }
        else if options.isEmpty { title = L("没有可用屏幕", "No displays available") }
        else { title = selected == nil ? L("选择屏幕", "Choose a display") : L("屏幕已断开", "Display disconnected") }
        toolTip = title
        setAccessibilityValue(title)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: isEnabled ? 0.075 : 0.035).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let color = NSColor(white: 1, alpha: isEnabled ? 0.88 : 0.32)
        let symbols: [(String, NSRect)] = [
            ("display", NSRect(x: 11, y: (bounds.height - 16) / 2, width: 16, height: 16)),
            ("chevron.down", NSRect(x: bounds.width - 23, y: (bounds.height - 11) / 2, width: 11, height: 11))]
        for (symbol, rect) in symbols {
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                    .applying(.init(paletteColors: [color])))?.draw(in: rect)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: 36, y: (bounds.height - 17) / 2,
                                          width: max(1, bounds.width - 68), height: 17),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                 .foregroundColor: color, .paragraphStyle: paragraph])
    }

    @objc private func showDisplayMenu() {
        guard isEnabled, !options.isEmpty else { return }
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(selectDisplayItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: option.id)
            item.state = option.id == selectedDisplayID ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY - 4), in: self)
    }

    @objc private func selectDisplayItem(_ sender: NSMenuItem) {
        guard isEnabled, let number = sender.representedObject as? NSNumber,
              options.contains(where: { $0.id == number.uint32Value }) else { return }
        let id = number.uint32Value
        guard id != selectedDisplayID else { return }
        setOptions(options, selected: id)
        onSelect?(id)
    }
}

private final class NarrationSetupWindow: NSWindow {
    weak var setupController: NarrationSetupController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { setupController?.cancel() }
}

private final class NarrationSetupDragView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSTextField ? self : hit
    }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

// Screen image resolution must never drive the window's minimum/fitting size.
private final class NarrationPreviewImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

// The menu-bar app has no Edit menu. Preserve ordinary multiline-editor shortcuts.
private final class NarrationScriptTextView: NSTextView {
    var placeholder = L("在这里输入或粘贴讲解内容…\n\n可以先看画面，再慢慢准备。关闭提词器也会保留草稿。",
                        "Type or paste your script here…\n\nCheck your frame, then prepare your words. Turning the teleprompter off keeps your draft.")
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "v": pasteAsPlainText(nil)
        case "x": cut(nil)
        case "z":
            if flags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        (placeholder as NSString).draw(in: NSRect(x: textContainerInset.width + 5, y: textContainerInset.height,
                                         width: max(40, bounds.width - textContainerInset.width * 2 - 10), height: 180),
                               withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 15),
                                                .foregroundColor: NSColor(white: 1, alpha: 0.34),
                                                .paragraphStyle: paragraph])
    }
}

private final class NarrationToggleButton: NSButton {
    var enabledValue = false { didSet { state = enabledValue ? .on : .off; needsDisplay = true } }
    var symbol = ""
    override var allowsVibrancy: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.055).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let foreground = NSColor(white: 1, alpha: 0.9)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                .applying(.init(paletteColors: [enabledValue ? accent : NSColor(white: 1, alpha: 0.5)]))) {
            image.draw(in: NSRect(x: 13, y: (bounds.height - 18) / 2, width: 18, height: 18))
        }
        let label = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                                   .foregroundColor: foreground])
        label.draw(at: NSPoint(x: 41, y: (bounds.height - label.size().height) / 2))
        let track = NSRect(x: bounds.width - 46, y: (bounds.height - 20) / 2, width: 34, height: 20)
        (enabledValue ? accent : NSColor(white: 1, alpha: 0.2)).setFill()
        NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: enabledValue ? track.maxX - 18 : track.minX + 2,
                                   y: track.minY + 2, width: 16, height: 16)).fill()
    }
}

final class NarrationSetupController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    var onStart: ((CGRect, String, Bool, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onChooseRegion: (() -> Void)?
    var onSelectFullScreen: (() -> Void)?
    var onSelectRecordingDisplay: ((CGDirectDisplayID) -> Void)?
    var onSelectPrompterDisplay: ((CGDirectDisplayID) -> Void)?
    var onPrompterChange: ((String, Bool) -> Void)?
    var onRetryPreview: (() -> Void)?
    var onFinish: (() -> Void)?
    var onHide: (() -> Void)?
    var onUseStandalone: (() -> Void)?
    var onCameraChange: ((Bool, String?, Bool, Bool) -> Void)?
    var onCameraSizeChange: ((CGFloat) -> Void)?

    private(set) var cameraEnabled: Bool
    private(set) var cameraDeviceID: String?
    private(set) var cameraCircular: Bool
    private(set) var cameraMirrored: Bool
    private var cameraReady = false
    private var cameraDevices: [(id: String, name: String)] = []
    private var cameraMessage = L("开启后可预览人像、拖动和缩放", "Enable to preview, move and resize your camera")
    private var cameraSizeFraction: CGFloat = 0.24
    private var cameraSwitch: NarrationToggleButton?
    private var cameraDeviceSelector: NSPopUpButton?
    private var cameraShapeSelector: NSSegmentedControl?
    private var cameraSizeSlider: NSSlider?
    private var cameraSizeLabel: NSTextField?
    private var cameraMirrorButton: NSButton?
    private var cameraStatusLabel: NSTextField?
    private var cameraRetryButton: PillButton?

    var scriptValue: String { editor?.string ?? savedScript }
    private(set) var prompterEnabled: Bool
    private(set) var microphoneEnabled: Bool
    private var savedScript: String
    private var selectedRegion: CGRect = .zero
    private var previewReady = false
    private var recordingMode = false
    private var displayOptions: [NarrationDisplayOption] = []
    private var selectedRecordingDisplay: CGDirectDisplayID?
    private var selectedPrompterDisplay: CGDirectDisplayID?
    private var currentRegionLabel = L("正在选择屏幕…", "Selecting a screen…")
    private var currentPreviewImage: NSImage?
    private var currentPreviewMessage = L("正在准备画面预览…", "Preparing your preview…")
    private var previewHasError = false
    private var finished = false
    private var draftSave: DispatchWorkItem?
    private var window: NarrationSetupWindow?
    private var editor: NarrationScriptTextView?
    private var previewImageView: NSImageView?
    private var previewPlaceholder: NSView?
    private var placeholderMessage: NSTextField?
    private var regionLabel: NSTextField?
    private var previewStatus: NSTextField?
    private var scriptHint: NSTextField?
    private var wordCount: NSTextField?
    private var startButton: PillButton?
    private var retryButton: PillButton?
    private var prompterSwitch: NarrationToggleButton?
    private var microphoneSwitch: NarrationToggleButton?
    private var headingLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var cancelButton: PillButton?
    private var chooseRegionButton: PillButton?
    private var fullScreenButton: PillButton?
    private var standaloneButton: PillButton?
    private var recordingDisplaySelector: NarrationDisplaySelector?
    private var prompterDisplaySelector: NarrationDisplaySelector?

    override init() {
        let config = recordConfig()
        savedScript = config["narration_script"] as? String ?? ""
        prompterEnabled = config["narration_prompter_enabled"] as? Bool ?? true
        microphoneEnabled = config["narration_microphone_enabled"] as? Bool ?? true
        cameraEnabled = config["narration_camera_enabled"] as? Bool ?? false
        cameraDeviceID = config["narration_camera_device"] as? String
        cameraCircular = config["narration_camera_circular"] as? Bool ?? true
        cameraMirrored = config["narration_camera_mirrored"] as? Bool ?? true
        let savedSize = (config["narration_camera_size"] as? NSNumber)?.doubleValue ?? 0.24
        cameraSizeFraction = CGFloat(savedSize.isFinite ? min(0.6, max(0.12, savedSize)) : 0.24)
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        finished = false
        refreshStart()
        activateApp()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    func hideForRegionSelection() {
        flushDraft(notify: true)
        window?.orderOut(nil)
    }

    func setRegion(_ region: CGRect, label: String) {
        selectedRegion = region
        currentRegionLabel = label
        regionLabel?.stringValue = label
        setPreview(nil)
    }

    func setDisplayOptions(_ options: [NarrationDisplayOption], recording: CGDirectDisplayID?, prompter: CGDirectDisplayID?) {
        displayOptions = options
        selectedRecordingDisplay = recording
        selectedPrompterDisplay = prompter
        recordingDisplaySelector?.setOptions(options, selected: recording)
        prompterDisplaySelector?.setOptions(options, selected: prompter)
        recordingDisplaySelector?.isEnabled = !recordingMode && !options.isEmpty
        // A destination can be chosen with the prompter off; it never enables it.
        prompterDisplaySelector?.isEnabled = !options.isEmpty
        recordingDisplaySelector?.needsDisplay = true
        prompterDisplaySelector?.needsDisplay = true
    }

    func setPreview(_ image: NSImage?) {
        currentPreviewImage = image
        previewImageView?.image = image
        previewReady = image != nil
        previewPlaceholder?.isHidden = image != nil
        if image != nil {
            previewStatus?.stringValue = L("画面已就绪 · 仅录制所选区域", "Ready · only the selected area will be recorded")
            previewStatus?.textColor = NSColor(white: 1, alpha: 0.56)
            retryButton?.isHidden = true
        }
        refreshStart()
    }

    // A status update marks the preview as loading/failed until the next image arrives.
    func setPreviewStatus(_ message: String, error: Bool) {
        currentPreviewImage = nil
        currentPreviewMessage = message
        previewHasError = error
        previewReady = false
        previewImageView?.image = nil
        previewPlaceholder?.isHidden = false
        placeholderMessage?.stringValue = message
        previewStatus?.stringValue = error ? L("画面暂不可用，请重试", "Preview unavailable. Try again.") : L("正在连接录制画面…", "Connecting to your screen…")
        previewStatus?.textColor = error ? accent : NSColor(white: 1, alpha: 0.56)
        retryButton?.isHidden = !error
        refreshStart()
    }

    func setRecordingMode(_ recording: Bool) {
        if recordingMode && !recording { finished = false }
        recordingMode = recording
        headingLabel?.stringValue = recording ? L("录制中", "Recording") : L("录制准备", "Ready to record")
        subtitleLabel?.stringValue = recording
            ? L("随时调整讲稿、提词器和摄像头。", "Adjust your script, prompter, or camera while recording.")
            : L("先确认画面，再开始讲解。", "Frame your screen, then tell your story.")
        window?.title = recording ? L("录制中 · Blurt", "Recording · Blurt") : L("录制准备 · Blurt", "Recording setup · Blurt")
        for button in [chooseRegionButton, fullScreenButton] {
            button?.isEnabled = !recording
            button?.alphaValue = recording ? 0.35 : 1
        }
        microphoneSwitch?.isEnabled = !recording
        microphoneSwitch?.alphaValue = recording ? 0.35 : 1
        standaloneButton?.isHidden = recording
        standaloneButton?.isEnabled = !recording
        recordingDisplaySelector?.isEnabled = !recording && !displayOptions.isEmpty
        recordingDisplaySelector?.needsDisplay = true
        cancelButton?.title = recording ? L("返回录制", "Back") : L("取消", "Cancel")
        if let button = cancelButton {
            let width = NSAttributedString(string: button.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).size().width + 28
            button.constraints.first(where: { $0.firstAttribute == .width && $0.secondItem == nil })?.constant = width
        }
        cancelButton?.needsDisplay = true
        refreshStart()
    }

    func setPrompterEnabled(_ enabled: Bool) {
        prompterEnabled = enabled
        prompterSwitch?.enabledValue = enabled
        updateScriptHint()
        setRecordConfig("narration_prompter_enabled", enabled)
        onPrompterChange?(scriptValue, enabled)
    }

    func setCameraDevices(_ devices: [(id: String, name: String)], selected: String?) {
        cameraDevices = devices
        cameraDeviceID = selected ?? devices.first?.id
        cameraDeviceSelector?.removeAllItems()
        let unavailable = cameraDeviceID != nil && !devices.contains(where: { $0.id == cameraDeviceID })
        if unavailable {
            cameraDeviceSelector?.addItem(withTitle: L("所选摄像头不可用", "Selected camera unavailable"))
            cameraDeviceSelector?.lastItem?.representedObject = cameraDeviceID
        } else if devices.isEmpty { cameraDeviceSelector?.addItem(withTitle: L("没有可用摄像头", "No camera available")) }
        for device in devices {
            cameraDeviceSelector?.addItem(withTitle: device.name)
            cameraDeviceSelector?.lastItem?.representedObject = device.id
        }
        if let index = devices.firstIndex(where: { $0.id == cameraDeviceID }) { cameraDeviceSelector?.selectItem(at: index + (unavailable ? 1 : 0)) }
        else { cameraDeviceSelector?.selectItem(at: 0) }
        cameraDeviceSelector?.isEnabled = !devices.isEmpty
    }

    func setCameraStatus(_ message: String, ready: Bool) {
        cameraMessage = message
        cameraReady = ready
        cameraStatusLabel?.stringValue = message
        cameraStatusLabel?.textColor = cameraEnabled && !ready ? accent : NSColor(white: 1, alpha: 0.5)
        cameraStatusLabel?.toolTip = message
        cameraRetryButton?.isHidden = !cameraEnabled || ready
        refreshStart()
    }

    func setCameraEnabled(_ enabled: Bool, notify: Bool = true) {
        if cameraEnabled != enabled { cameraReady = false }
        cameraEnabled = enabled
        cameraSwitch?.enabledValue = enabled
        setRecordConfig("narration_camera_enabled", enabled)
        if !enabled { setCameraStatus(L("摄像头已关闭", "Camera off"), ready: false) }
        else if !cameraReady { setCameraStatus(L("正在连接摄像头…", "Connecting to camera…"), ready: false) }
        refreshStart()
        if notify { notifyCameraChange() }
    }

    func setCameraSize(_ fraction: CGFloat) {
        guard fraction.isFinite else { return }
        cameraSizeFraction = min(0.6, max(0.12, fraction))
        cameraSizeSlider?.doubleValue = Double(cameraSizeFraction)
        cameraSizeLabel?.stringValue = "\(Int((cameraSizeFraction * 100).rounded()))%"
    }

    private func notifyCameraChange() {
        onCameraChange?(cameraEnabled, cameraDeviceID, cameraCircular, cameraMirrored)
    }

    private func buildWindow() {
        let w = NarrationSetupWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 740),
                                     styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        w.title = L("录制准备 · Blurt", "Recording setup · Blurt")
        w.minSize = NSSize(width: 940, height: 680)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.collectionBehavior = [.moveToActiveSpace]
        w.sharingType = chromeSharing
        w.setupController = self
        w.delegate = self
        window = w

        let content = NSView(frame: NSRect(origin: .zero, size: w.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.105, green: 0.112, blue: 0.125, alpha: 1).cgColor
        content.layer?.cornerRadius = 22
        content.layer?.masksToBounds = true
        w.contentView = content

        func add(_ view: NSView, to parent: NSView = content) {
            view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(view)
        }
        func label(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   alpha: CGFloat = 0.9, parent: NSView = content) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = NSColor(white: 1, alpha: alpha)
            field.isSelectable = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            add(field, to: parent)
            return field
        }
        func pane() -> NSView {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(white: 1, alpha: 0.045).cgColor
            view.layer?.cornerRadius = 16
            view.layer?.masksToBounds = true
            add(view)
            return view
        }
        func button(_ value: String, symbol: String? = nil, selector: Selector,
                    parent: NSView = content, primary: Bool = false) -> PillButton {
            let result = PillButton(value, symbol: symbol, fill: primary ? accent : NSColor(white: 1, alpha: 0.09),
                                    target: self, action: selector)
            let width = result.frame.width
            add(result, to: parent)
            result.widthAnchor.constraint(equalToConstant: width).isActive = true
            result.heightAnchor.constraint(equalToConstant: 34).isActive = true
            return result
        }

        let header = NarrationSetupDragView()
        add(header)
        let heading = label(L("录制准备", "Ready to record"), size: 24, weight: .bold, parent: header)
        let subtitle = label(L("先确认画面，再开始讲解。", "Frame your screen, then tell your story."), size: 13, alpha: 0.52, parent: header)
        headingLabel = heading
        subtitleLabel = subtitle
        let brand = label("BLURT", size: 11, weight: .bold, alpha: 0.45, parent: header)
        let close = IconButton(symbol: "xmark", tip: L("关闭录制准备", "Close recording setup"), target: self, action: #selector(cancel))
        add(close)

        let left = pane()
        let right = pane()
        let previewTitle = label(L("录制画面", "Recording preview"), size: 15, weight: .semibold, parent: left)
        let recordingDisplayLabel = label(L("录制屏幕", "Recording display"), size: 12, weight: .medium, alpha: 0.65, parent: left)
        let recordingDisplay = NarrationDisplaySelector(frame: .zero)
        recordingDisplay.setAccessibilityLabel(L("录制屏幕", "Recording display"))
        recordingDisplay.onSelect = { [weak self] id in
            guard let self = self, !self.recordingMode else { return }
            self.selectedRecordingDisplay = id
            self.setPreview(nil)
            self.onSelectRecordingDisplay?(id)
        }
        add(recordingDisplay, to: left)
        recordingDisplaySelector = recordingDisplay
        let region = label(L("正在选择屏幕…", "Selecting a screen…"), size: 12, alpha: 0.5, parent: left)
        region.maximumNumberOfLines = 1
        region.lineBreakMode = .byTruncatingMiddle
        regionLabel = region
        let full = button(L("全屏", "Full screen"), symbol: "arrow.up.left.and.arrow.down.right", selector: #selector(selectFullScreen), parent: left)
        let choose = button(L("选择区域", "Choose area"), symbol: "viewfinder", selector: #selector(chooseRegion), parent: left)
        fullScreenButton = full
        chooseRegionButton = choose

        let canvas = NSView()
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedRed: 0.065, green: 0.07, blue: 0.08, alpha: 1).cgColor
        canvas.layer?.cornerRadius = 10
        canvas.layer?.masksToBounds = true
        add(canvas, to: left)
        let image = NarrationPreviewImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.imageAlignment = .alignCenter
        add(image, to: canvas)
        previewImageView = image
        let placeholder = NSView()
        add(placeholder, to: canvas)
        previewPlaceholder = placeholder
        let monitor = NSImageView(image: NSImage(systemSymbolName: "display", accessibilityDescription: nil) ?? NSImage())
        monitor.contentTintColor = NSColor(white: 1, alpha: 0.2)
        monitor.imageScaling = .scaleProportionallyUpOrDown
        add(monitor, to: placeholder)
        let message = label(L("正在准备画面预览…", "Preparing your preview…"), size: 13, alpha: 0.5, parent: placeholder)
        message.alignment = .center
        placeholderMessage = message
        let status = label(L("正在连接录制画面…", "Connecting to your screen…"), size: 11, alpha: 0.5, parent: left)
        previewStatus = status
        let retry = button(L("重试", "Retry"), selector: #selector(retryPreview), parent: left)
        retry.isHidden = true
        retryButton = retry

        let camera = NarrationToggleButton(frame: .zero)
        camera.title = L("摄像头", "Camera")
        camera.symbol = "video.fill"
        camera.isBordered = false
        camera.target = self
        camera.action = #selector(toggleCamera)
        camera.enabledValue = cameraEnabled
        camera.setAccessibilityLabel(L("录制摄像头人像", "Record camera overlay"))
        add(camera, to: left)
        cameraSwitch = camera
        let device = NSPopUpButton(frame: .zero, pullsDown: false)
        device.font = .systemFont(ofSize: 12, weight: .medium)
        device.bezelStyle = .rounded
        device.target = self
        device.action = #selector(changeCameraDevice)
        device.setAccessibilityLabel(L("摄像头设备", "Camera device"))
        add(device, to: left)
        cameraDeviceSelector = device
        let shape = NSSegmentedControl(labels: [L("圆形", "Circle"), L("方形", "Square")], trackingMode: .selectOne,
                                       target: self, action: #selector(changeCameraShape))
        shape.segmentStyle = .rounded
        shape.selectedSegment = cameraCircular ? 0 : 1
        shape.setAccessibilityLabel(L("摄像头形状", "Camera shape"))
        add(shape, to: left)
        cameraShapeSelector = shape
        let sizeTitle = label(L("大小", "Size"), size: 11, alpha: 0.6, parent: left)
        let size = NSSlider(value: Double(cameraSizeFraction), minValue: 0.12, maxValue: 0.6, target: self, action: #selector(changeCameraSize))
        size.isContinuous = true
        size.controlSize = .small
        size.setAccessibilityLabel(L("摄像头大小，占录制区域短边的比例", "Camera size as a percentage of the recording area's shorter side"))
        add(size, to: left)
        cameraSizeSlider = size
        let percent = label("", size: 11, weight: .medium, parent: left)
        percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        percent.alignment = .right
        cameraSizeLabel = percent
        let mirror = NSButton(checkboxWithTitle: L("镜像", "Mirror"), target: self, action: #selector(changeCameraMirror))
        mirror.font = .systemFont(ofSize: 11)
        mirror.state = cameraMirrored ? .on : .off
        mirror.setAccessibilityLabel(L("镜像摄像头画面和成片", "Mirror camera preview and recording"))
        add(mirror, to: left)
        cameraMirrorButton = mirror
        let cameraStatus = label(cameraMessage, size: 11, alpha: 0.5, parent: left)
        cameraStatus.maximumNumberOfLines = 1
        cameraStatus.lineBreakMode = .byTruncatingTail
        cameraStatusLabel = cameraStatus
        let cameraRetry = button(L("重试", "Retry"), selector: #selector(retryCamera), parent: left)
        cameraRetry.setAccessibilityLabel(L("重试连接摄像头", "Retry camera connection"))
        cameraRetry.isHidden = true
        cameraRetryButton = cameraRetry

        let scriptTitle = label(L("提词器", "Teleprompter"), size: 15, weight: .semibold, parent: right)
        let privateBadge = label(L("不录入视频", "Hidden in video"), size: 11, weight: .medium, alpha: 0.45, parent: right)
        let toggle = NarrationToggleButton(frame: .zero)
        toggle.title = L("显示提词器", "Show teleprompter")
        toggle.symbol = "text.bubble"
        toggle.isBordered = false
        toggle.target = self
        toggle.action = #selector(togglePrompter)
        toggle.enabledValue = prompterEnabled
        toggle.setAccessibilityLabel(L("显示或关闭提词器", "Show or hide the teleprompter"))
        add(toggle, to: right)
        prompterSwitch = toggle
        let prompterDisplayLabel = label(L("提词器屏幕", "Prompter display"), size: 12, weight: .medium, alpha: 0.65, parent: right)
        let prompterDisplay = NarrationDisplaySelector(frame: .zero)
        prompterDisplay.setAccessibilityLabel(L("提词器屏幕", "Prompter display"))
        prompterDisplay.onSelect = { [weak self] id in
            guard let self = self else { return }
            self.selectedPrompterDisplay = id
            self.onSelectPrompterDisplay?(id)
        }
        add(prompterDisplay, to: right)
        prompterDisplaySelector = prompterDisplay
        let scriptLabel = label(L("提词内容", "Your script"), size: 12, weight: .medium, alpha: 0.65, parent: right)
        let count = label("", size: 11, alpha: 0.35, parent: right)
        count.alignment = .right
        wordCount = count

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedRed: 0.105, green: 0.112, blue: 0.125, alpha: 1)
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = scroll.backgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.masksToBounds = true
        let text = NarrationScriptTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.font = .systemFont(ofSize: 16)
        text.textColor = NSColor(white: 1, alpha: 0.9)
        text.insertionPointColor = accent
        text.drawsBackground = true
        text.backgroundColor = scroll.backgroundColor
        text.textContainerInset = NSSize(width: 12, height: 14)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = .width
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 316, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        text.defaultParagraphStyle = paragraph
        text.string = savedScript
        text.delegate = self
        text.setAccessibilityLabel(L("提词内容，草稿自动保存在本机", "Teleprompter script, draft saved on this Mac"))
        editor = text
        scroll.documentView = text
        add(scroll, to: right)
        let hint = label("", size: 11, alpha: 0.45, parent: right)
        hint.maximumNumberOfLines = 2
        scriptHint = hint

        let microphone = NarrationToggleButton(frame: .zero)
        microphone.title = L("麦克风", "Microphone")
        microphone.symbol = "mic.fill"
        microphone.isBordered = false
        microphone.target = self
        microphone.action = #selector(toggleMicrophone)
        microphone.enabledValue = microphoneEnabled
        microphone.setAccessibilityLabel(L("录制麦克风声音", "Record microphone audio"))
        add(microphone)
        microphoneSwitch = microphone
        let saveHint = label(L("完成后保存为 MP4", "Save as MP4 when finished"), size: 12, alpha: 0.45)
        let standalone = button(L("仅用提词器", "Teleprompter only"), symbol: "text.bubble", selector: #selector(useStandalone))
        standalone.setAccessibilityLabel(L("切换为独立提词器", "Use the teleprompter on its own"))
        standaloneButton = standalone
        let cancelButton = button(L("取消", "Cancel"), selector: #selector(cancel))
        self.cancelButton = cancelButton
        cancelButton.keyEquivalent = "\u{1b}"
        let start = button(L("开始录制", "Start recording"), symbol: "record.circle.fill", selector: #selector(start), primary: true)
        start.setAccessibilityLabel(L("确认画面并开始录制", "Confirm the preview and start recording"))
        startButton = start

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            header.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            header.heightAnchor.constraint(equalToConstant: 55),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor), heading.topAnchor.constraint(equalTo: header.topAnchor),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor), subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 5),
            brand.trailingAnchor.constraint(equalTo: header.trailingAnchor), brand.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 32), close.heightAnchor.constraint(equalToConstant: 32),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22), close.topAnchor.constraint(equalTo: content.topAnchor, constant: 23),
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            left.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 17),
            left.bottomAnchor.constraint(equalTo: microphone.topAnchor, constant: -20),
            left.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.59, constant: -24),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            right.topAnchor.constraint(equalTo: left.topAnchor), right.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            previewTitle.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 16), previewTitle.topAnchor.constraint(equalTo: left.topAnchor, constant: 16),
            recordingDisplayLabel.leadingAnchor.constraint(equalTo: previewTitle.leadingAnchor),
            recordingDisplayLabel.widthAnchor.constraint(equalToConstant: L("zh", "en") == "zh" ? 84 : 106),
            recordingDisplayLabel.centerYAnchor.constraint(equalTo: recordingDisplay.centerYAnchor),
            recordingDisplay.leadingAnchor.constraint(equalTo: recordingDisplayLabel.trailingAnchor, constant: 8),
            recordingDisplay.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -16),
            recordingDisplay.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 12),
            recordingDisplay.heightAnchor.constraint(equalToConstant: 34),
            region.leadingAnchor.constraint(equalTo: previewTitle.leadingAnchor), region.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -16),
            region.topAnchor.constraint(equalTo: recordingDisplay.bottomAnchor, constant: 8),
            full.leadingAnchor.constraint(equalTo: previewTitle.leadingAnchor), full.topAnchor.constraint(equalTo: region.bottomAnchor, constant: 12),
            choose.leadingAnchor.constraint(equalTo: full.trailingAnchor, constant: 8), choose.centerYAnchor.constraint(equalTo: full.centerYAnchor),
            canvas.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 14), canvas.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -14),
            canvas.topAnchor.constraint(equalTo: full.bottomAnchor, constant: 14), canvas.bottomAnchor.constraint(equalTo: camera.topAnchor, constant: -36),
            image.leadingAnchor.constraint(equalTo: canvas.leadingAnchor), image.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            image.topAnchor.constraint(equalTo: canvas.topAnchor), image.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: canvas.centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 24), placeholder.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -24),
            placeholder.heightAnchor.constraint(equalToConstant: 118),
            monitor.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor), monitor.topAnchor.constraint(equalTo: placeholder.topAnchor),
            monitor.widthAnchor.constraint(equalToConstant: 56), monitor.heightAnchor.constraint(equalToConstant: 48),
            message.topAnchor.constraint(equalTo: monitor.bottomAnchor, constant: 16), message.leadingAnchor.constraint(equalTo: placeholder.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: placeholder.trailingAnchor),
            status.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 17), status.centerYAnchor.constraint(equalTo: retry.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: retry.leadingAnchor, constant: -8),
            retry.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12), retry.bottomAnchor.constraint(equalTo: camera.topAnchor, constant: -1),
            camera.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 14),
            camera.widthAnchor.constraint(equalToConstant: 152), camera.heightAnchor.constraint(equalToConstant: 38),
            camera.bottomAnchor.constraint(equalTo: shape.topAnchor, constant: -12),
            device.leadingAnchor.constraint(equalTo: camera.trailingAnchor, constant: 10), device.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -16),
            device.centerYAnchor.constraint(equalTo: camera.centerYAnchor), device.heightAnchor.constraint(equalToConstant: 30),
            shape.leadingAnchor.constraint(equalTo: camera.leadingAnchor), shape.widthAnchor.constraint(equalToConstant: 142),
            shape.heightAnchor.constraint(equalToConstant: 28), shape.bottomAnchor.constraint(equalTo: mirror.topAnchor, constant: -10),
            sizeTitle.leadingAnchor.constraint(equalTo: shape.trailingAnchor, constant: 12), sizeTitle.widthAnchor.constraint(equalToConstant: 27),
            sizeTitle.centerYAnchor.constraint(equalTo: shape.centerYAnchor),
            size.leadingAnchor.constraint(equalTo: sizeTitle.trailingAnchor, constant: 8), size.centerYAnchor.constraint(equalTo: shape.centerYAnchor),
            size.trailingAnchor.constraint(equalTo: percent.leadingAnchor, constant: -7),
            percent.widthAnchor.constraint(equalToConstant: 33), percent.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -16),
            percent.centerYAnchor.constraint(equalTo: shape.centerYAnchor),
            mirror.leadingAnchor.constraint(equalTo: camera.leadingAnchor), mirror.widthAnchor.constraint(equalToConstant: 73),
            mirror.heightAnchor.constraint(equalToConstant: 22), mirror.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -12),
            cameraStatus.leadingAnchor.constraint(equalTo: mirror.trailingAnchor, constant: 10),
            cameraStatus.trailingAnchor.constraint(equalTo: cameraRetry.leadingAnchor, constant: -8), cameraStatus.centerYAnchor.constraint(equalTo: mirror.centerYAnchor),
            cameraRetry.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12), cameraRetry.centerYAnchor.constraint(equalTo: mirror.centerYAnchor),
            scriptTitle.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 16), scriptTitle.topAnchor.constraint(equalTo: right.topAnchor, constant: 16),
            privateBadge.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -16), privateBadge.centerYAnchor.constraint(equalTo: scriptTitle.centerYAnchor),
            toggle.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 14), toggle.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -14),
            toggle.topAnchor.constraint(equalTo: scriptTitle.bottomAnchor, constant: 15), toggle.heightAnchor.constraint(equalToConstant: 42),
            prompterDisplayLabel.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 17),
            prompterDisplayLabel.widthAnchor.constraint(equalToConstant: L("zh", "en") == "zh" ? 84 : 106),
            prompterDisplayLabel.centerYAnchor.constraint(equalTo: prompterDisplay.centerYAnchor),
            prompterDisplay.leadingAnchor.constraint(equalTo: prompterDisplayLabel.trailingAnchor, constant: 8),
            prompterDisplay.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -14),
            prompterDisplay.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 12),
            prompterDisplay.heightAnchor.constraint(equalToConstant: 34),
            scriptLabel.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 17), scriptLabel.topAnchor.constraint(equalTo: prompterDisplay.bottomAnchor, constant: 16),
            count.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -17), count.centerYAnchor.constraint(equalTo: scriptLabel.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 14), scroll.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: scriptLabel.bottomAnchor, constant: 9), scroll.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -56),
            hint.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 17), hint.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -17),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            microphone.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 23), microphone.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            microphone.widthAnchor.constraint(equalToConstant: 187), microphone.heightAnchor.constraint(equalToConstant: 40),
            saveHint.leadingAnchor.constraint(equalTo: microphone.trailingAnchor, constant: 17), saveHint.centerYAnchor.constraint(equalTo: microphone.centerYAnchor),
            standalone.leadingAnchor.constraint(equalTo: saveHint.trailingAnchor, constant: 14), standalone.centerYAnchor.constraint(equalTo: microphone.centerYAnchor),
            standalone.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -14),
            start.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), start.centerYAnchor.constraint(equalTo: microphone.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: start.leadingAnchor, constant: -10), cancelButton.centerYAnchor.constraint(equalTo: start.centerYAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, text.frame.height)))
        refreshStart()
        refreshCount()
        updateScriptHint()
        setDisplayOptions(displayOptions, recording: selectedRecordingDisplay, prompter: selectedPrompterDisplay)
        setCameraDevices(cameraDevices, selected: cameraDeviceID)
        setCameraSize(cameraSizeFraction)
        setCameraStatus(cameraMessage, ready: cameraReady)
        region.stringValue = currentRegionLabel
        if let cached = currentPreviewImage { setPreview(cached) }
        else { setPreviewStatus(currentPreviewMessage, error: previewHasError) }
        setRecordingMode(recordingMode)
        w.center()
    }

    func textDidChange(_ notification: Notification) {
        editor?.needsDisplay = true
        refreshCount()
        draftSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushDraft(notify: true) }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func refreshCount() {
        let count = scriptValue.count
        wordCount?.stringValue = L("\(count) 字", "\(count) characters")
    }

    private func updateScriptHint() {
        scriptHint?.stringValue = prompterEnabled
            ? L("草稿自动保存 · 提词窗可拖动、缩放", "Draft saved automatically · move and resize the prompter")
            : L("提词器已关闭 · 草稿保留，可随时开启", "Teleprompter off · your draft is kept for later")
    }

    private func refreshStart() {
        let valid = !selectedRegion.isNull && !selectedRegion.isInfinite && selectedRegion.width >= 2 && selectedRegion.height >= 2
        let enabled = !finished && (recordingMode || (previewReady && valid && (!cameraEnabled || cameraReady)))
        startButton?.title = recordingMode ? L("完成录制", "Finish recording") : L("开始录制", "Start recording")
        startButton?.image = NSImage(systemSymbolName: recordingMode ? "stop.fill" : "record.circle.fill", accessibilityDescription: nil)
        if let button = startButton {
            let width = NSAttributedString(string: button.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).size().width + 46
            button.constraints.first(where: { $0.firstAttribute == .width && $0.secondItem == nil })?.constant = width
        }
        startButton?.isEnabled = enabled
        startButton?.fill = enabled ? accent : NSColor(white: 1, alpha: 0.1)
        startButton?.fg = NSColor(white: 1, alpha: enabled ? 1 : 0.3)
        startButton?.needsDisplay = true
    }

    private func flushDraft(notify: Bool) {
        draftSave?.cancel()
        draftSave = nil
        savedScript = scriptValue
        setRecordConfig("narration_script", savedScript)
        if notify { onPrompterChange?(savedScript, prompterEnabled) }
    }

    @objc private func chooseRegion() { if !recordingMode { onChooseRegion?() } }
    @objc private func selectFullScreen() { if !recordingMode { onSelectFullScreen?() } }
    @objc private func retryPreview() { onRetryPreview?() }
    @objc private func togglePrompter() { setPrompterEnabled(!prompterEnabled) }
    @objc private func useStandalone() {
        guard !recordingMode, !finished else { return }
        flushDraft(notify: false)
        onUseStandalone?()
    }
    @objc private func toggleMicrophone() {
        guard !recordingMode else { return }
        microphoneEnabled.toggle()
        microphoneSwitch?.enabledValue = microphoneEnabled
        setRecordConfig("narration_microphone_enabled", microphoneEnabled)
    }
    @objc private func toggleCamera() { setCameraEnabled(!cameraEnabled) }
    @objc private func retryCamera() { if cameraEnabled { notifyCameraChange() } }
    @objc private func changeCameraDevice() {
        guard let id = cameraDeviceSelector?.selectedItem?.representedObject as? String,
              cameraDevices.contains(where: { $0.id == id }), id != cameraDeviceID else { return }
        cameraDeviceID = id
        setRecordConfig("narration_camera_device", id)
        if cameraEnabled { setCameraStatus(L("正在切换摄像头…", "Switching camera…"), ready: false) }
        notifyCameraChange()
    }
    @objc private func changeCameraShape() {
        cameraCircular = cameraShapeSelector?.selectedSegment != 1
        setRecordConfig("narration_camera_circular", cameraCircular)
        notifyCameraChange()
    }
    @objc private func changeCameraMirror() {
        cameraMirrored = cameraMirrorButton?.state == .on
        setRecordConfig("narration_camera_mirrored", cameraMirrored)
        notifyCameraChange()
    }
    @objc private func changeCameraSize() {
        setCameraSize(CGFloat(cameraSizeSlider?.doubleValue ?? 0.24))
        setRecordConfig("narration_camera_size", Double(cameraSizeFraction))
        onCameraSizeChange?(cameraSizeFraction)
    }
    @objc private func start() {
        if recordingMode {
            guard !finished else { return }
            finished = true
            flushDraft(notify: true)
            window?.orderOut(nil)
            onFinish?()
            return
        }
        guard !finished, previewReady, (!cameraEnabled || cameraReady), selectedRegion.width >= 2, selectedRegion.height >= 2,
              !selectedRegion.isNull, !selectedRegion.isInfinite else { return }
        finished = true
        flushDraft(notify: false)
        // Keep an owned window present while Recorder.prepare resolves the exclusion filter.
        // App.begin hides this window only after capture setup has succeeded.
        onStart?(selectedRegion, scriptValue, prompterEnabled, microphoneEnabled)
    }
    @objc func cancel() {
        if recordingMode {
            flushDraft(notify: true)
            window?.orderOut(nil)
            onHide?()
            return
        }
        guard !finished else { return }
        finished = true
        flushDraft(notify: false)
        window?.orderOut(nil)
        onCancel?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    deinit { draftSave?.cancel() }
}


private final class StandalonePrompterWindow: NSWindow {
    weak var prompterController: StandalonePrompterController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { prompterController?.hide() }
}

private final class StandalonePrompterSurfaceView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.105, green: 0.112, blue: 0.125, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 22, yRadius: 22).fill()
    }
}

/// Script settings for an independent prompter. This controller never starts capture.
final class StandalonePrompterController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    var onChange: ((String, Bool) -> Void)?
    var onSelectDisplay: ((CGDirectDisplayID) -> Void)?
    var onHide: (() -> Void)?

    var scriptValue: String { editor?.string ?? savedScript }
    private(set) var prompterEnabled: Bool
    private var savedScript: String
    private var displayOptions: [NarrationDisplayOption] = []
    private var selectedDisplay: CGDirectDisplayID?
    private var window: StandalonePrompterWindow?
    private var editor: NarrationScriptTextView?
    private var displaySelector: NarrationDisplaySelector?
    private var prompterSwitch: NarrationToggleButton?
    private var wordCount: NSTextField?
    private var stateHint: NSTextField?
    private var draftSave: DispatchWorkItem?

    override init() {
        let config = recordConfig()
        savedScript = config["narration_script"] as? String ?? ""
        prompterEnabled = config["standalone_prompter_enabled"] as? Bool ?? true
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        activateApp()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        if let editor = editor { window?.makeFirstResponder(editor) }
    }

    /// Keep the independent prompter running while dismissing its settings.
    @objc func hide() {
        let wasVisible = window?.isVisible == true
        flushDraft(notify: true)
        window?.orderOut(nil)
        if wasVisible { onHide?() }
    }

    /// Flush and release settings during a mode switch or application teardown.
    func close() {
        flushDraft(notify: true)
        window?.orderOut(nil)
        window?.delegate = nil
        window?.prompterController = nil
        window = nil
        editor = nil
        displaySelector = nil
        prompterSwitch = nil
        wordCount = nil
        stateHint = nil
    }

    func setDisplayOptions(_ options: [NarrationDisplayOption], selected: CGDirectDisplayID?) {
        displayOptions = options
        selectedDisplay = selected
        displaySelector?.setOptions(options, selected: selected)
        displaySelector?.isEnabled = !options.isEmpty
        displaySelector?.needsDisplay = true
    }

    func setPrompterEnabled(_ enabled: Bool) {
        prompterEnabled = enabled
        prompterSwitch?.enabledValue = enabled
        setRecordConfig("standalone_prompter_enabled", enabled)
        refreshText()
        flushDraft(notify: true)
    }

    private func buildWindow() {
        let w = StandalonePrompterWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
                                         styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        w.title = L("提词器设置 · Blurt", "Teleprompter settings · Blurt")
        w.minSize = NSSize(width: 580, height: 520)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.collectionBehavior = [.moveToActiveSpace]
        w.sharingType = chromeSharing
        w.prompterController = self
        w.delegate = self
        window = w

        let content = StandalonePrompterSurfaceView(frame: NSRect(origin: .zero, size: w.frame.size))
        w.contentView = content
        func add(_ view: NSView, to parent: NSView = content) {
            view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(view)
        }
        func label(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   alpha: CGFloat = 0.9, parent: NSView = content) -> NSTextField {
            let result = NSTextField(wrappingLabelWithString: value)
            result.font = .systemFont(ofSize: size, weight: weight)
            result.textColor = NSColor(white: 1, alpha: alpha)
            result.isSelectable = false
            result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            add(result, to: parent)
            return result
        }

        let header = NarrationSetupDragView()
        add(header)
        let heading = label(L("提词器", "Teleprompter"), size: 24, weight: .bold, parent: header)
        let subtitle = label(L("准备好讲稿，按自己的节奏表达。", "Prepare your script and speak at your own pace."),
                             size: 13, alpha: 0.52, parent: header)
        let closeButton = IconButton(symbol: "xmark", tip: L("收起提词器设置", "Hide teleprompter settings"),
                                     target: self, action: #selector(hide))
        add(closeButton)
        let toggle = NarrationToggleButton(frame: .zero)
        toggle.title = L("显示提词器", "Show teleprompter")
        toggle.symbol = "text.bubble"
        toggle.isBordered = false
        toggle.target = self
        toggle.action = #selector(togglePrompter)
        toggle.enabledValue = prompterEnabled
        toggle.setAccessibilityLabel(L("显示或关闭独立提词器", "Show or hide the standalone teleprompter"))
        add(toggle)
        prompterSwitch = toggle

        let displayLabel = label(L("提词器屏幕", "Prompter display"), size: 12, weight: .medium, alpha: 0.65)
        let displays = NarrationDisplaySelector(frame: .zero)
        displays.setAccessibilityLabel(L("提词器屏幕", "Prompter display"))
        displays.onSelect = { [weak self] id in
            self?.selectedDisplay = id
            self?.onSelectDisplay?(id)
        }
        add(displays)
        displaySelector = displays
        let scriptLabel = label(L("提词内容", "Your script"), size: 12, weight: .medium, alpha: 0.65)
        let count = label("", size: 11, alpha: 0.4)
        count.alignment = .right
        wordCount = count

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedRed: 0.073, green: 0.078, blue: 0.088, alpha: 1)
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = scroll.backgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true
        let text = NarrationScriptTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 300))
        text.placeholder = L("在这里输入或粘贴提词内容…\n\n讲稿会自动保存，也可以在提词时随时修改。",
                             "Type or paste your script here…\n\nYour draft is saved automatically. You can edit it while using the teleprompter.")
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.font = .systemFont(ofSize: 17)
        text.textColor = NSColor(white: 1, alpha: 0.9)
        text.insertionPointColor = accent
        text.drawsBackground = true
        text.backgroundColor = scroll.backgroundColor
        text.textContainerInset = NSSize(width: 14, height: 16)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = .width
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 592, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        text.defaultParagraphStyle = paragraph
        text.string = savedScript
        text.delegate = self
        text.setAccessibilityLabel(L("提词内容，草稿自动保存在本机", "Teleprompter script, draft saved on this Mac"))
        editor = text
        scroll.documentView = text
        add(scroll)

        let hint = label("", size: 11, alpha: 0.48)
        hint.maximumNumberOfLines = 2
        stateHint = hint
        let done = PillButton(L("完成设置", "Done"), symbol: "checkmark", fill: accent,
                              target: self, action: #selector(hide))
        let doneWidth = done.frame.width
        add(done)
        done.setAccessibilityLabel(L("完成设置并保留提词器", "Finish settings and keep the teleprompter"))

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            header.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            header.heightAnchor.constraint(equalToConstant: 58),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor), heading.topAnchor.constraint(equalTo: header.topAnchor),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor), subtitle.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 23),
            closeButton.widthAnchor.constraint(equalToConstant: 32), closeButton.heightAnchor.constraint(equalToConstant: 32),
            toggle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            toggle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            toggle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16), toggle.heightAnchor.constraint(equalToConstant: 44),
            displayLabel.leadingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: 2),
            displayLabel.widthAnchor.constraint(equalToConstant: L("zh", "en") == "zh" ? 90 : 112),
            displayLabel.centerYAnchor.constraint(equalTo: displays.centerYAnchor),
            displays.leadingAnchor.constraint(equalTo: displayLabel.trailingAnchor, constant: 10),
            displays.trailingAnchor.constraint(equalTo: toggle.trailingAnchor),
            displays.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 14), displays.heightAnchor.constraint(equalToConstant: 34),
            scriptLabel.leadingAnchor.constraint(equalTo: displayLabel.leadingAnchor),
            scriptLabel.topAnchor.constraint(equalTo: displays.bottomAnchor, constant: 22),
            count.trailingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: -2), count.centerYAnchor.constraint(equalTo: scriptLabel.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: toggle.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: toggle.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: scriptLabel.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -22),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            done.widthAnchor.constraint(equalToConstant: doneWidth), done.heightAnchor.constraint(equalToConstant: 36),
            hint.leadingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: 2),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: done.leadingAnchor, constant: -20), hint.centerYAnchor.constraint(equalTo: done.centerYAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, text.frame.height)))
        setDisplayOptions(displayOptions, selected: selectedDisplay)
        refreshText()
        w.center()
    }

    func textDidChange(_ notification: Notification) {
        editor?.needsDisplay = true
        refreshText()
        draftSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushDraft(notify: true) }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func refreshText() {
        let count = scriptValue.count
        wordCount?.stringValue = L("\(count) 字", "\(count) characters")
        stateHint?.stringValue = prompterEnabled
            ? L("草稿自动保存 · 完成设置后继续提词", "Draft saved automatically · prompting continues after Done")
            : L("提词器已关闭 · 草稿会保留", "Teleprompter hidden · your draft is kept")
    }

    private func flushDraft(notify: Bool) {
        draftSave?.cancel()
        draftSave = nil
        savedScript = scriptValue
        setRecordConfig("narration_script", savedScript)
        if notify { onChange?(savedScript, prompterEnabled) }
    }

    @objc private func togglePrompter() { setPrompterEnabled(!prompterEnabled) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    deinit { draftSave?.cancel() }
}

private final class TeleprompterTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class TeleprompterDragView: NSView {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    // Static title/subtitle labels otherwise win hit-testing and swallow the drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSTextField ? self : hit
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onBegin?(); window?.performDrag(with: event); onEnd?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

// Paint the entire content view; the transparent window has no title-bar/background rim.
private final class TeleprompterSurfaceView: NSView {
    var onLayout: (() -> Void)?
    override var isOpaque: Bool { false }
    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.075, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill()
    }
    override func layout() { super.layout(); onLayout?() }
}

private enum TeleprompterResizeCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var label: String {
        switch self {
        case .topLeft: return L("左上角", "Top-left corner")
        case .topRight: return L("右上角", "Top-right corner")
        case .bottomLeft: return L("左下角", "Bottom-left corner")
        case .bottomRight: return L("右下角", "Bottom-right corner")
        }
    }
    func desiredSize(from initial: NSSize, delta: NSPoint) -> NSSize {
        NSSize(width: initial.width + (isLeft ? -delta.x : delta.x),
               height: initial.height + (isTop ? delta.y : -delta.y))
    }
    func resizedFrame(from initial: NSRect, to desired: NSSize, in visible: NSRect, minimum: NSSize) -> NSRect {
        // Normalize a manually moved-offscreen window once, then keep the opposite corner fixed.
        let minW = min(minimum.width, visible.width), minH = min(minimum.height, visible.height)
        let initialW = min(visible.width, max(minW, initial.width))
        let initialH = min(visible.height, max(minH, initial.height))
        let anchor = NSRect(x: max(visible.minX, min(initial.minX, visible.maxX - initialW)),
                            y: max(visible.minY, min(initial.minY, visible.maxY - initialH)),
                            width: initialW, height: initialH)
        let maxW = isLeft ? anchor.maxX - visible.minX : visible.maxX - anchor.minX
        let maxH = isTop ? visible.maxY - anchor.minY : anchor.maxY - visible.minY
        let width = min(maxW, max(minW, desired.width)), height = min(maxH, max(minH, desired.height))
        return NSRect(x: isLeft ? anchor.maxX - width : anchor.minX,
                      y: isTop ? anchor.minY : anchor.maxY - height, width: width, height: height)
    }
}

private final class TeleprompterResizeView: NSView {
    let corner: TeleprompterResizeCorner
    var onBegin: (() -> Void)?
    var onResize: ((NSSize) -> Void)?
    var onEnd: (() -> Void)?
    private var startPoint = NSPoint.zero
    private var startSize = NSSize.zero
    private static let risingCursor = diagonalCursor(descending: false)
    private static let fallingCursor = diagonalCursor(descending: true)

    init(corner: TeleprompterResizeCorner) { self.corner = corner; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private static func diagonalCursor(descending: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: descending ? 22 - y : y) }
            let path = NSBezierPath()
            path.move(to: point(4, 4)); path.line(to: point(18, 18))
            path.move(to: point(4, 10)); path.line(to: point(4, 4)); path.line(to: point(10, 4))
            path.move(to: point(12, 18)); path.line(to: point(18, 18)); path.line(to: point(18, 12))
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            NSColor.black.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = 1.8; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 11, y: 11))
    }
    override func draw(_ dirty: NSRect) {
        NSColor(white: 1, alpha: 0.32).setStroke()
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: corner.isLeft ? bounds.width - x : x, y: corner.isTop ? bounds.height - y : y)
        }
        // The strokes stay inside the window's rounded silhouette, with no square background.
        for segment in [(CGFloat(2), CGFloat(6), CGFloat(12), CGFloat(16)), (6, 6, 12, 12)] {
            let line = NSBezierPath()
            line.move(to: point(segment.0, segment.1)); line.line(to: point(segment.2, segment.3))
            line.lineWidth = 1.3
            line.lineCapStyle = .round
            line.stroke()
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: corner.isLeft == corner.isTop ? Self.fallingCursor : Self.risingCursor)
    }
    override func mouseDown(with event: NSEvent) {
        startPoint = NSEvent.mouseLocation
        startSize = window?.frame.size ?? .zero
        onBegin?()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        onResize?(corner.desiredSize(from: startSize, delta: NSPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)))
    }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

final class TeleprompterPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDisplayChange: ((CGDirectDisplayID?) -> Void)?
    var currentDisplayID: CGDirectDisplayID? { effectiveScreen().flatMap(Self.displayID) }
    private let surface = TeleprompterSurfaceView()
    private let drag = TeleprompterDragView()
    private let resizeHandles = TeleprompterResizeCorner.allCases.map { TeleprompterResizeView(corner: $0) }
    private let titleLabel = NSTextField(labelWithString: L("提词器", "Teleprompter"))
    private let privateLabel = NSTextField(labelWithString: L("不录入视频 · 拖动标题栏", "Hidden in video · drag header"))
    private let scroll = NSScrollView()
    private let text = TeleprompterTextView(frame: .zero)
    private let status = NSTextField(labelWithString: "")
    private let speedTitle = NSTextField(labelWithString: L("速度", "Speed"))
    private let speedValue = NSTextField(labelWithString: "")
    private let speed = NSSlider(value: 28, minValue: 8, maxValue: 72, target: nil, action: nil)
    private let dimensions = NSView()
    private let widthLabel = NSTextField(labelWithString: L("宽", "W"))
    private let heightLabel = NSTextField(labelWithString: L("高", "H"))
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private var applySizeButton: PillButton!
    private var autoButton: PillButton!
    private var resetButton: IconButton!
    private var fontDown: PillButton!
    private var fontUp: PillButton!
    private var editButton: IconButton!
    private var sizeButton: IconButton!
    private var closeButton: IconButton!
    private var fontSize: CGFloat = 23
    private var autoScroll = false
    private var recordingPaused = false
    private var previewMode = true
    private var standaloneMode = false
    private var reachedEnd = false
    private var showDimensions = false
    private var lastTick: TimeInterval?
    private var ended = false
    private var placed = false
    private var geometrySave: DispatchWorkItem?
    private var resizeAnchor: NSRect?
    private var resizeCorner: TeleprompterResizeCorner?
    private var resizeVisibleFrame: NSRect?
    private var recordingDisplayID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?
    private var screenSignature = ""
    private var lastScreenID: CGDirectDisplayID?
    private var lastScreenUUID: String?
    private var lastVisibleFrame: NSRect?
    private var lastPlacedFrame: NSRect?
    private var adjustingGeometry = false
    private var draggingHeader = false
    private var pendingScreenChange = false
    private var preservePreferredPlacement = false
    private var manualScrollUntil: TimeInterval = 0
    private var scrollObserver: NSObjectProtocol?
    private let minimumSize = NSSize(width: 360, height: 320)

    // Only explicit numeric editing needs keyboard focus; ordinary controls never steal it.
    override var canBecomeKey: Bool { showDimensions }
    override var canBecomeMain: Bool { false }

    init(script: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = true
        sharingType = chromeSharing
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        delegate = self
        setAccessibilityLabel(L("讲解提词器，不会出现在 Blurt 录制的视频里", "Narration teleprompter, excluded from the Blurt recording"))

        surface.frame = NSRect(origin: .zero, size: frame.size)
        surface.autoresizingMask = [.width, .height]
        contentView = surface
        surface.addSubview(drag)
        drag.onBegin = { [weak self] in self?.draggingHeader = true; self?.preservePreferredPlacement = false }
        drag.onEnd = { [weak self] in
            guard let self = self else { return }
            self.draggingHeader = false
            if self.pendingScreenChange { self.screenParametersChanged() }
            self.recordCurrentScreen(); self.saveGeometry()
        }
        drag.setAccessibilityLabel(L("拖动标题栏可移动提词器", "Drag the header to move the teleprompter"))
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        privateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        privateLabel.textColor = NSColor(white: 1, alpha: 0.55)
        for field in [titleLabel, privateLabel] {
            field.lineBreakMode = .byTruncatingTail
            drag.addSubview(field)
        }
        editButton = icon("pencil", L("编辑提词内容", "Edit script"), #selector(editScript))
        sizeButton = icon("arrow.up.left.and.arrow.down.right", L("设置宽度和高度；也可拖动四个角", "Set width and height, or drag any corner"), #selector(toggleDimensions))
        closeButton = icon("xmark", L("关闭提词器（录制继续）", "Hide teleprompter (recording continues)"), #selector(hidePrompter))
        for button in [editButton!, sizeButton!, closeButton!] { surface.addSubview(button) }

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        text.isEditable = false
        text.isSelectable = false
        text.isRichText = false
        text.drawsBackground = false
        text.textColor = .white
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = .width
        text.textContainerInset = NSSize(width: 4, height: 12)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 2
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.string = script
        text.setAccessibilityLabel(L("讲解逐字稿", "Narration script"))
        scroll.documentView = text
        surface.addSubview(scroll)

        autoButton = PillButton(L("自动滚动", "Auto-scroll"), symbol: "play.fill", fill: accent,
                                target: self, action: #selector(toggleAuto))
        autoButton.setAccessibilityLabel(L("开启或停止自动滚动", "Start or stop automatic scrolling"))
        resetButton = icon("arrow.counterclockwise", L("回到稿件开头", "Back to the beginning"), #selector(resetToTop))
        fontDown = PillButton("A−", fill: NSColor(white: 1, alpha: 0.10), target: self, action: #selector(decreaseFont))
        fontUp = PillButton("A+", fill: NSColor(white: 1, alpha: 0.10), target: self, action: #selector(increaseFont))
        fontDown.toolTip = L("减小字号", "Decrease text size")
        fontUp.toolTip = L("增大字号", "Increase text size")
        for button in [autoButton!, resetButton!, fontDown!, fontUp!] { surface.addSubview(button) }

        speed.target = self
        speed.action = #selector(changeSpeed)
        speed.isContinuous = true
        speed.setAccessibilityLabel(L("自动滚动速度", "Automatic scrolling speed"))
        speedTitle.font = .systemFont(ofSize: 11, weight: .medium)
        speedTitle.textColor = NSColor(white: 1, alpha: 0.55)
        speedValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        speedValue.textColor = .white
        speedValue.alignment = .right
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = NSColor(white: 1, alpha: 0.55)
        status.lineBreakMode = .byTruncatingTail
        for view in [speedTitle, speed, speedValue, status] { surface.addSubview(view) }

        for label in [widthLabel, heightLabel] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = NSColor(white: 1, alpha: 0.65)
            dimensions.addSubview(label)
        }
        for field in [widthField, heightField] {
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = true
            field.backgroundColor = NSColor(white: 0.17, alpha: 1)
            field.textColor = .white
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            field.alignment = .center
            field.focusRingType = .none
            field.wantsLayer = true
            field.layer?.cornerRadius = 7
            field.layer?.masksToBounds = true
            field.target = self
            field.action = #selector(applyDimensions)
            dimensions.addSubview(field)
        }
        widthField.setAccessibilityLabel(L("提词器宽度，单位为屏幕点", "Teleprompter width in screen points"))
        heightField.setAccessibilityLabel(L("提词器高度，单位为屏幕点", "Teleprompter height in screen points"))
        applySizeButton = PillButton(L("应用", "Apply"), fill: NSColor(white: 1, alpha: 0.12), target: self, action: #selector(applyDimensions))
        dimensions.addSubview(applySizeButton)
        dimensions.isHidden = true
        surface.addSubview(dimensions)
        for handle in resizeHandles {
            let corner = handle.corner
            handle.toolTip = corner.label + L(" · 拖动调整大小", " · Drag to resize")
            handle.setAccessibilityLabel(handle.toolTip)
            handle.onBegin = { [weak self] in
                guard let self = self else { return }
                self.resizeAnchor = self.frame; self.resizeCorner = corner
                self.resizeVisibleFrame = self.effectiveScreen()?.visibleFrame.insetBy(dx: 12, dy: 12)
                self.preservePreferredPlacement = false
            }
            handle.onResize = { [weak self] size in self?.resizePanel(to: size) }
            handle.onEnd = { [weak self] in
                guard let self = self else { return }
                self.resizeAnchor = nil; self.resizeCorner = nil; self.resizeVisibleFrame = nil
                if self.pendingScreenChange { self.screenParametersChanged() }
                self.recordCurrentScreen(); self.saveGeometry()
            }
            surface.addSubview(handle)
        }

        if let saved = recordConfig()["narration_font_size"] as? Double, saved.isFinite {
            fontSize = CGFloat(min(45, max(17, saved)))
        }
        if let saved = recordConfig()["narration_scroll_speed"] as? Double, saved.isFinite {
            speed.doubleValue = min(speed.maxValue, max(speed.minValue, saved))
        }
        scrollObserver = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
                                                                 object: scroll, queue: .main) { [weak self] _ in
            self?.manualScrollUntil = ProcessInfo.processInfo.systemUptime + 1.5
        }
        screenSignature = Self.currentScreenSignature()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            self?.screenParametersChanged()
        }
        surface.onLayout = { [weak self] in self?.layoutPanel() }
        layoutPanel()
        refreshSpeed()
        applyFont()
        refreshStatus()
    }

    private func icon(_ symbol: String, _ tip: String, _ action: Selector) -> IconButton {
        let button = IconButton(symbol: symbol, tip: tip, target: self, action: action)
        button.setAccessibilityLabel(tip)
        return button
    }

    private func layoutPanel() {
        let w = surface.bounds.width, h = surface.bounds.height
        guard w > 0, h > 0 else { return }
        drag.frame = NSRect(x: 0, y: h - 66, width: w, height: 66)
        titleLabel.frame = NSRect(x: 20, y: 32, width: max(1, w - 152), height: 21)
        privateLabel.frame = NSRect(x: 20, y: 13, width: max(1, w - 152), height: 16)
        editButton.frame.origin = NSPoint(x: w - 122, y: h - 47)
        sizeButton.frame.origin = NSPoint(x: w - 86, y: h - 47)
        closeButton.frame.origin = NSPoint(x: w - 50, y: h - 47)
        let textBottom: CGFloat = showDimensions ? 171 : 127
        scroll.frame = NSRect(x: 16, y: textBottom, width: w - 32, height: max(1, h - textBottom - 66))
        autoButton.frame = NSRect(x: 20, y: 78, width: 140, height: 34)
        resetButton.frame.origin = NSPoint(x: 168, y: 79)
        fontDown.frame = NSRect(x: w - 114, y: 78, width: 43, height: 34)
        fontUp.frame = NSRect(x: w - 63, y: 78, width: 43, height: 34)
        speedTitle.frame = NSRect(x: 20, y: 49, width: 40, height: 16)
        speed.frame = NSRect(x: 66, y: 45, width: w - 149, height: 24)
        speedValue.frame = NSRect(x: w - 74, y: 49, width: 54, height: 16)
        status.frame = NSRect(x: 20, y: 20, width: w - 63, height: 16)
        dimensions.frame = NSRect(x: 20, y: 124, width: w - 40, height: 34)
        widthLabel.frame = NSRect(x: 0, y: 9, width: 20, height: 17)
        widthField.frame = NSRect(x: 25, y: 3, width: 71, height: 27)
        heightLabel.frame = NSRect(x: 109, y: 9, width: 20, height: 17)
        heightField.frame = NSRect(x: 135, y: 3, width: 71, height: 27)
        applySizeButton.frame = NSRect(x: dimensions.bounds.width - 76, y: 1, width: 76, height: 32)
        // 18pt targets meet, but never overlap, the header buttons and title labels.
        for handle in resizeHandles {
            handle.frame = NSRect(x: handle.corner.isLeft ? 0 : w - 18,
                                  y: handle.corner.isTop ? h - 18 : 0, width: 18, height: 18)
        }
        sizeText()
        surface.needsDisplay = true
    }

    static func preferredDisplayID(fallback: CGDirectDisplayID?) -> CGDirectDisplayID? {
        let saved = recordConfig()["narration_panel_position"] as? [String: Any] ?? [:]
        if let uuid = saved["display_uuid"] as? String {
            if let found = NSScreen.screens.first(where: { displayUUID($0) == uuid }) { return displayID(found) }
            // A disconnected UUID must not accidentally resolve to a reused numeric ID.
        } else {
            if let oldID = (saved["display_id"] as? NSNumber)?.uint32Value,
               let found = NSScreen.screens.first(where: { displayID($0) == oldID }) { return displayID(found) }
            if let x = saved["x"] as? Double, let y = saved["y"] as? Double, x.isFinite, y.isFinite,
               let found = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: x, y: y)) }) { return displayID(found) }
        }
        if let fallback = fallback, NSScreen.screens.contains(where: { displayID($0) == fallback }) { return fallback }
        return (NSScreen.main ?? NSScreen.screens.first).flatMap(displayID)
    }

    static func rememberPreferredDisplay(_ id: CGDirectDisplayID) {
        guard let target = NSScreen.screens.first(where: { displayID($0) == id }) else { return }
        let saved = recordConfig()["narration_panel_position"] as? [String: Any] ?? [:]
        let visible = target.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(width: min(visible.width, max(360, savedDimension(saved["width"], fallback: 440))),
                          height: min(visible.height, max(320, savedDimension(saved["height"], fallback: 520))))
        let frame = NSRect(x: visible.maxX - size.width, y: visible.maxY - size.height, width: size.width, height: size.height)
        setRecordConfig("narration_panel_position", geometryRecord(frame, on: target))
    }

    func move(to displayID: CGDirectDisplayID) {
        guard let target = NSScreen.screens.first(where: { Self.displayID($0) == displayID }) else { return }
        let visible = target.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = boundedSize(frame.size, in: visible)
        preservePreferredPlacement = false
        screenSignature = Self.currentScreenSignature()
        applyPlacement(NSRect(x: visible.maxX - size.width, y: visible.maxY - size.height, width: size.width, height: size.height))
        placed = true
        recordCurrentScreen(forceNotify: true); saveGeometry()
    }

    func place(near region: CGRect) {
        guard !placed else { return }
        let r = toNS(region)
        guard let recordingScreen = NSScreen.screens.max(by: {
            let a = $0.frame.intersection(r), b = $1.frame.intersection(r)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }) else { return }
        recordingDisplayID = Self.displayID(recordingScreen)
        let selected = Self.preferredDisplayID(fallback: recordingDisplayID)
        let target = NSScreen.screens.first(where: { Self.displayID($0) == selected }) ?? recordingScreen
        let saved = recordConfig()["narration_panel_position"] as? [String: Any] ?? [:]
        let visible = target.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = boundedSize(NSSize(width: Self.savedDimension(saved["width"], fallback: 440),
                                      height: Self.savedDimension(saved["height"], fallback: 520)), in: visible)
        let savedUUID = saved["display_uuid"] as? String
        let matches = savedUUID.map { $0 == Self.displayUUID(target) } ?? true
        preservePreferredPlacement = savedUUID != nil && !matches
        let topRight = NSPoint(x: visible.maxX - size.width, y: visible.maxY - size.height)
        var origin = topRight
        if matches {
            if let x = saved["relative_x"] as? Double, let y = saved["relative_y"] as? Double, x.isFinite, y.isFinite {
                origin = Self.restoredOrigin(NSPoint(x: x, y: y), size: size, visible: visible)
            } else if let x = saved["x"] as? Double, let y = saved["y"] as? Double, x.isFinite, y.isFinite {
                origin = NSPoint(x: max(visible.minX, min(x, visible.maxX - size.width)),
                                 y: max(visible.minY, min(y, visible.maxY - size.height)))
            }
        }
        screenSignature = Self.currentScreenSignature()
        applyPlacement(NSRect(origin: origin, size: size))
        resetToTop()
        placed = true
        recordCurrentScreen()
    }

    private static func savedDimension(_ value: Any?, fallback: CGFloat) -> CGFloat {
        guard let value = value as? Double, value.isFinite, value > 0 else { return fallback }
        return CGFloat(value)
    }
    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let id = displayID(screen), let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
    private static func relativeOrigin(_ frame: NSRect, visible: NSRect) -> NSPoint {
        NSPoint(x: visible.width > frame.width ? max(0, min(1, (frame.minX - visible.minX) / (visible.width - frame.width))) : 1,
                y: visible.height > frame.height ? max(0, min(1, (frame.minY - visible.minY) / (visible.height - frame.height))) : 1)
    }
    private static func restoredOrigin(_ relative: NSPoint, size: NSSize, visible: NSRect) -> NSPoint {
        NSPoint(x: visible.minX + max(0, visible.width - size.width) * max(0, min(1, relative.x)),
                y: visible.minY + max(0, visible.height - size.height) * max(0, min(1, relative.y)))
    }
    private static func geometryRecord(_ frame: NSRect, on screen: NSScreen) -> [String: Any] {
        let relative = relativeOrigin(frame, visible: screen.visibleFrame.insetBy(dx: 12, dy: 12))
        var saved: [String: Any] = ["x": Double(frame.minX), "y": Double(frame.minY),
                                   "width": Double(frame.width), "height": Double(frame.height),
                                   "relative_x": Double(relative.x), "relative_y": Double(relative.y)]
        if let id = displayID(screen) { saved["display_id"] = Int(id) }
        if let uuid = displayUUID(screen) { saved["display_uuid"] = uuid }
        return saved
    }
    private static func currentScreenSignature() -> String {
        NSScreen.screens.map { "\(displayID($0) ?? 0):\($0.frame):\($0.visibleFrame)" }.sorted().joined(separator: "|")
    }
    private func effectiveScreen() -> NSScreen? {
        NSScreen.screens.filter { $0.frame.intersects(frame) }.max {
            let a = $0.frame.intersection(frame), b = $1.frame.intersection(frame)
            return a.width * a.height < b.width * b.height
        }
    }
    private func applyPlacement(_ newFrame: NSRect) {
        adjustingGeometry = true
        setFrame(newFrame, display: true)
        layoutPanel(); refreshDimensionFields()
        adjustingGeometry = false
    }
    private func recordCurrentScreen(forceNotify: Bool = false) {
        guard placed, !adjustingGeometry, screenSignature == Self.currentScreenSignature() else { return }
        let current = effectiveScreen()
        let id = current.flatMap(Self.displayID)
        let changed = id != lastScreenID
        lastScreenID = id
        lastScreenUUID = current.flatMap(Self.displayUUID)
        lastVisibleFrame = current?.visibleFrame.insetBy(dx: 12, dy: 12)
        lastPlacedFrame = frame
        if changed || forceNotify { onDisplayChange?(id) }
    }
    private func screenParametersChanged() {
        guard placed, screenSignature != Self.currentScreenSignature() else { return }
        guard !draggingHeader, resizeAnchor == nil else { pendingScreenChange = true; return }
        pendingScreenChange = false
        let previousFrame = lastPlacedFrame ?? frame
        let stillPresent = NSScreen.screens.first { Self.displayUUID($0) == lastScreenUUID }
        let fallback = NSScreen.screens.first { Self.displayID($0) == recordingDisplayID } ?? NSScreen.main ?? NSScreen.screens.first
        guard let target = stillPresent ?? fallback else { return }
        let visible = target.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = boundedSize(previousFrame.size, in: visible)
        let origin: NSPoint
        if stillPresent != nil, let oldVisible = lastVisibleFrame {
            origin = Self.restoredOrigin(Self.relativeOrigin(previousFrame, visible: oldVisible), size: size, visible: visible)
        } else {
            preservePreferredPlacement = true
            origin = NSPoint(x: visible.maxX - size.width, y: visible.maxY - size.height)
        }
        screenSignature = Self.currentScreenSignature()
        applyPlacement(NSRect(origin: origin, size: size))
        recordCurrentScreen()
        if !preservePreferredPlacement { saveGeometry() }
    }
    private func boundedSize(_ size: NSSize, in visible: NSRect) -> NSSize {
        NSSize(width: min(visible.width, max(minimumSize.width, size.width)),
               height: min(visible.height, max(minimumSize.height, size.height)))
    }
    private func resizePanel(to desiredSize: NSSize) {
        guard desiredSize.width.isFinite, desiredSize.height.isFinite,
              let screen = screen ?? NSScreen.main else { return }
        let visible = resizeVisibleFrame ?? screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let newFrame: NSRect
        if let anchor = resizeAnchor, let corner = resizeCorner {
            newFrame = corner.resizedFrame(from: anchor, to: desiredSize, in: visible, minimum: minimumSize)
        } else {
            // Numeric width/height edits may reposition the whole window to keep it onscreen.
            let size = boundedSize(desiredSize, in: visible)
            let origin = NSPoint(x: max(visible.minX, min(frame.minX, visible.maxX - size.width)),
                                 y: max(visible.minY, min(frame.maxY - size.height, visible.maxY - size.height)))
            newFrame = NSRect(origin: origin, size: size)
        }
        setFrame(newFrame, display: true)
        layoutPanel()
        refreshDimensionFields()
        scheduleGeometrySave()
    }
    private func refreshDimensionFields() {
        widthField.stringValue = String(Int(frame.width.rounded()))
        heightField.stringValue = String(Int(frame.height.rounded()))
    }
    func windowDidMove(_ notification: Notification) { recordCurrentScreen(); scheduleGeometrySave() }
    func windowDidChangeScreen(_ notification: Notification) { recordCurrentScreen(); scheduleGeometrySave() }
    func windowDidResize(_ notification: Notification) { layoutPanel(); recordCurrentScreen(); scheduleGeometrySave() }
    private func scheduleGeometrySave() {
        guard placed, !adjustingGeometry, screenSignature == Self.currentScreenSignature() else { return }
        geometrySave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveGeometry() }
        geometrySave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    private func saveGeometry() {
        guard placed, !preservePreferredPlacement, screenSignature == Self.currentScreenSignature(),
              frame.origin.x.isFinite, frame.origin.y.isFinite, let target = effectiveScreen() else { return }
        setRecordConfig("narration_panel_position", Self.geometryRecord(frame, on: target))
    }

    func setScript(_ script: String) {
        guard text.string != script else { return }
        let oldLimit = max(0, text.bounds.height - scroll.contentView.bounds.height)
        let fraction = oldLimit > 0 ? scroll.contentView.bounds.minY / oldLimit : 0
        text.string = script
        applyFont()
        let limit = max(0, text.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(limit, max(0, fraction * limit))))
        scroll.reflectScrolledClipView(scroll.contentView)
        reachedEnd = false
        lastTick = nil
        refreshStatus()
    }
    func setPreviewMode(_ isPreview: Bool) {
        previewMode = isPreview
        recordingPaused = false
        lastTick = nil
        refreshStatus()
    }
    func setStandaloneMode(_ enabled: Bool) {
        standaloneMode = enabled
        recordingPaused = false
        lastTick = nil
        privateLabel.stringValue = enabled
            ? L("独立提词 · 拖动标题栏", "Standalone · drag header")
            : L("不录入视频 · 拖动标题栏", "Hidden in video · drag header")
        setAccessibilityLabel(enabled
            ? L("独立提词器，可阅读、滚动和编辑讲稿", "Standalone teleprompter for reading, scrolling, and editing scripts")
            : L("讲解提词器，不会出现在 Blurt 录制的视频里", "Narration teleprompter, excluded from the Blurt recording"))
        let closeTip = enabled ? L("关闭提词器", "Hide teleprompter")
                               : L("关闭提词器（录制继续）", "Hide teleprompter (recording continues)")
        closeButton.toolTip = closeTip
        closeButton.setAccessibilityLabel(closeTip)
        refreshStatus()
    }
    // The owner's standalone/preview/HUD timer drives scrolling. Hidden panels do not advance.
    func update(paused: Bool) {
        guard !ended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.25, max(0, now - (lastTick ?? now)))
        lastTick = now
        let justResumed = recordingPaused && !paused
        recordingPaused = paused
        refreshStatus()
        guard isVisible, autoScroll, !paused, !justResumed, now >= manualScrollUntil else { return }
        let clip = scroll.contentView
        let limit = max(0, text.bounds.height - clip.bounds.height)
        let y = min(limit, max(0, clip.bounds.minY) + CGFloat(dt * speed.doubleValue))
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        if y >= limit { autoScroll = false; reachedEnd = true; refreshStatus() }
    }
    func stopScrolling() {
        ended = true
        autoScroll = false
        lastTick = nil
        geometrySave?.cancel()
        geometrySave = nil
        saveGeometry()
        if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer); scrollObserver = nil }
    }

    private func refreshStatus() {
        autoButton.title = autoScroll ? L("暂停滚动", "Pause scroll") : L("自动滚动", "Auto-scroll")
        autoButton.image = NSImage(systemSymbolName: autoScroll ? "pause.fill" : "play.fill", accessibilityDescription: autoButton.title)
        autoButton.fill = autoScroll ? NSColor(white: 1, alpha: 0.15) : accent
        autoButton.needsDisplay = true
        status.textColor = recordingPaused ? amber : NSColor(white: 1, alpha: 0.55)
        if standaloneMode {
            if recordingPaused {
                status.stringValue = autoScroll ? L("已暂停 · 继续时恢复滚动", "Paused · scrolling resumes when continued")
                                                : L("已暂停 · 可手动滚动", "Paused · scroll manually")
            } else if reachedEnd {
                status.stringValue = L("已到稿件末尾 · 可回到开头", "End of script · return to the beginning")
            } else {
                status.stringValue = autoScroll ? L("自动滚动中 · 可手动调整", "Auto-scrolling · scroll manually to adjust")
                                                : L("手动滚动 · 开启自动滚动开始提词", "Scroll manually, or start Auto-scroll")
            }
            return
        }
        let mode = previewMode ? L("预览", "Preview") : L("录制中", "Recording")
        if recordingPaused {
            status.stringValue = autoScroll ? L("录制已暂停 · 滚动同步暂停", "Recording paused · scrolling paused")
                                             : L("录制已暂停 · 可手动滚动", "Recording paused · scroll manually")
        } else if reachedEnd {
            status.stringValue = mode + L(" · 已到稿件末尾", " · End of script")
        } else {
            status.stringValue = mode + (autoScroll ? L(" · 自动滚动中，可手动调整", " · Auto-scrolling, or scroll manually")
                                                     : L(" · 手动滚动，或开启自动滚动", " · Scroll manually, or start Auto-scroll"))
        }
    }
    private func sizeText() {
        let width = max(1, scroll.contentSize.width)
        let oldY = scroll.contentView.bounds.minY
        text.setFrameSize(NSSize(width: width, height: max(1, text.frame.height)))
        guard let container = text.textContainer, let layout = text.layoutManager else { return }
        container.containerSize = NSSize(width: max(1, width - text.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = max(scroll.contentSize.height, ceil(layout.usedRect(for: container).height) + text.textContainerInset.height * 2)
        text.setFrameSize(NSSize(width: width, height: height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, height - scroll.contentSize.height), max(0, oldY))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func applyFont() {
        let oldLimit = max(0, text.bounds.height - scroll.contentView.bounds.height)
        let fraction = oldLimit > 0 ? scroll.contentView.bounds.minY / oldLimit : 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        paragraph.paragraphSpacing = 15
        text.textStorage?.setAttributes([.font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                                        .foregroundColor: NSColor.white, .paragraphStyle: paragraph],
                                       range: NSRange(location: 0, length: (text.string as NSString).length))
        sizeText()
        let limit = max(0, text.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(limit, max(0, fraction * limit))))
        scroll.reflectScrolledClipView(scroll.contentView)
        fontDown.isEnabled = fontSize > 17
        fontUp.isEnabled = fontSize < 45
        fontDown.alphaValue = fontDown.isEnabled ? 1 : 0.35
        fontUp.alphaValue = fontUp.isEnabled ? 1 : 0.35
    }
    @objc private func toggleAuto() {
        autoScroll.toggle()
        reachedEnd = false
        lastTick = nil
        manualScrollUntil = 0
        refreshStatus()
    }
    @objc private func resetToTop() {
        reachedEnd = false
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        lastTick = nil
        refreshStatus()
    }
    @objc private func decreaseFont() { fontSize = max(17, fontSize - 2); applyFont(); setRecordConfig("narration_font_size", Double(fontSize)) }
    @objc private func increaseFont() { fontSize = min(45, fontSize + 2); applyFont(); setRecordConfig("narration_font_size", Double(fontSize)) }
    private func refreshSpeed() { speedValue.stringValue = String(format: "%.1f×", speed.doubleValue / 28) }
    @objc private func changeSpeed() { refreshSpeed(); setRecordConfig("narration_scroll_speed", speed.doubleValue) }
    @objc private func editScript() { onEdit?() }
    @objc private func toggleDimensions() {
        showDimensions.toggle()
        dimensions.isHidden = !showDimensions
        sizeButton.tint = showDimensions ? accent : .white
        if !showDimensions { makeFirstResponder(nil); resignKey() }
        refreshDimensionFields()
        layoutPanel()
    }
    @objc private func applyDimensions() {
        guard let width = Double(widthField.stringValue), let height = Double(heightField.stringValue), width.isFinite, height.isFinite else {
            refreshDimensionFields(); return
        }
        makeFirstResponder(nil)
        preservePreferredPlacement = false
        resizePanel(to: NSSize(width: width, height: height))
        saveGeometry()
    }
    @objc private func hidePrompter() {
        makeFirstResponder(nil)
        saveGeometry()
        orderOut(nil)
        lastTick = nil
        onClose?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hidePrompter(); return false }
    deinit {
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
        geometrySave?.cancel()
        if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) }
    }
}


// MARK: - Camera overlay positioning (the recorder composites camera pixels separately)

private enum CameraResizeCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var label: String {
        switch self {
        case .topLeft: return L("左上角", "Top-left corner")
        case .topRight: return L("右上角", "Top-right corner")
        case .bottomLeft: return L("左下角", "Bottom-left corner")
        case .bottomRight: return L("右下角", "Bottom-right corner")
        }
    }
    func resizedFrame(from initial: NSRect, delta: NSPoint, in region: NSRect) -> NSRect {
        let dx = isLeft ? -delta.x : delta.x
        let dy = isTop ? delta.y : -delta.y
        let change = abs(dx) >= abs(dy) ? dx : dy
        let minimum = min(region.width, region.height) * 0.12
        let maximum = min(region.width, region.height) * 0.6
        let availableX = isLeft ? initial.maxX - region.minX : region.maxX - initial.minX
        let availableY = isTop ? region.maxY - initial.minY : initial.maxY - region.minY
        let side = max(0, min(availableX, availableY, maximum, max(minimum, initial.width + change)))
        return NSRect(x: isLeft ? initial.maxX - side : initial.minX,
                      y: isTop ? initial.minY : initial.maxY - side, width: side, height: side)
    }
}

private final class CameraOverlaySurface: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var circular = true { didSet { needsDisplay = true } }
    var onDrag: ((NSPoint, Bool) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var dragStart = NSPoint.zero
    private var tracking: NSTrackingArea?
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let item = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(item); tracking = item
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { dragStart = NSEvent.mouseLocation; onDrag?(.zero, true) }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        onDrag?(NSPoint(x: point.x - dragStart.x, y: point.y - dragStart.y), false)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let path = circular ? CGPath(ellipseIn: bounds, transform: nil) : CGPath(rect: bounds, transform: nil)
        context.addPath(path); context.clip()
        context.setFillColor(NSColor(calibratedRed: 0.105, green: 0.112, blue: 0.125, alpha: 1).cgColor)
        context.fill(bounds)
        if let image = image {
            let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height))
        } else {
            let edge = min(40, bounds.width * 0.24)
            NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: edge, weight: .regular)
                    .applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.3)])))?
                .draw(in: NSRect(x: (bounds.width - edge) / 2, y: (bounds.height - edge) / 2, width: edge, height: edge))
        }
        context.restoreGState()
    }
}

private final class CameraOverlayResizeHandle: NSView {
    let corner: CameraResizeCorner
    var onResize: ((NSPoint, Bool) -> Void)?
    var highlighted = false { didSet { needsDisplay = true } }
    private var startPoint = NSPoint.zero
    init(corner: CameraResizeCorner) { self.corner = corner; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { startPoint = NSEvent.mouseLocation; onResize?(.zero, true) }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        onResize?(NSPoint(x: point.x - startPoint.x, y: point.y - startPoint.y), false)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor(white: 0.12, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 7, dy: 7)).fill()
        NSColor(white: 1, alpha: 0.85).setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 7, dy: 7)); ring.lineWidth = 1.2; ring.stroke()
    }
}

/// Its local preview is excluded with all Blurt chrome. Only camera pixels and this
/// normalized placement are sent to the video compositor, never buttons or handles.
final class CameraOverlayPanel: NSPanel {
    var onClose: (() -> Void)?
    var onLayoutChange: ((CGRect) -> Void)?
    var onSizeChange: ((CGFloat) -> Void)?
    private let surface = CameraOverlaySurface()
    private let handles = CameraResizeCorner.allCases.map { CameraOverlayResizeHandle(corner: $0) }
    private var closeButton: IconButton!
    private var recordingRegion = CGRect.zero
    private var sizeFraction: CGFloat = 0.24
    private var savedOrigin: CGPoint?
    private var dragAnchor = NSRect.zero
    private var resizeAnchor = NSRect.zero
    private var geometrySave: DispatchWorkItem?
    var normalizedRect: CGRect {
        guard recordingRegion.width > 0, recordingRegion.height > 0 else { return .zero }
        let global = toCG(frame)
        return CGRect(x: (global.minX - recordingRegion.minX) / recordingRegion.width,
                      y: (global.minY - recordingRegion.minY) / recordingRegion.height,
                      width: frame.width / recordingRegion.width, height: frame.height / recordingRegion.height)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        let config = recordConfig()
        let requested = (config["narration_camera_size"] as? NSNumber)?.doubleValue ?? 0.24
        sizeFraction = CGFloat(requested.isFinite ? min(0.6, max(0.12, requested)) : 0.24)
        if let saved = config["narration_camera_position"] as? [String: Double],
           let x = saved["x"], let y = saved["y"], x.isFinite, y.isFinite {
            savedOrigin = CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
        }
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 220),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = chromeSharing
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityLabel(L("摄像头人像，将显示在成片中；拖动移动，四角缩放", "Camera overlay included in recording; drag to move or resize from any corner"))
        surface.frame = NSRect(origin: .zero, size: frame.size)
        surface.autoresizingMask = [.width, .height]
        contentView = surface
        surface.onDrag = { [weak self] delta, begin in
            guard let self = self, self.recordingRegion.width > 0 else { return }
            if begin { self.dragAnchor = self.frame; return }
            var next = self.dragAnchor.offsetBy(dx: delta.x, dy: delta.y)
            let region = toNS(self.recordingRegion)
            next.origin.x = max(region.minX, min(region.maxX - next.width, next.minX))
            next.origin.y = max(region.minY, min(region.maxY - next.height, next.minY))
            self.setFrame(self.alignedFrame(next), display: true)
            self.changedLayout(sizeChanged: false)
        }
        surface.onHover = { [weak self] inside in
            self?.closeButton.isHidden = !inside
            self?.handles.forEach { $0.highlighted = inside }
        }
        closeButton = IconButton(symbol: "xmark", tip: L("关闭摄像头，继续录制屏幕", "Turn off camera and keep recording the screen"), target: self, action: #selector(hideCamera))
        closeButton.isHidden = true
        surface.addSubview(closeButton)
        for handle in handles {
            handle.setAccessibilityLabel(handle.corner.label + L(" · 拖动调整摄像头大小", " · Drag to resize camera"))
            handle.onResize = { [weak self, weak handle] delta, begin in
                guard let self = self, let handle = handle, self.recordingRegion.width > 0 else { return }
                if begin { self.resizeAnchor = self.frame; return }
                let next = handle.corner.resizedFrame(from: self.resizeAnchor, delta: delta, in: toNS(self.recordingRegion))
                self.setFrame(self.alignedFrame(next), display: true)
                self.layoutControls()
                self.sizeFraction = self.frame.width / min(self.recordingRegion.width, self.recordingRegion.height)
                self.changedLayout(sizeChanged: true)
            }
            surface.addSubview(handle)
        }
        layoutControls()
    }

    func setRegion(_ region: CGRect) {
        guard !region.isNull, !region.isInfinite, region.width >= 2, region.height >= 2 else { return }
        if recordingRegion == region { return }
        let previous = recordingRegion.width > 0 ? normalizedRect.origin : savedOrigin
        recordingRegion = region
        let side = min(region.width, region.height) * sizeFraction
        let margin = min(24, min(region.width, region.height) * 0.025)
        let origin = previous ?? CGPoint(x: margin / region.width, y: (region.height - side - margin) / region.height)
        let global = CGRect(x: region.minX + max(0, min(region.width - side, origin.x * region.width)),
                            y: region.minY + max(0, min(region.height - side, origin.y * region.height)), width: side, height: side)
        setFrame(alignedFrame(toNS(global)), display: true)
        layoutControls()
        // Selecting a different recording display rehomes the camera but does not
        // replace the user's saved position until they explicitly move or resize it.
        onLayoutChange?(normalizedRect)
        onSizeChange?(sizeFraction)
    }

    func setImage(_ image: CGImage?) { surface.image = image }
    func setShape(circular: Bool) { surface.circular = circular }
    func setSizeFraction(_ fraction: CGFloat) {
        guard fraction.isFinite else { return }
        sizeFraction = min(0.6, max(0.12, fraction))
        guard recordingRegion.width > 0 else { return }
        let region = toNS(recordingRegion), side = min(region.width, region.height) * sizeFraction
        let next = NSRect(x: max(region.minX, min(region.maxX - side, frame.midX - side / 2)),
                          y: max(region.minY, min(region.maxY - side, frame.midY - side / 2)), width: side, height: side)
        setFrame(alignedFrame(next), display: true)
        layoutControls()
        changedLayout(sizeChanged: true)
    }

    private func alignedFrame(_ proposed: NSRect) -> NSRect {
        // NSWindow expands fractional sizes to whole points. Align before clamping
        // so its actual square frame never crosses a cropped recording boundary.
        let region = toNS(recordingRegion)
        let minX = ceil(region.minX), minY = ceil(region.minY)
        let maxX = floor(region.maxX), maxY = floor(region.maxY)
        let side = max(1, min(floor(min(proposed.width, proposed.height)), maxX - minX, maxY - minY))
        return NSRect(x: max(minX, min(maxX - side, proposed.minX.rounded())),
                      y: max(minY, min(maxY - side, proposed.minY.rounded())), width: side, height: side)
    }

    private func layoutControls() {
        let bounds = surface.bounds, handleSide = min(26, bounds.width / 3)
        for handle in handles {
            handle.frame = NSRect(x: handle.corner.isLeft ? 0 : bounds.width - handleSide,
                                  y: handle.corner.isTop ? bounds.height - handleSide : 0,
                                  width: handleSide, height: handleSide)
        }
        let closeSide = min(26, bounds.width / 3)
        closeButton.frame = NSRect(x: (bounds.width - closeSide) / 2, y: bounds.height - closeSide - 7,
                                   width: closeSide, height: closeSide)
    }
    private func changedLayout(sizeChanged: Bool) {
        savedOrigin = normalizedRect.origin
        onLayoutChange?(normalizedRect)
        if sizeChanged { onSizeChange?(sizeFraction) }
        geometrySave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveGeometry() }
        geometrySave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func saveGeometry() {
        guard let origin = savedOrigin else { return }
        setRecordConfig("narration_camera_position", ["x": Double(origin.x), "y": Double(origin.y)])
        setRecordConfig("narration_camera_size", Double(sizeFraction))
    }
    @objc private func hideCamera() { orderOut(nil); onClose?() }
    override func orderOut(_ sender: Any?) {
        geometrySave?.cancel(); geometrySave = nil
        saveGeometry()
        super.orderOut(sender)
    }
    deinit { geometrySave?.cancel() }
}

// MARK: - Live recording preview (no writer, microphone, or saved frames)

final class RecordingPreview: NSObject, SCStreamOutput, SCStreamDelegate {
    var displayID: CGDirectDisplayID?
    var expectedDisplayFrame: CGRect?
    private var stream: SCStream?
    private var stopped = false
    private var starting = false
    private let queue = DispatchQueue(label: "blurt.preview")
    private let context = CIContext()
    var onImage: ((NSImage) -> Void)?
    var onError: ((String) -> Void)?

    func start(region: CGRect) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self = self, !self.stopped else { return }
                guard let content = content else {
                    self.fail(error?.localizedDescription ?? L("无法读取屏幕预览，请检查录屏权限。", "Screen preview unavailable. Check Screen Recording permission.")); return
                }
                let center = CGPoint(x: region.midX, y: region.midY)
                guard let display = content.displays.first(where: { display in
                    self.displayID.map { display.displayID == $0 } ?? display.frame.contains(center)
                }) else {
                    self.fail(L("所选屏幕已断开，请重新选择录制区域。", "The selected display is unavailable. Choose another area.")); return
                }
                let clipped = region.intersection(display.frame)
                guard self.expectedDisplayFrame == nil || self.expectedDisplayFrame == display.frame else {
                    self.fail(L("屏幕布局已变化，请重新预览后录制。", "Display layout changed. Refresh the preview before recording.")); return
                }
                guard !clipped.isNull, clipped.width >= 8, clipped.height >= 8, clipped == region else {
                    self.fail(L("录制区域无效，请重新选择。", "Choose a valid recording area.")); return
                }
                let mine = content.applications.filter { $0.processID == getpid() }
                guard !mine.isEmpty else {
                    self.fail(L("暂时无法排除 Blurt 窗口，请重试预览。", "Could not exclude Blurt's windows. Retry the preview.")); return
                }
                let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                let ratio = min(1, 1100 / clipped.width)
                cfg.width = max(2, Int(clipped.width * ratio) / 2 * 2)
                cfg.height = max(2, Int(clipped.height * ratio) / 2 * 2)
                cfg.sourceRect = CGRect(x: clipped.minX - display.frame.minX, y: clipped.minY - display.frame.minY,
                                        width: clipped.width, height: clipped.height)
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 6)
                cfg.queueDepth = 3
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.showsCursor = true
                cfg.capturesAudio = false
                if #available(macOS 15.0, *) { cfg.captureMicrophone = false }
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                do {
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    self.stream = s
                    self.starting = true
                    s.startCapture { [weak self] error in
                        DispatchQueue.main.async {
                            guard let self = self else { s.stopCapture { _ in }; return }
                            self.starting = false
                            if self.stopped { s.stopCapture { _ in }; self.stream = nil; return }
                            if let error = error { self.fail(error.localizedDescription) }
                        }
                    }
                } catch { self.fail(error.localizedDescription) }
            }
        }
    }

    func stop() {
        stopped = true
        onImage = nil
        onError = nil
        if !starting { stream?.stopCapture { _ in }; stream = nil }
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        let callback = onError
        stop()
        callback?(message)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.fail(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.stopped else { return }
            self.onImage?(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }
    }
}

// MARK: - Camera capture

final class CameraCaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "blurt.camera.capture", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var latestFrame: CVPixelBuffer?
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var device: AVCaptureDevice?
    private var observers: [NSObjectProtocol] = []
    private var activeGeneration = 0
    private var pendingCompletion: ((Error?) -> Void)?
    var onFailure: ((String) -> Void)?

    static func devices() -> [AVCaptureDevice] {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                mediaType: .video, position: .unspecified).devices
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video, position: .unspecified).devices
    }

    private func nextGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        latestFrame = nil
        return generation
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }

    func snapshot() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latestFrame
    }

    // Success means a real frame is available, not merely that permission was granted.
    func start(deviceID: String?, completion: @escaping (Error?) -> Void) {
        let token = nextGeneration()
        queue.async { [weak self] in
            guard let self = self, self.isCurrent(token) else { return }
            self.teardown()
            self.activeGeneration = token
            self.pendingCompletion = completion
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configure(deviceID: deviceID, token: token)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self = self else { return }
                    self.queue.async {
                        guard self.isCurrent(token) else { return }
                        if granted { self.configure(deviceID: deviceID, token: token) }
                        else { self.fail(L("请在系统设置中允许 Blurt 使用摄像头。", "Allow Blurt to use the camera in System Settings."), token: token) }
                    }
                }
            default: self.fail(L("请在系统设置中允许 Blurt 使用摄像头。", "Allow Blurt to use the camera in System Settings."), token: token)
            }
        }
    }

    func stop() {
        _ = nextGeneration() // Invalidates permission/start callbacks and removes the image immediately.
        queue.async { self.teardown() } // Keep teardown off the main thread even if the owner releases us.
    }

    private func configure(deviceID: String?, token: Int) {
        guard isCurrent(token) else { return }
        let available = Self.devices()
        let selected = deviceID.flatMap { id in available.first { $0.uniqueID == id } }
            ?? (deviceID == nil ? available.first : nil)
        guard let selected = selected, selected.isConnected else {
            fail(L("未找到所选摄像头，请重新选择。", "The selected camera is unavailable. Choose another camera."), token: token); return
        }
        do {
            let capture = AVCaptureSession()
            capture.beginConfiguration()
            if capture.canSetSessionPreset(.hd1280x720) { capture.sessionPreset = .hd1280x720 }
            let input = try AVCaptureDeviceInput(device: selected)
            guard capture.canAddInput(input) else { throw NSError(domain: "blurt.camera", code: 1) }
            capture.addInput(input)
            let video = AVCaptureVideoDataOutput()
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            video.alwaysDiscardsLateVideoFrames = true
            video.setSampleBufferDelegate(self, queue: queue)
            guard capture.canAddOutput(video) else { throw NSError(domain: "blurt.camera", code: 2) }
            capture.addOutput(video)
            if let connection = video.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false // Preview and export apply the user's mirror setting once.
            }
            capture.commitConfiguration()
            guard isCurrent(token) else { return }
            session = capture; output = video; device = selected
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: capture, queue: nil) { [weak self] note in
                let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                    ?? L("摄像头已停止，请重新打开。", "The camera stopped. Turn it on again.")
                self?.queue.async { [weak self] in self?.fail(message, token: token) }
            })
            observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: capture, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.fail(L("摄像头暂时无法使用，请重新打开。", "The camera is unavailable. Turn it on again."), token: token) }
            })
            observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: selected, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.fail(L("摄像头已断开连接，请重新选择。", "The camera disconnected. Choose another camera."), token: token) }
            })
            capture.startRunning()
            guard isCurrent(token) else { teardown(); return }
            guard capture.isRunning else {
                fail(L("摄像头无法启动，可能正被其他应用使用。", "The camera could not start. It may be in use by another app."), token: token); return
            }
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self = self, self.isCurrent(token), self.pendingCompletion != nil else { return }
                self.fail(L("摄像头没有返回画面，请检查连接或重新选择。", "No camera image was received. Check its connection or choose another camera."), token: token)
            }
        } catch {
            fail(error.localizedDescription, token: token)
        }
    }

    private func teardown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        output?.setSampleBufferDelegate(nil, queue: nil)
        if session?.isRunning == true { session?.stopRunning() }
        session = nil; output = nil; device = nil; pendingCompletion = nil
    }

    private func fail(_ message: String, token: Int) {
        guard isCurrent(token) else { return }
        lock.lock(); latestFrame = nil; lock.unlock()
        let completion = pendingCompletion
        teardown()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isCurrent(token) else { return }
            let error = NSError(domain: "blurt.camera", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
            if let completion = completion { completion(error) } else { self.onFailure?(message) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let token = activeGeneration
        guard self.output === output, sampleBuffer.isValid, isCurrent(token),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        if generation == token { latestFrame = pixels }
        lock.unlock()
        if let completion = pendingCompletion {
            pendingCompletion = nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isCurrent(token), self.snapshot() != nil else { return }
                completion(nil)
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        output?.setSampleBufferDelegate(nil, queue: nil)
        if session?.isRunning == true { session?.stopRunning() }
    }
}

// MARK: - Camera compositing

struct CameraCompositeState {
    let pixelBuffer: CVPixelBuffer
    // Relative to the selected recording area; origin is its top-left corner.
    let normalizedRect: CGRect
    let circular: Bool
    let mirrored: Bool
}

final class CameraCompositor {
    private let context = CIContext()
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    // Shared by the setup preview and the actual MP4 writer: chrome is never composited.
    static func compositedImage(screen: CIImage, state: CameraCompositeState) -> CIImage {
        let bounds = screen.extent
        let n = state.normalizedRect
        guard [n.minX, n.minY, n.width, n.height].allSatisfy({ $0.isFinite }),
              n.width > 0, n.height > 0, bounds.width > 0, bounds.height > 0 else { return screen }
        let rect = CGRect(x: bounds.minX + n.minX * bounds.width,
                          y: bounds.minY + (1 - n.maxY) * bounds.height,
                          width: n.width * bounds.width, height: n.height * bounds.height)
        guard rect.intersects(bounds) else { return screen }
        var camera = CIImage(cvPixelBuffer: state.pixelBuffer)
        let source = camera.extent
        guard source.width > 0, source.height > 0 else { return screen }
        camera = camera.transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
        if state.mirrored {
            camera = camera.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: source.width, ty: 0))
        }
        let scale = max(rect.width / source.width, rect.height / source.height)
        camera = camera.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        camera = camera.transformed(by: CGAffineTransform(translationX: rect.midX - camera.extent.midX,
                                                         y: rect.midY - camera.extent.midY)).cropped(to: rect)
        if state.circular {
            // A grayscale radial mask has a one-output-pixel antialiased edge. UI always uses a square rect.
            let radius = min(rect.width, rect.height) / 2
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: rect.midX, y: rect.midY),
                "inputRadius0": max(0, radius - 0.75), "inputRadius1": radius + 0.25,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])!.outputImage!.cropped(to: rect)
            camera = camera.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: CIColor.clear).cropped(to: rect),
                kCIInputMaskImageKey: mask,
            ])
        }
        return camera.composited(over: screen).cropped(to: bounds)
    }

    func compositedBuffer(screen: CVPixelBuffer, state: CameraCompositeState) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(screen), height = CVPixelBufferGetHeight(screen)
        let size = CGSize(width: width, height: height)
        if pool == nil || poolSize != size {
            pool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            poolSize = size
        }
        guard let pool = pool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let destination = destination else { return nil }
        // Keep the screen's primaries, transfer function, color-space metadata and display dimensions.
        CVBufferPropagateAttachments(screen, destination)
        let image = Self.compositedImage(screen: CIImage(cvPixelBuffer: screen), state: state)
        let colorSpace = CVImageBufferGetColorSpace(screen)?.takeUnretainedValue() ?? CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(image, to: destination, bounds: image.extent, colorSpace: colorSpace)
        return destination
    }
}

// MARK: - Recorder

func audioInputDevices() -> [AVCaptureDevice] {
    if #available(macOS 14.0, *) {
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified).devices
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let region: CGRect
    let recordingDisplayID: CGDirectDisplayID?
    let recordingDisplayFrame: CGRect?
    var stream: SCStream?
    var writer: AVAssetWriter!
    var vIn: AVAssetWriterInput!
    var aIn: AVAssetWriterInput?
    let q = DispatchQueue(label: "blurt.capture")
    var started = false
    var sessionStart = CMTime.invalid
    var offset = CMTime.zero          // accumulated pause time
    var pausedAt: CMTime? = nil
    var lastVideo = CMTime.invalid
    var stopping = false
    var discard = false
    var micLevel: Float = 0
    var captureSession: AVCaptureSession?
    var events: FileHandle?
    var hud: HUD!
    var border: NSWindow?
    var borderView = BorderView()
    var ticker: Timer?
    var cursorTicker: Timer?
    var clickMonitor: Any?
    var frames = 0
    var audioBuffers = 0
    var onRestart: (() -> Void)?
    var teleprompter: TeleprompterPanel?
    var captureError: Error?
    var startingCapture = false
    var pendingStop: (discard: Bool, restart: Bool)?
    var onPrompterChanged: ((Bool) -> Void)?
    var onEditNarration: (() -> Void)?
    var onPrompterDisplayChanged: ((CGDirectDisplayID?) -> Void)?
    var onWillStop: ((Bool) -> Void)?
    private var willStopNotified = false
    // Install once before prepare. The closure snapshots thread-safe camera and placement state.
    var cameraFrameProvider: (() -> CameraCompositeState?)?
    private let cameraCompositor = CameraCompositor()
    private var latestScreenSample: CMSampleBuffer?
    private var cameraRefresh: DispatchSourceTimer?
    private var lastRawVideo = CMTime.invalid

    init(region: CGRect) {
        self.region = region
        recordingDisplayID = opts.narrationScript == nil ? nil : opts.recordingDisplayID
        recordingDisplayFrame = opts.narrationScript == nil ? nil : opts.recordingDisplayFrame
    }

    var isPaused: Bool { pausedAt != nil }
    var prompterVisible: Bool { teleprompter?.isVisible == true }

    func setPrompterEnabled(_ enabled: Bool, notify: Bool = true) {
        guard opts.narrationScript != nil, !stopping else { return }
        opts.prompterEnabled = enabled
        if enabled {
            if teleprompter == nil {
                let panel = TeleprompterPanel(script: opts.narrationScript ?? "")
                panel.onDisplayChange = { [weak self] id in self?.onPrompterDisplayChanged?(id) }
                panel.place(near: region)
                panel.setPreviewMode(false)
                panel.onClose = { [weak self] in self?.setPrompterEnabled(false) }
                panel.onEdit = { [weak self] in self?.onEditNarration?() }
                teleprompter = panel
            }
            teleprompter?.orderFrontRegardless()
        } else { teleprompter?.orderOut(nil) }
        if notify { onPrompterChanged?(enabled) }
    }

    func updateNarration(script: String, enabled: Bool) {
        opts.narrationScript = script
        teleprompter?.setScript(script)
        setPrompterEnabled(enabled, notify: false)
    }

    func elapsed() -> Double {
        guard sessionStart.isValid else { return 0 }
        let now = pausedAt ?? hostNow()
        return max(0, CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(now, sessionStart), offset)))
    }

    func log(_ type: String, _ extra: [String: Any] = [:]) {
        guard let fh = events else { return }
        var o: [String: Any] = ["t": (elapsed() * 1000).rounded() / 1000, "type": type]
        extra.forEach { o[$0.key] = $0.value }
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
            fh.write(d)
            fh.write("\n".data(using: .utf8)!)
        }
    }

    // --- setup
    func prepare(completion: @escaping (Error?) -> Void) {
        if opts.narrationScript != nil { setPrompterEnabled(opts.prompterEnabled, notify: false) }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, err in
            DispatchQueue.main.async {
                guard !self.stopping else { return }
                guard let content = content else { return completion(err ?? NSError(domain: "blurt", code: 1)) }
                do { try self.configure(content); completion(nil) } catch { completion(error) }
            }
        }
    }

    func configure(_ content: SCShareableContent) throws {
        let center = CGPoint(x: region.midX, y: region.midY)
        guard let display = content.displays.first(where: { display in
            recordingDisplayID.map { display.displayID == $0 } ?? display.frame.contains(center)
        }) else {
            throw NSError(domain: "blurt", code: 2, userInfo: [NSLocalizedDescriptionKey:
                L("所选屏幕已断开，请重新选择录制区域。", "The selected display is unavailable. Choose another area.")])
        }
        let clipped = region.intersection(display.frame)
        guard recordingDisplayFrame == nil || recordingDisplayFrame == display.frame else {
            throw NSError(domain: "blurt", code: 2, userInfo: [NSLocalizedDescriptionKey:
                L("屏幕布局已变化，请重新预览后录制。", "Display layout changed. Refresh the preview before recording.")])
        }
        guard !clipped.isNull, !clipped.isInfinite, clipped.width >= 8, clipped.height >= 8, clipped == region else {
            throw NSError(domain: "blurt", code: 2, userInfo: [NSLocalizedDescriptionKey:
                L("录制区域无效，请重新选择。", "Choose a valid recording area.")])
        }
        // Window IDs are a snapshot: they do not protect a HUD, prompt or dialog created later.
        let mine = content.applications.filter { $0.processID == getpid() }
        guard !mine.isEmpty else {
            throw NSError(domain: "blurt", code: 6, userInfo: [NSLocalizedDescriptionKey:
                L("无法安全排除提词窗，请重新打开 Blurt 后再试。", "Could not exclude Blurt's windows safely. Reopen Blurt and try again.")])
        }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let scale = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        })?.backingScaleFactor ?? 2
        var w = clipped.width * scale, h = clipped.height * scale
        if w > CGFloat(opts.maxWidth) { h = h * CGFloat(opts.maxWidth) / w; w = CGFloat(opts.maxWidth) }
        let W = Int(w) / 2 * 2, H = Int(h) / 2 * 2
        cfg.sourceRect = CGRect(x: clipped.minX - display.frame.minX, y: clipped.minY - display.frame.minY,
                                width: clipped.width, height: clipped.height)
        cfg.width = W
        cfg.height = H
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(opts.fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 8
        var scMic = false
        if opts.mic, #available(macOS 15.0, *) {
            cfg.captureMicrophone = true
            if let name = opts.micName,
               let dev = audioInputDevices()
                .first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) {
                cfg.microphoneCaptureDeviceID = dev.uniqueID
            }
            scMic = true
        }

        let url = URL(fileURLWithPath: opts.out)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false  // true leaves .sb-* temp files if we exit right after
        vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_500_000, Int(Double(W * H) * 2.2)),
                AVVideoExpectedSourceFrameRateKey: opts.fps,
                AVVideoMaxKeyFrameIntervalKey: opts.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        vIn.expectsMediaDataInRealTime = true
        writer.add(vIn)
        if opts.mic {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000,
            ])
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            aIn = a
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        if scMic, #available(macOS 15.0, *) {
            try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: q)
        }
        stream = s
        if opts.mic && !scMic { try setupLegacyMic() }
        if let e = opts.events {
            FileManager.default.createFile(atPath: e, contents: nil)
            events = FileHandle(forWritingAtPath: e)
        }
        emit(["event": "configured", "width": W, "height": H, "display": Int(display.displayID),
              "region": [clipped.minX, clipped.minY, clipped.width, clipped.height], "mic": opts.mic ? (scMic ? "screencapturekit" : "avcapture") : "none"])
    }

    func setupLegacyMic() throws {
        let devs = audioInputDevices()
        guard let dev = (opts.micName.flatMap { n in devs.first { $0.localizedName.localizedCaseInsensitiveContains(n) } })
                ?? AVCaptureDevice.default(for: .audio) else { return }
        let cs = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: dev)
        if cs.canAddInput(input) { cs.addInput(input) }
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: q)
        if cs.canAddOutput(out) { cs.addOutput(out) }
        captureSession = cs
    }

    // --- run
    func start() {
        guard !stopping, let stream = stream else { return }
        startingCapture = true
        stream.startCapture { err in
            DispatchQueue.main.async {
                self.startingCapture = false
                if let err = err { self.captureError = err }
                if let pending = self.pendingStop {
                    self.pendingStop = nil
                    self.stop(discard: pending.discard, restart: pending.restart)
                } else if err != nil {
                    self.stop()
                } else if !self.stopping {
                    self.captureSession?.startRunning()
                    self.showChrome()
                }
            }
        }
    }

    func showChrome() {
        let r = toNS(region)
        border = overlayWindow(r.insetBy(dx: -4, dy: -4), view: borderView)
        border?.orderFrontRegardless()
        hud = HUD(rec: self)
        hud.place(near: region)
        hud.orderFrontRegardless()
        // Keep moving text smooth; the ordinary feedback HUD only needs five updates per second.
        let interval = opts.narrationScript == nil ? 0.2 : 1.0 / 30.0
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.hud.update(elapsed: self.elapsed(), paused: self.isPaused, level: self.micLevel)
            self.teleprompter?.update(paused: self.isPaused || !self.started || !self.prompterVisible)
            self.borderView.color = self.isPaused ? amber : accent
        }
        cursorTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPaused, self.sessionStart.isValid else { return }
            self.logCursor()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self = self, !self.isPaused, let p = self.relative(NSEvent.mouseLocation) else { return }
            self.log("click", ["x": p.x, "y": p.y, "button": e.type == .rightMouseDown ? "right" : "left"])
        }
    }

    func relative(_ ns: NSPoint) -> CGPoint? {
        let cg = CGPoint(x: ns.x, y: primaryHeight - ns.y)
        guard region.contains(cg) else { return nil }
        return CGPoint(x: ((cg.x - region.minX) / region.width * 1000).rounded() / 1000,
                       y: ((cg.y - region.minY) / region.height * 1000).rounded() / 1000)
    }

    var lastCursor: CGPoint?
    func logCursor() {
        guard let p = relative(NSEvent.mouseLocation), p != lastCursor else { return }
        lastCursor = p
        log("cursor", ["x": p.x, "y": p.y])
    }

    func togglePause() {
        q.async {
            if let p = self.pausedAt {
                self.offset = CMTimeAdd(self.offset, CMTimeSubtract(hostNow(), p))
                self.pausedAt = nil
                DispatchQueue.main.async { self.log("resume"); emit(["event": "resumed", "t": self.elapsed()]) }
            } else if self.sessionStart.isValid {
                DispatchQueue.main.async { self.log("pause") }
                self.pausedAt = hostNow()
                DispatchQueue.main.async { emit(["event": "paused", "t": self.elapsed()]) }
            }
        }
    }

    func marker() {
        log("marker")
        emit(["event": "marker", "t": elapsed()])
        NSSound(named: "Tink")?.play()
    }

    func adjusted(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        if offset == .zero { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in 0..<count {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, !stopping else { return }
        if type == .screen {
            guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            handleScreenVideo(sb)
        } else {
            handleAudio(sb)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.captureError = error; self.stop() }
    }

    // AVCapture (macOS < 15 mic)
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let cs = captureSession, let clock = cs.synchronizationClock else { handleAudio(sb); return }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sb), from: clock, to: CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        if let o = out { handleAudio(o) }
    }

    func handleScreenVideo(_ sample: CMSampleBuffer) {
        // Always cache the original screen, including while paused. Re-compositing an already
        // composited image would leave a ghost when the camera moves, hides or disconnects.
        latestScreenSample = sample
        ensureCameraRefresh()
        handleVideo(sample)
    }

    func handleVideo(_ sb: CMSampleBuffer) {
        guard !stopping, captureError == nil else { return }
        if !started {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            guard writer.startWriting() else {
                failWriting()
                return
            }
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
            started = true
            DispatchQueue.main.async { emit(["event": "recording"]) }
        }
        if isPaused { return }
        let rawTime = CMSampleBufferGetPresentationTimeStamp(sb)
        let frameInterval = 1.0 / Double(max(1, opts.fps))
        if cameraFrameProvider != nil, lastRawVideo.isValid,
           CMTimeGetSeconds(CMTimeSubtract(rawTime, lastRawVideo)) < frameInterval * 0.85 { return }
        guard let adjustedSample = adjusted(sb), vIn.isReadyForMoreMediaData else { return }
        let adjustedTime = CMSampleBufferGetPresentationTimeStamp(adjustedSample)
        guard !lastVideo.isValid || CMTimeCompare(adjustedTime, lastVideo) > 0 else { return }
        var s = adjustedSample
        if let state = cameraFrameProvider?() {
            guard let screen = CMSampleBufferGetImageBuffer(adjustedSample),
                  let pixels = cameraCompositor.compositedBuffer(screen: screen, state: state),
                  let composed = sampleReplacingImage(adjustedSample, pixels: pixels) else {
                captureError = NSError(domain: "blurt.camera", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    L("无法合成摄像头画面，录制已停止。", "Could not composite the camera image. Recording stopped.")])
                DispatchQueue.main.async { self.stop() }
                return
            }
            s = composed
        }
        if vIn.append(s) {
            frames += 1
            lastVideo = CMSampleBufferGetPresentationTimeStamp(s)
            lastRawVideo = rawTime
        } else { failWriting() }
    }

    private func sampleReplacingImage(_ sample: CMSampleBuffer, pixels: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                formatDescriptionOut: &format) == noErr, let format = format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample))
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }

    private func ensureCameraRefresh() {
        guard cameraFrameProvider != nil, cameraRefresh == nil, !stopping else { return }
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 1.0 / Double(max(1, opts.fps)), repeating: 1.0 / Double(max(1, opts.fps)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.refreshCameraFrame() }
        cameraRefresh = timer
        timer.resume()
    }

    // ScreenCaptureKit suppresses unchanged screen frames. Camera motion must keep advancing
    // even over a static slide; the host clock shares ScreenCaptureKit's timestamp domain.
    func refreshCameraFrame() {
        guard !stopping, !isPaused, started, cameraFrameProvider != nil,
              let screen = latestScreenSample else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(max(1, opts.fps))),
            presentationTimeStamp: hostNow(), decodeTimeStamp: .invalid)
        var repeated: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: screen,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &repeated) == noErr,
              let repeated = repeated else { return }
        handleVideo(repeated)
    }

    func handleAudio(_ sb: CMSampleBuffer) {
        guard !stopping, captureError == nil else { return }
        micLevel = rms(sb)
        guard started, !isPaused, let a = aIn else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTimeCompare(pts, sessionStart) >= 0, let s = adjusted(sb), a.isReadyForMoreMediaData else { return }
        if a.append(s) { audioBuffers += 1 } else { failWriting() }
    }

    func failWriting() {
        captureError = writer.error ?? NSError(domain: "blurt", code: 5,
            userInfo: [NSLocalizedDescriptionKey: L("MP4 写入失败。", "Could not write the MP4.")])
        DispatchQueue.main.async { self.stop() }
    }

    func cleanupChrome() {
        ticker?.invalidate()
        cursorTicker?.invalidate()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        hud?.orderOut(nil)
        border?.orderOut(nil)
        teleprompter?.stopScrolling()
        teleprompter?.orderOut(nil)
    }

    func rms(_ sb: CMSampleBuffer) -> Float {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sb) else { return 0 }
        var len = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
              let p = ptr, len > 0 else { return 0 }
        var sum: Float = 0
        var n = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            p.withMemoryRebound(to: Float.self, capacity: len / 4) { f in
                for i in stride(from: 0, to: len / 4, by: 4) { sum += f[i] * f[i]; n += 1 }
            }
        } else {
            p.withMemoryRebound(to: Int16.self, capacity: len / 2) { f in
                for i in stride(from: 0, to: len / 2, by: 4) { let v = Float(f[i]) / 32768; sum += v * v; n += 1 }
            }
        }
        guard n > 0 else { return 0 }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return max(0, min(1, (db + 55) / 45))       // -55 dB … -10 dB → 0 … 1
    }

    func stop(discard: Bool = false, restart: Bool = false) {
        guard !stopping else { return }
        if startingCapture {
            pendingStop = (discard, restart)
            if !restart { notifyWillStop(restart: false) }
            cleanupChrome()
            return
        }
        self.discard = discard
        let endAt = CMTimeSubtract(pausedAt ?? hostNow(), offset)
        stopping = true
        notifyWillStop(restart: restart)
        cleanupChrome()
        log("stop")
        try? events?.close()
        captureSession?.stopRunning()
        let finish = {
            self.q.async {
                self.cameraRefresh?.cancel()
                self.cameraRefresh = nil
                self.latestScreenSample = nil
                guard self.started else {
                    self.writer?.cancelWriting()
                    DispatchQueue.main.async {
                        if discard {
                            try? FileManager.default.removeItem(atPath: opts.out)
                            if let e = opts.events { try? FileManager.default.removeItem(atPath: e) }
                        }
                        if restart { emit(["event": "restarting"]); self.onRestart?(); return }
                        sessionEnded(discard ? 2 : 4, discard ? ["event": "cancelled"]
                                     : ["event": "error", "code": "no_frames", "message": self.captureError?.localizedDescription ?? "no video frames captured"])
                    }
                    return
                }
                let completed = {
                    DispatchQueue.main.async {
                        if discard {
                            try? FileManager.default.removeItem(atPath: opts.out)
                            if let e = opts.events { try? FileManager.default.removeItem(atPath: e) }
                            if restart { emit(["event": "restarting"]); self.onRestart?(); return }
                            sessionEnded(2, ["event": "cancelled", "reason": "discarded"])
                            return
                        }
                        if self.writer.status != .completed || self.frames == 0 || self.captureError != nil {
                            sessionEnded(5, ["event": "error", "code": "writer", "message": self.captureError?.localizedDescription ?? self.writer.error?.localizedDescription ?? "MP4 did not finish"])
                            return
                        }
                        NSSound(named: "Submarine")?.play()
                        sessionEnded(0, ["event": "stopped", "file": opts.out, "duration": CMTimeGetSeconds(CMTimeSubtract(endAt, self.sessionStart)),
                                         "frames": self.frames, "audio_buffers": self.audioBuffers,
                                         "region": [self.region.minX, self.region.minY, self.region.width, self.region.height]])
                    }
                }
                // AVAssetWriter raises an Objective-C exception if finalized after cancellation/failure.
                guard self.writer.status == .writing else { completed(); return }
                self.vIn.markAsFinished()
                self.aIn?.markAsFinished()
                // Screen content may have been static at the end: extend to the real stop time.
                self.writer.endSession(atSourceTime: CMTimeMaximum(endAt, self.lastVideo))
                self.writer.finishWriting(completionHandler: completed)
            }
        }
        if let s = stream { s.stopCapture { _ in finish() } } else { finish() }
    }

    private func notifyWillStop(restart: Bool) {
        guard !willStopNotified else { return }
        willStopNotified = true
        if Thread.isMainThread { onWillStop?(restart) }
        else { DispatchQueue.main.async { self.onWillStop?(restart) } }
    }
}

// MARK: - Hotkeys (Carbon: work without Accessibility permission, even when we're not the active app)

enum HK: UInt32 { case pause = 1, marker = 2, stop = 3, toggleRec = 4, menu = 5, pickEnter = 10, pickEsc = 11, pickFull = 12 }
var hotkeyHandler: ((HK) -> Void)?
var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]

func installHotkeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &id)
        if let k = HK(rawValue: id.id) { hotkeyHandler?(k) }
        return noErr
    }, 1, &spec, nil, nil)
}

func registerHotkey(_ k: HK, key: Int, mods: Int) {
    guard hotkeyRefs[k.rawValue] == nil else { return }
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: OSType(0x626C7274), id: k.rawValue),
                        GetApplicationEventTarget(), 0, &ref)
    if let r = ref { hotkeyRefs[k.rawValue] = r }
}

func unregisterHotkey(_ k: HK) {
    if let r = hotkeyRefs.removeValue(forKey: k.rawValue) { UnregisterEventHotKey(r) }
}

let optShift = optionKey | shiftKey

var signalSources: [DispatchSourceSignal] = []

/// Called by the recorder when a take ends (stopped / cancelled / error). CLI mode exits; the menu-bar app carries on.
var sessionEnded: (Int32, [String: Any]) -> Void = { code, event in
    emit(event)
    DispatchQueue.main.asyncAfter(deadline: .now() + (code == 0 ? 0.4 : 0)) { exit(code) }
}

// MARK: - Workspaces (menu-bar app): where recordings go

let homeDir = FileManager.default.homeDirectoryForCurrentUser
let defaultWorkspace = homeDir.appendingPathComponent("Blurt")

func currentWorkspace() -> URL {
    if let p = recordConfig()["workspace"] as? String, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
    return defaultWorkspace
}

func knownWorkspaces() -> [URL] {
    let list = (recordConfig()["workspaces"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    return list.map { URL(fileURLWithPath: $0) }
}

/// Default workspace keeps recordings visible (~/Blurt/recordings); a bound project uses <repo>/.blurt/sessions.
func sessionsRoot(for ws: URL) -> URL {
    ws.standardizedFileURL == defaultWorkspace.standardizedFileURL
        ? ws.appendingPathComponent("recordings") : ws.appendingPathComponent(".blurt/sessions")
}

func ensureDefaultWorkspace() {
    let fm = FileManager.default
    try? fm.createDirectory(at: defaultWorkspace.appendingPathComponent("recordings"), withIntermediateDirectories: true)
    let guide = defaultWorkspace.appendingPathComponent("AGENTS.md")
    if !fm.fileExists(atPath: guide.path) {
        let text = """
        # Blurt workspace

        This folder is the default workspace of **blurt** (口喷鸡). Each folder in `recordings/` is one screen
        recording with narration (`recording.mp4`, `events.jsonl`, `meta.json`). Use the `blurt` skill to turn a
        recording into structured output (issues, ideas, notes…) — e.g. "process my latest blurt recording" /
        "处理最新的录屏". Outputs are written next to the recording.
        """
        try? text.write(to: guide, atomically: true, encoding: .utf8)
        try? fm.createSymbolicLink(at: defaultWorkspace.appendingPathComponent("CLAUDE.md"), withDestinationURL: guide)
    }
}

func newSessionDir() -> URL {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    let dir = sessionsRoot(for: currentWorkspace()).appendingPathComponent(f.string(from: Date()))
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func recentSessions(limit: Int = 8) -> [URL] {
    var dirs: [URL] = []
    for ws in Set([defaultWorkspace] + knownWorkspaces() + [currentWorkspace()]) {
        let root = sessionsRoot(for: ws)
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        dirs += items.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("recording.mp4").path) }
    }
    return Array(dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(limit))
}

/// Apps opened from Finder get a bare PATH, and many people add ~/.local/bin etc. only in ~/.zshrc — so ask an
/// interactive shell once (with a timeout) and add the usual install locations.
let userPATH: String = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-ilc", "printf '\\n__BLURT_PATH__%s' \"$PATH\""]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    var found = ""
    if (try? p.run()) != nil {
        let deadline = Date().addingTimeInterval(6)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let r = out.range(of: "__BLURT_PATH__") { found = String(out[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    let home = NSHomeDirectory()
    let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
                 "\(home)/.cargo/bin", "\(home)/.volta/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    var seen = Set<String>()
    return (found.split(separator: ":").map(String.init) + extra).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
}()

func findExecutable(_ name: String) -> String? {
    for dir in userPATH.split(separator: ":") {
        let path = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

func shell(_ cmd: String, cwd: URL, log: URL, done: @escaping (Int32) -> Void) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = userPATH
    env["BLURT_APP"] = "1"
    p.environment = env
    p.standardInput = FileHandle.nullDevice   // codex exec otherwise waits for more prompt on stdin
    p.currentDirectoryURL = cwd
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let fh = try? FileHandle(forWritingTo: log)
    p.standardOutput = fh
    p.standardError = fh
    p.terminationHandler = { pr in DispatchQueue.main.async { done(pr.terminationStatus) } }
    try? p.run()
}

func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: - App

/// A stable, locked bridge between the main-thread camera controls and the writer queue.
/// Window coordinates and AppKit state never escape onto the capture queue.
final class NarrationCameraFeed {
    let capture = CameraCaptureController()
    private let lock = NSLock()
    private var enabled = false
    private var rect = CGRect.zero
    private var circular = true
    private var mirrored = true

    func update(enabled: Bool, rect: CGRect, circular: Bool, mirrored: Bool) {
        lock.lock()
        self.enabled = enabled
        self.rect = rect
        self.circular = circular
        self.mirrored = mirrored
        lock.unlock()
    }

    func snapshot() -> CameraCompositeState? {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, rect.width > 0, rect.height > 0, let buffer = capture.snapshot() else { return nil }
        return CameraCompositeState(pixelBuffer: buffer, normalizedRect: rect, circular: circular, mirrored: mirrored)
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var picker: PickerController?
    var rec: Recorder?
    var countdownWin: NSWindow?
    var countdownTimer: Timer?
    var narrationSetup: NarrationSetupController?
    var narrationPreview: RecordingPreview?
    var previewPrompter: TeleprompterPanel?
    var previewPrompterTimer: Timer?
    var narrationRegion: CGRect?
    var narrationRecordingDisplayID: CGDirectDisplayID?
    var narrationPrompterDisplayID: CGDirectDisplayID?
    var narrationLocalRegion: CGRect?
    var narrationFullDisplay = false
    var narrationScreenObserver: NSObjectProtocol?
    var narrationCameraFeed: NarrationCameraFeed?
    var narrationCameraPanel: CameraOverlayPanel?
    var narrationCameraTimer: Timer?
    var narrationCameraGeneration = 0
    var narrationCameraDeviceID: String?
    var narrationCameraDeviceObservers: [NSObjectProtocol] = []
    var narrationCameraReady = false
    var narrationCameraStarting = false
    var narrationScreenPreviewImage: NSImage?
    private let narrationCameraContext = CIContext(options: [.cacheIntermediates: false])
    var standalonePrompterSetup: StandalonePrompterController?
    var standalonePrompter: TeleprompterPanel?
    var standalonePrompterTimer: Timer?
    var standalonePrompterDisplayID: CGDirectDisplayID?
    var standaloneScreenObserver: NSObjectProtocol?
    var statusItem: NSStatusItem?
    var busy = false                 // picking / counting down / recording
    var processing: [String] = []    // sessions being processed by an agent
    var statusTimer: Timer?
    var lastSession: URL?

    var resident: Bool { opts.standalone }

    func applicationDidFinishLaunching(_ n: Notification) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                guard let self = self else { return }
                if self.rec != nil { self.command("stop") } else if !self.resident { self.command("stop") } else { NSApp.terminate(nil) }
            }
            s.resume()
            signalSources.append(s)
        }
        installHotkeyHandler()
        hotkeyHandler = { [weak self] k in self?.hotkey(k) }
        registerHotkey(.pause, key: kVK_ANSI_P, mods: optShift)
        registerHotkey(.marker, key: kVK_ANSI_M, mods: optShift)
        registerHotkey(.stop, key: kVK_ANSI_S, mods: optShift)
        if resident {
            startResident()
            return
        }
        DispatchQueue.global().async {
            while let line = readLine() {
                let cmd = line.trimmingCharacters(in: .whitespaces).lowercased()
                DispatchQueue.main.async { self.command(cmd) }
            }
        }
        // Probe permission early so the user isn't asked mid-flow.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, err in
            DispatchQueue.main.async {
                if let err = err {
                    sessionEnded(3, ["event": "error", "code": "screen_permission", "message": err.localizedDescription])
                    return
                }
                if let r = opts.region { self.begin(r) } else { self.pick() }
            }
        }
    }

    func hotkey(_ k: HK) {
        switch k {
        case .pause: command("toggle")
        case .marker: command("marker")
        case .stop: command("stop")
        case .toggleRec: rec != nil ? command("stop") : (busy ? nil : startRecording(useLast: false))
        case .menu: popMenu()
        case .pickEnter: picker?.finish(true)
        case .pickEsc: picker?.finish(false)
        case .pickFull: picker?.fullScreen()
        }
    }

    func command(_ c: String) {
        switch c {
        case "stop":
            if let r = rec { r.stop() } else if let p = picker { p.finish(false) } else if !resident { sessionEnded(2, ["event": "cancelled"]) }
        case "discard": rec?.stop(discard: true)
        case "restart": rec?.stop(discard: true, restart: true)
        case "pause": if rec?.isPaused == false { rec?.togglePause() }
        case "resume": if rec?.isPaused == true { rec?.togglePause() }
        case "toggle": rec?.togglePause()
        case "marker": rec?.marker()
        default: break
        }
    }

    func pick() {
        busy = true
        let p = PickerController()
        p.onDone = { [weak self] r in
            guard let self = self else { return }
            unregisterHotkey(.pickEnter); unregisterHotkey(.pickEsc); unregisterHotkey(.pickFull)
            self.picker = nil
            guard let r = r else { self.busy = false; sessionEnded(2, ["event": "cancelled"]); return }
            self.begin(r)
        }
        picker = p
        // Esc / Enter / F must work even if macOS refuses to make us the active app
        registerHotkey(.pickEnter, key: kVK_Return, mods: 0)
        registerHotkey(.pickEsc, key: kVK_Escape, mods: 0)
        registerHotkey(.pickFull, key: kVK_ANSI_F, mods: 0)
        p.show(preselect: opts.preselect)
    }

    func begin(_ region: CGRect) {
        cancelCountdown()
        stopNarrationPreview()
        busy = true
        emit(["event": "selected", "region": [region.minX, region.minY, region.width, region.height]])
        saveLastRegion(region)
        opts.lastRegion = region
        let r = Recorder(region: region)
        if opts.narrationScript != nil {
            if let feed = narrationCameraFeed { r.cameraFrameProvider = { [weak feed] in feed?.snapshot() } }
            r.onWillStop = { [weak self] restarting in if !restarting { self?.closeNarrationCamera() } }
            r.onEditNarration = { [weak self] in self?.showNarrationControls() }
            r.onPrompterChanged = { [weak self] enabled in self?.narrationSetup?.setPrompterEnabled(enabled) }
            r.onPrompterDisplayChanged = { [weak self] id in
                self?.narrationPrompterDisplayID = id
                self?.refreshNarrationDisplays()
            }
        }
        r.onRestart = { [weak self] in
            FileManager.default.createFile(atPath: opts.events ?? "/dev/null", contents: nil)
            self?.rec = nil
            self?.begin(region)
        }
        rec = r
        r.prepare { err in
            guard self.rec === r, !r.stopping else { return }
            if let err = err {
                sessionEnded(3, ["event": "error", "code": "setup", "message": err.localizedDescription])
                return
            }
            if opts.narrationScript != nil { self.narrationSetup?.hideForRegionSelection() }
            self.countdown(opts.countdown, over: region) {
                guard self.rec === r, !r.stopping else { return }
                r.start()
            }
        }
    }

    func countdown(_ n: Int, over region: CGRect, then: @escaping () -> Void) {
        guard n > 0 else { return then() }
        let v = CountdownView()
        let w = overlayWindow(toNS(region), view: v)
        w.ignoresMouseEvents = false
        w.orderFrontRegardless()
        countdownWin = w
        var left = n
        var fired = false
        v.n = left
        emit(["event": "countdown", "n": left])
        NSSound(named: "Pop")?.play()
        let go = {
            guard !fired else { return }
            fired = true                 // a short beat after hiding so the countdown never lands in frame 1
            self.countdownTimer?.invalidate()
            self.countdownTimer = nil
            v.onSkip = nil
            w.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { then() }
        }
        v.onSkip = go
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            left -= 1
            if left == 0 {
                go()
                return
            }
            v.n = left
            NSSound(named: "Pop")?.play()
            emit(["event": "countdown", "n": left])
        }
    }

    // MARK: menu-bar app

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        (countdownWin?.contentView as? CountdownView)?.onSkip = nil
        countdownWin?.orderOut(nil)
        countdownWin = nil
    }

    func startResident() {
        ensureDefaultWorkspace()
        registerHotkey(.toggleRec, key: kVK_ANSI_R, mods: optShift)
        registerHotkey(.menu, key: kVK_ANSI_B, mods: optShift)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.autosaveName = "blurt"
        item.isVisible = true
        statusItem = item
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshStatus() }
        sessionEnded = { [weak self] code, event in
            emit(event)
            self?.takeEnded(code, event)
        }
        // A second launch restores the current setup or opens a recording preview.
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.blurt.recorder.start"), object: nil, queue: .main) { [weak self] _ in
            self?.reopenResident()
        }
        if recordConfig()["welcomed"] == nil {
            setRecordConfig("welcomed", true)
            toast(L("口喷鸡已常驻 🐔  ⌥⇧R 开始 / 结束录制 · ⌥⇧B 打开菜单", "blurt is running 🐔  ⌥⇧R start / finish · ⌥⇧B menu"))
        }
        // `--process <session dir> [--agent claude|codex]`: process an existing recording (also handy for testing)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--process"), i + 1 < args.count {
            let agent = args.firstIndex(of: "--agent").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "claude"
            process(URL(fileURLWithPath: args[i + 1]), with: agent)
        } else if args.contains("--prompter") {
            mStandalonePrompter()
        } else if args.contains("--narrate") {
            mNarration()
        } else if !args.contains("--background") {
            openPreferredMode()
        }
    }

    /// The menu-bar icon can be hidden behind the notch on a crowded menu bar — ⌥⇧B shows the same menu at the pointer.
    func popMenu() {
        let m = NSMenu()
        menuNeedsUpdate(m)
        activateApp()
        m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenResident()
        return false
    }

    func reopenResident() {
        guard resident else { return }
        if standalonePrompterSetup != nil { standalonePrompterSetup?.show(); return }
        if narrationSetup != nil { showNarrationControls(); return }
        if !busy { openPreferredMode() }
    }

    func openPreferredMode() {
        if recordConfig()["launch_mode"] as? String == "prompter" { mStandalonePrompter() }
        else { mNarration() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeStandalonePrompter()
        closeNarrationCamera()
        stopNarrationPreview()
        closePreviewPrompter()
        narrationSetup?.cancel()   // Flush any pending draft edit before the app exits.
    }

    func startRecording(useLast: Bool, narrationScript: String? = nil) {
        guard !busy else { return }
        closeStandalonePrompter()
        opts.narrationScript = narrationScript
        opts.recordingDisplayID = nil
        opts.recordingDisplayFrame = nil
        opts.mic = true
        let dir = newSessionDir()
        opts.out = dir.appendingPathComponent("recording.mp4").path
        opts.events = dir.appendingPathComponent("events.jsonl").path
        opts.lastRegion = lastRegionFromConfig()
        opts.countdown = recordConfig()["countdown"] as? Int ?? 3
        lastSession = dir
        busy = true
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, err in
            DispatchQueue.main.async {
                if err != nil {
                    self.busy = false
                    opts.narrationScript = nil
                    try? FileManager.default.removeItem(at: dir)
                    self.permissionHelp()
                    return
                }
                if useLast, let r = opts.lastRegion { self.begin(r) } else { self.pick() }
            }
        }
    }

    func takeEnded(_ code: Int32, _ event: [String: Any]) {
        if opts.narrationScript != nil, let setup = narrationSetup {
            opts.narrationScript = setup.scriptValue
        }
        cancelCountdown()
        closeNarrationControls()
        rec?.cleanupChrome()
        rec = nil
        busy = false
        picker = nil
        let narrationScript = opts.narrationScript
        opts.narrationScript = nil
        guard let dir = lastSession else { return }
        if code != 0 {
            let video = dir.appendingPathComponent("recording.mp4")
            let size = (try? video.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let keepPartial = code != 2 && size > 0
            if !keepPartial { try? FileManager.default.removeItem(at: dir) }
            if event["event"] as? String == "error" {
                let recovery = keepPartial ? L("\n未完成的录制文件已保留：\n", "\nThe unfinished recording has been preserved at:\n") + dir.path : ""
                alert(L("录制失败", "Recording failed"), (event["message"] as? String ?? "") + recovery)
            }
            refreshStatus()
            return
        }
        let dur = event["duration"] as? Double ?? 0
        let meta: [String: Any] = [
            "engine": "native-app", "duration": dur, "video": "recording.mp4", "region": event["region"] ?? [],
            "started_at": ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -dur)),
            "author": recordConfig()["author"] as? String ?? NSFullUserName(),
            "workspace": currentWorkspace().path,
            "mode": narrationScript == nil ? "feedback" : "narration",
        ]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("meta.json"))
        }
        if let script = narrationScript {
            try? script.write(to: dir.appendingPathComponent("script.txt"), atomically: true, encoding: .utf8)
            saveNarration(dir, duration: dur)
            refreshStatus()
            return
        }
        let mode = recordConfig()["process"] as? String ?? "off"
        if mode == "off" {
            openHistory(dir)
            toast(L("已保存 \(fmtDur(dur)) 的录屏 · 在菜单里可以拷贝发给同事，或让 agent 处理", "Saved a \(fmtDur(dur)) recording · copy it from the menu or let your agent process it"))
        } else {
            process(dir, with: mode)
        }
        refreshStatus()
    }

    /// Keep the original take even if the presenter cancels exporting or the chosen disk is unavailable.
    func saveNarration(_ dir: URL, duration: Double) {
        busy = true
        defer { busy = false }
        let source = dir.appendingPathComponent("recording.mp4")
        let panel = NSSavePanel()
        panel.title = L("保存讲解视频", "Save narration video")
        panel.message = L("MP4 已自动保存在录制文件夹中，可另存到你选择的位置。", "Your MP4 is already saved in the recording folder. Save a copy wherever you prefer.")
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Blurt-\(dir.lastPathComponent).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        activateApp()
        guard panel.runModal() == .OK, let destination = panel.url else {
            NSWorkspace.shared.activateFileViewerSelecting([source])
            toast(L("MP4 已保存在录制文件夹 · \(fmtDur(duration))", "MP4 saved in the recording folder · \(fmtDur(duration))"))
            return
        }
        do {
            if source.standardizedFileURL != destination.standardizedFileURL {
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".blurt-export-\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: source, to: temporary)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
            }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            toast(L("讲解视频已保存为 MP4 · \(fmtDur(duration))", "Narration saved as MP4 · \(fmtDur(duration))"))
        } catch {
            alert(L("另存失败，原视频已保留", "Could not export; original video is safe"), error.localizedDescription + "\n" + source.path)
            NSWorkspace.shared.activateFileViewerSelecting([source])
        }
    }

    /// Hand the recording to a coding agent in the workspace, headless. It writes the outputs next to the recording
    /// and opens the review page itself.
    func process(_ dir: URL, with agent: String) {
        guard !processing.contains(dir.path) else { openHistory(dir); return }
        let ws = currentWorkspace()
        let name = agent == "codex" ? "Codex" : "Claude Code"
        guard let bin = findExecutable(agent == "codex" ? "codex" : "claude") else {
            alert(L("没找到 \(name)", "\(name) not found"),
                  L("口喷鸡要调用命令行里的 `\(agent == "codex" ? "codex" : "claude")`，但在你的 PATH 里没找到。装好 \(name) 命令行后再试，或者在菜单里改成「只保存」。",
                    "blurt calls the `\(agent == "codex" ? "codex" : "claude")` command line tool, which isn't on your PATH. Install the \(name) CLI, or switch to “Just save”."))
            return
        }
        let prompt = L("用 blurt skill 处理这段录屏：\(dir.path)\n这是口喷鸡 App 发起的无人值守后台运行：不要提问，也不要启动审核页（App 会在你结束后自己打开）；写好 items.json 后用两三句话总结。",
                       "Use the blurt skill to process this recording: \(dir.path)\nThis is an unattended background run started by the Blurt app: don't ask questions and don't start the review page (the app opens it when you finish); write items.json, then summarise in 2–3 sentences.")
        let cmd: String
        if agent == "codex" {
            // the skill needs uv's cache, the models in ~/.blurt and ffmpeg — outside the workspace sandbox
            cmd = "\(shq(bin)) exec --skip-git-repo-check --sandbox danger-full-access \(shq(prompt))"
        } else {
            cmd = "\(shq(bin)) -p \(shq(prompt)) --permission-mode acceptEdits --allowedTools Bash Read Write Edit Glob Grep"
        }
        let oldLog = dir.appendingPathComponent("agent.log")
        if FileManager.default.fileExists(atPath: oldLog.path) {
            try? FileManager.default.moveItem(at: oldLog, to: dir.appendingPathComponent("agent-\(Int(Date().timeIntervalSince1970)).log"))
        }
        writeProcessing(dir, status: "running", agent: agent)
        processing.append(dir.path)
        openHistory(dir)
        toast(L("\(name) 正在后台整理…", "\(name) is processing it in the background…"))
        shell(cmd, cwd: ws, log: dir.appendingPathComponent("agent.log")) { [weak self] status in
            guard let self = self else { return }
            self.processing.removeAll { $0 == dir.path }
            let ok = status == 0 && FileManager.default.fileExists(atPath: dir.appendingPathComponent("items.json").path)
            self.writeProcessing(dir, status: ok ? "completed" : "failed", agent: agent, code: status)
            if ok {
                self.toast(L("整理好了，请在处理记录页审核", "Ready to review in workflow history"))
            } else {
                self.toast(L("后台整理失败，详见录屏文件夹里的 agent.log", "Processing failed — see agent.log in the recording folder"))
            }
            self.refreshStatus()
        }
        refreshStatus()
    }

    func writeProcessing(_ dir: URL, status: String, agent: String, code: Int32? = nil) {
        var state = ((try? Data(contentsOf: dir.appendingPathComponent("processing.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        state["status"] = status
        state["agent"] = agent
        state["pid"] = ProcessInfo.processInfo.processIdentifier
        state["updated"] = Date().timeIntervalSince1970
        if status == "running" { state["started"] = Date().timeIntervalSince1970; state.removeValue(forKey: "exit_code") }
        if let c = code { state["exit_code"] = c }
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: dir.appendingPathComponent("processing.json"), options: .atomic)
        }
    }

    func openHistory(_ dir: URL? = nil) {
        guard let skill = readConfig()["skill_dir"] as? String, let uv = findExecutable("uv") else { return }
        let session = dir.map { " --session " + shq($0.path) } ?? ""
        shell("\(shq(uv)) run -q \(shq("\(skill)/scripts/history.py"))\(session)", cwd: currentWorkspace(),
              log: configURL.deletingLastPathComponent().appendingPathComponent("history-launch.log")) { _ in }
    }
    @objc func mHistory() { openHistory() }
    @objc func mSessionHistory(_ it: NSMenuItem) {
        if let p = it.representedObject as? String { openHistory(URL(fileURLWithPath: p)) }
    }

    /// Open the review page ourselves (the agent has exited; a page it started could die with it).
    @discardableResult
    func openReview(_ dir: URL) -> Bool {
        guard let skill = readConfig()["skill_dir"] as? String,
              FileManager.default.fileExists(atPath: "\(skill)/scripts/review.py"), let uv = findExecutable("uv") else { return false }
        shell("history_url=$(\(shq(uv)) run -q \(shq("\(skill)/scripts/history.py")) --no-open --session \(shq(dir.path))); \(shq(uv)) run -q \(shq("\(skill)/scripts/review.py")) \(shq(dir.path)) --history-url \"$history_url\"", cwd: dir,
              log: dir.appendingPathComponent("review.log")) { _ in }
        return true
    }

    func fmtDur(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    func refreshStatus() {
        guard let b = statusItem?.button else { return }
        if let r = rec, r.sessionStart.isValid {
            let s = Int(r.elapsed())
            b.image = nil
            b.attributedTitle = NSAttributedString(string: (r.isPaused ? "❚❚ " : "● ") + String(format: "%02d:%02d", s / 60, s % 60), attributes: [
                .foregroundColor: r.isPaused ? amber : NSColor.systemRed, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
        } else {
            b.image = menuIcon
            b.imagePosition = .imageLeft
            b.attributedTitle = NSAttributedString(string: processing.isEmpty ? "" : " …", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            b.toolTip = processing.isEmpty ? L("口喷鸡 · ⌥⇧R 开始录制 · ⌥⇧B 菜单", "blurt · ⌥⇧R record · ⌥⇧B menu")
                                           : L("口喷鸡 · 正在后台整理…", "blurt · processing in the background…")
        }
    }

    /// The chicken as a monochrome template image, like every other menu-bar icon (macOS tints it).
    lazy var menuIcon: NSImage? = {
        let img = Bundle.main.image(forResource: "MenuIconTemplate")
            ?? NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "blurt")
        if let i = img, i.size.height > 0 {
            i.size = NSSize(width: 18 * i.size.width / i.size.height, height: 18)
            i.isTemplate = true
        }
        return img
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector?, key: String = "", to m: NSMenu = menu, obj: Any? = nil, on: Bool = false) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self
            it.representedObject = obj
            it.state = on ? .on : .off
            m.addItem(it)
            return it
        }
        if let r = rec {
            if narrationSetup != nil {
                _ = add(L("录制设置与讲稿…", "Recording controls and script…"), #selector(mNarration))
                _ = add(r.prompterVisible ? L("关闭提词器", "Hide teleprompter") : L("显示提词器", "Show teleprompter"), #selector(mTogglePrompter))
                menu.addItem(.separator())
            }
            _ = add(L("完成录制", "Finish recording") + "   ⌥⇧S", #selector(mStop))
            _ = add((r.isPaused ? L("继续", "Resume") : L("暂停", "Pause")) + "   ⌥⇧P", #selector(mPause))
            _ = add(L("重新录制", "Restart"), #selector(mRestart))
            _ = add(L("放弃这次录制", "Discard"), #selector(mDiscard))
            return
        }
        if narrationSetup != nil {
            _ = add(L("录制讲解视频（带提词）…", "Record narration with teleprompter…"), #selector(mNarration))
            _ = add(L("单独使用提词器…", "Use teleprompter on its own…"), #selector(mStandalonePrompter))
            _ = add(L("取消本次讲解准备", "Cancel narration setup"), #selector(mCancelNarration))
            menu.addItem(.separator())
            _ = add(L("退出口喷鸡", "Quit blurt"), #selector(mQuit), key: "q")
            return
        }
        if busy { _ = add(L("正在准备或保存录制…", "Preparing or saving recording…"), nil); return }
        if let standalone = standalonePrompterSetup {
            _ = add(L("提词器设置…", "Teleprompter settings…"), #selector(mStandalonePrompter))
            _ = add(standalone.prompterEnabled ? L("隐藏提词器", "Hide teleprompter") : L("显示提词器", "Show teleprompter"), #selector(mToggleStandalonePrompter))
            _ = add(L("结束独立提词", "Close standalone teleprompter"), #selector(mCloseStandalonePrompter))
            menu.addItem(.separator())
        } else {
            _ = add(L("单独使用提词器…", "Use teleprompter on its own…"), #selector(mStandalonePrompter))
        }
        _ = add(L("录制讲解视频（带提词）…", "Record narration with teleprompter…"), #selector(mNarration))
        _ = add(L("开始录制", "Start recording") + "   ⌥⇧R", #selector(mStart))
        if lastRegionFromConfig() != nil { _ = add(L("录制上次的区域", "Record the last area"), #selector(mStartLast)) }
        menu.addItem(.separator())

        let ws = currentWorkspace()
        let wsItem = NSMenuItem(title: L("工作区：", "Workspace: ") + ws.lastPathComponent, action: nil, keyEquivalent: "")
        let wsMenu = NSMenu()
        _ = add(L("默认（~/Blurt）", "Default (~/Blurt)"), #selector(mWorkspace(_:)), to: wsMenu, obj: defaultWorkspace.path,
                on: ws.standardizedFileURL == defaultWorkspace.standardizedFileURL)
        for w in knownWorkspaces() where w.standardizedFileURL != defaultWorkspace.standardizedFileURL {
            _ = add(w.lastPathComponent + "  ·  " + (w.path as NSString).abbreviatingWithTildeInPath, #selector(mWorkspace(_:)), to: wsMenu,
                    obj: w.path, on: w.standardizedFileURL == ws.standardizedFileURL)
        }
        wsMenu.addItem(.separator())
        _ = add(L("绑定一个项目文件夹…", "Bind a project folder…"), #selector(mChooseWorkspace), to: wsMenu)
        _ = add(L("在访达中打开工作区", "Open workspace in Finder"), #selector(mOpenWorkspace), to: wsMenu)
        wsItem.submenu = wsMenu
        menu.addItem(wsItem)

        _ = add(L("处理记录与结果…", "Workflow history…"), #selector(mHistory))
        let recents = recentSessions()
        let rItem = NSMenuItem(title: L("最近的录制", "Recent recordings"), action: nil, keyEquivalent: "")
        let rMenu = NSMenu()
        if recents.isEmpty { _ = add(L("还没有录制", "No recordings yet"), nil, to: rMenu) }
        for d in recents {
            let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("meta.json")))) as? [String: Any]
            let dur = fmtDur(meta?["duration"] as? Double ?? 0)
            let done = FileManager.default.fileExists(atPath: d.appendingPathComponent("items.json").path)
            let name = d.lastPathComponent
            let pretty = name.count >= 15 ? "\(name.dropFirst(4).prefix(2))/\(name.dropFirst(6).prefix(2)) \(name.dropFirst(9).prefix(2)):\(name.dropFirst(11).prefix(2))" : name
            let it = NSMenuItem(title: "\(pretty)  ·  \(dur)\(done ? "  ✓" : "")\(processing.contains(d.path) ? "  …" : "")", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            _ = add(L("查看处理进度与结果", "View progress and results"), #selector(mSessionHistory(_:)), to: sub, obj: d.path)
            _ = add(L("拷贝视频（粘贴发给同事）", "Copy video (paste to share)"), #selector(mCopyVideo(_:)), to: sub, obj: d.path)
            _ = add(L("在访达中显示", "Show in Finder"), #selector(mReveal(_:)), to: sub, obj: d.path)
            _ = add(L("让 Claude Code 整理", "Process with Claude Code"), #selector(mProcessClaude(_:)), to: sub, obj: d.path)
            _ = add(L("让 Codex 整理", "Process with Codex"), #selector(mProcessCodex(_:)), to: sub, obj: d.path)
            it.submenu = sub
            rMenu.addItem(it)
        }
        rItem.submenu = rMenu
        menu.addItem(rItem)
        menu.addItem(.separator())

        let mode = recordConfig()["process"] as? String ?? "off"
        let pItem = NSMenuItem(title: L("录完自动整理", "After recording"), action: nil, keyEquivalent: "")
        let pMenu = NSMenu()
        _ = add(L("只保存（手动处理 / 发给别人）", "Just save (process later / share)"), #selector(mProcessMode(_:)), to: pMenu, obj: "off", on: mode == "off")
        _ = add(L("交给 Claude Code 后台整理", "Process with Claude Code"), #selector(mProcessMode(_:)), to: pMenu, obj: "claude", on: mode == "claude")
        _ = add(L("交给 Codex 后台整理", "Process with Codex"), #selector(mProcessMode(_:)), to: pMenu, obj: "codex", on: mode == "codex")
        pItem.submenu = pMenu
        menu.addItem(pItem)

        let cd = recordConfig()["countdown"] as? Int ?? 3
        let cItem = NSMenuItem(title: L("倒计时", "Countdown"), action: nil, keyEquivalent: "")
        let cMenu = NSMenu()
        for n in [0, 3, 5] { _ = add(n == 0 ? L("不倒计时", "None") : L("\(n) 秒", "\(n) s"), #selector(mCountdown(_:)), to: cMenu, obj: n, on: cd == n) }
        cItem.submenu = cMenu
        menu.addItem(cItem)
        if #available(macOS 13.0, *) {
            _ = add(L("开机时启动", "Open at login"), #selector(mLogin), on: SMAppService.mainApp.status == .enabled)
        }
        menu.addItem(.separator())
        _ = add(L("使用说明 / GitHub", "Help / GitHub"), #selector(mHelp))
        _ = add(L("退出口喷鸡", "Quit blurt"), #selector(mQuit), key: "q")
    }

    @objc func mStart() { startRecording(useLast: false) }

    @objc func mStandalonePrompter() {
        // Preparation can be left safely; an active take/countdown/save cannot.
        guard rec == nil else { return }
        if let setup = standalonePrompterSetup { setup.show(); return }
        if narrationSetup != nil {
            closeNarrationControls()
            busy = false
        }
        guard !busy else { return }
        setRecordConfig("launch_mode", "prompter")
        let setup = StandalonePrompterController()
        standalonePrompterSetup = setup
        let fallback = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        standalonePrompterDisplayID = TeleprompterPanel.preferredDisplayID(fallback: fallback.map(narrationDisplayID))
        setup.onChange = { [weak self] script, enabled in self?.updateStandalonePrompter(script: script, enabled: enabled) }
        setup.onSelectDisplay = { [weak self] id in self?.selectStandalonePrompterDisplay(id) }
        standaloneScreenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            // The panel has its own screen-change observer and may run after us.
            DispatchQueue.main.async { [weak self] in self?.refreshStandaloneDisplays() }
        }
        refreshStandaloneDisplays()
        setup.show()
        updateStandalonePrompter(script: setup.scriptValue, enabled: setup.prompterEnabled)
    }

    @objc func mToggleStandalonePrompter() {
        guard let setup = standalonePrompterSetup else { return }
        setup.setPrompterEnabled(!setup.prompterEnabled)
    }

    @objc func mCloseStandalonePrompter() { closeStandalonePrompter() }

    func availableNarrationDisplays() -> [NarrationDisplayOption] {
        let screens = NSScreen.screens
        return screens.enumerated().map { index, screen in
            let id = narrationDisplayID(screen)
            let name = CGDisplayIsBuiltin(id) != 0 ? L("内建显示屏", "Built-in display") : screen.localizedName
            let duplicate = screens.filter { $0.localizedName == screen.localizedName }.count > 1
            return NarrationDisplayOption(id: id, title: name + (duplicate ? " (\(index + 1))" : ""))
        }
    }

    func refreshStandaloneDisplays() {
        guard let setup = standalonePrompterSetup else { return }
        if let actual = standalonePrompter?.currentDisplayID {
            standalonePrompterDisplayID = actual
        } else if narrationScreen(standalonePrompterDisplayID) == nil {
            standalonePrompterDisplayID = TeleprompterPanel.preferredDisplayID(fallback: NSScreen.main.map(narrationDisplayID))
        }
        setup.setDisplayOptions(availableNarrationDisplays(), selected: standalonePrompterDisplayID)
    }

    func selectStandalonePrompterDisplay(_ id: CGDirectDisplayID) {
        guard standalonePrompterSetup != nil, narrationScreen(id) != nil else { return }
        standalonePrompterDisplayID = id
        TeleprompterPanel.rememberPreferredDisplay(id)
        standalonePrompter?.move(to: id)
        refreshStandaloneDisplays()
    }

    func updateStandalonePrompter(script: String, enabled: Bool) {
        guard standalonePrompterSetup != nil, rec == nil, narrationSetup == nil else { return }
        if !enabled {
            standalonePrompterTimer?.invalidate()
            standalonePrompterTimer = nil
            standalonePrompter?.update(paused: true)
            standalonePrompter?.orderOut(nil)
            return
        }
        if standalonePrompter == nil {
            guard let screen = narrationScreen(standalonePrompterDisplayID) ?? NSScreen.main ?? NSScreen.screens.first else { return }
            let panel = TeleprompterPanel(script: script)
            panel.setStandaloneMode(true)
            panel.onClose = { [weak self] in self?.standalonePrompterSetup?.setPrompterEnabled(false) }
            panel.onEdit = { [weak self] in self?.standalonePrompterSetup?.show() }
            panel.onDisplayChange = { [weak self] id in
                self?.standalonePrompterDisplayID = id
                self?.refreshStandaloneDisplays()
            }
            panel.place(near: toCG(screen.frame))
            standalonePrompter = panel
            refreshStandaloneDisplays()
        }
        standalonePrompter?.setScript(script)
        standalonePrompter?.orderFrontRegardless()
        standalonePrompter?.update(paused: false)
        if standalonePrompterTimer == nil {
            standalonePrompterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let panel = self?.standalonePrompter, panel.isVisible else { return }
                panel.update(paused: false)
            }
        }
    }

    func closeStandalonePrompter() {
        let setup = standalonePrompterSetup
        standalonePrompterSetup = nil
        setup?.onChange = nil
        setup?.onSelectDisplay = nil
        setup?.onHide = nil
        setup?.close() // Synchronously saves the last editor keystroke.
        standalonePrompterTimer?.invalidate()
        standalonePrompterTimer = nil
        if let observer = standaloneScreenObserver { NotificationCenter.default.removeObserver(observer) }
        standaloneScreenObserver = nil
        standalonePrompter?.onClose = nil
        standalonePrompter?.onEdit = nil
        standalonePrompter?.onDisplayChange = nil
        standalonePrompter?.stopScrolling()
        standalonePrompter?.orderOut(nil)
        standalonePrompter = nil
        standalonePrompterDisplayID = nil
    }

    @objc func mNarration() {
        if narrationSetup != nil { showNarrationControls(); return }
        guard !busy else { return }
        closeStandalonePrompter()
        setRecordConfig("launch_mode", "narration")
        busy = true
        let setup = NarrationSetupController()
        narrationSetup = setup
        setup.onUseStandalone = { [weak self] in self?.mStandalonePrompter() }
        setup.onCameraChange = { [weak self] enabled, deviceID, circular, mirrored in
            self?.updateNarrationCamera(enabled: enabled, deviceID: deviceID, circular: circular, mirrored: mirrored)
        }
        setup.onCameraSizeChange = { [weak self] fraction in
            self?.narrationCameraPanel?.setSizeFraction(fraction)
            self?.updateNarrationCameraLayout()
        }
        refreshNarrationCameraDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            narrationCameraDeviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshNarrationCameraDevices()
            })
        }
        setup.onCancel = { [weak self] in
            guard let self = self, self.rec == nil else { return }
            self.closeNarrationControls()
            self.busy = false
        }
        setup.onStart = { [weak self] region, script, enabled, microphone in
            self?.startNarrationRecording(region: region, script: script, enabled: enabled, microphone: microphone)
        }
        setup.onChooseRegion = { [weak self] in self?.chooseNarrationRegion() }
        setup.onSelectFullScreen = { [weak self] in self?.selectNarrationFullScreen() }
        setup.onSelectRecordingDisplay = { [weak self] id in self?.selectNarrationRecordingDisplay(id) }
        setup.onSelectPrompterDisplay = { [weak self] id in self?.selectNarrationPrompterDisplay(id) }
        setup.onRetryPreview = { [weak self] in
            guard let self = self, let region = self.narrationRegion else { return }
            self.startNarrationPreview(region)
        }
        setup.onPrompterChange = { [weak self] script, enabled in
            guard let self = self else { return }
            if let recorder = self.rec { recorder.updateNarration(script: script, enabled: enabled) }
            else { self.updatePreviewPrompter(script: script, enabled: enabled) }
        }
        setup.onFinish = { [weak self] in self?.command("stop") }
        setup.onHide = { [weak self] in self?.stopNarrationPreview() }
        narrationScreenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            self?.narrationScreensChanged()
        }
        setup.show()
        let screens = NSScreen.screens
        let underPointer = screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? screens.first
        guard let screen = underPointer else { setup.cancel(); return }
        let config = recordConfig()
        let savedUUID = config["narration_recording_display_uuid"] as? String
        let savedScreen = screens.first { savedUUID != nil && narrationDisplayUUID(narrationDisplayID($0)) == savedUUID }
        let candidate = savedScreen.flatMap { restoredNarrationRegion(on: $0) } ?? (savedUUID == nil ? lastRegionFromConfig() : nil)
        let validScreen = candidate.flatMap { r in screens.first { toCG($0.frame).contains(CGPoint(x: r.midX, y: r.midY)) } }
        let initial = candidate.flatMap { r in validScreen.map { r.intersection(toCG($0.frame)) } }
        let region = (initial != nil && initial!.width >= 8 && initial!.height >= 8) ? initial! : toCG((savedScreen ?? screen).frame)
        setNarrationRegion(region)
        narrationPrompterDisplayID = TeleprompterPanel.preferredDisplayID(fallback: narrationRecordingDisplayID)
        refreshNarrationDisplays()
        updatePreviewPrompter(script: setup.scriptValue, enabled: setup.prompterEnabled)
        updateNarrationCamera(enabled: setup.cameraEnabled, deviceID: setup.cameraDeviceID,
                              circular: setup.cameraCircular, mirrored: setup.cameraMirrored)
    }

    @objc func mCancelNarration() { narrationSetup?.cancel() }
    @objc func mTogglePrompter() { if let r = rec { r.setPrompterEnabled(!r.prompterVisible) } }

    func showNarrationControls() {
        guard let setup = narrationSetup else { return }
        if let picker = picker { picker.finish(false); return }
        setup.show()
        if let r = rec {
            setup.setRecordingMode(true)
            startNarrationPreview(r.region)
        } else if let region = narrationRegion {
            if narrationPreview == nil { startNarrationPreview(region) }
            updatePreviewPrompter(script: setup.scriptValue, enabled: setup.prompterEnabled)
        }
        refreshNarrationDisplays()
    }

    func restoredNarrationRegion(on screen: NSScreen) -> CGRect? {
        let display = toCG(screen.frame)
        guard let saved = recordConfig()["narration_region_on_display"] as? [String: Any],
              saved["display_uuid"] as? String == narrationDisplayUUID(narrationDisplayID(screen)) else { return display }
        if saved["full_screen"] as? Bool == true { return display }
        guard let x = saved["x"] as? Double, let y = saved["y"] as? Double,
              let width = saved["width"] as? Double, let height = saved["height"] as? Double,
              [x, y, width, height].allSatisfy({ $0.isFinite }) else { return display }
        let region = CGRect(x: display.minX + x, y: display.minY + y, width: width, height: height).intersection(display)
        return !region.isNull && region.width >= 8 && region.height >= 8 ? region : display
    }

    func refreshNarrationDisplays() {
        guard let setup = narrationSetup else { return }
        if let actual = rec?.teleprompter?.currentDisplayID ?? previewPrompter?.currentDisplayID {
            narrationPrompterDisplayID = actual
        } else if narrationScreen(narrationPrompterDisplayID) == nil {
            narrationPrompterDisplayID = TeleprompterPanel.preferredDisplayID(fallback: narrationRecordingDisplayID)
        }
        setup.setDisplayOptions(availableNarrationDisplays(), recording: narrationRecordingDisplayID, prompter: narrationPrompterDisplayID)
    }

    func selectNarrationRecordingDisplay(_ id: CGDirectDisplayID) {
        guard rec == nil, let screen = narrationScreen(id) else { return }
        setNarrationRegion(toCG(screen.frame))
        // Choosing what to capture must never move the user's prompter on another screen.
        refreshNarrationDisplays()
    }

    func selectNarrationPrompterDisplay(_ id: CGDirectDisplayID) {
        guard narrationScreen(id) != nil else { return }
        narrationPrompterDisplayID = id
        TeleprompterPanel.rememberPreferredDisplay(id)
        if let recorder = rec { recorder.teleprompter?.move(to: id) }
        else { previewPrompter?.move(to: id) }
        refreshNarrationDisplays()
    }

    func setNarrationRegion(_ requested: CGRect) {
        guard let screen = NSScreen.screens.first(where: { toCG($0.frame).contains(CGPoint(x: requested.midX, y: requested.midY)) }) else { return }
        let display = toCG(screen.frame)
        let region = requested.integral.intersection(display)
        guard !region.isNull, region.width >= 8, region.height >= 8 else { return }
        narrationRecordingDisplayID = narrationDisplayID(screen)
        narrationRegion = region
        narrationLocalRegion = region.offsetBy(dx: -display.minX, dy: -display.minY)
        narrationFullDisplay = region == display
        if let uuid = narrationDisplayUUID(narrationDisplayID(screen)), let local = narrationLocalRegion {
            setRecordConfig("narration_recording_display_uuid", uuid)
            setRecordConfig("narration_region_on_display", ["display_uuid": uuid, "x": local.minX, "y": local.minY,
                                                            "width": local.width, "height": local.height, "full_screen": region == display])
        }
        narrationSetup?.setRegion(region, label: "\(screen.localizedName) · \(Int(region.width)) × \(Int(region.height))")
        narrationCameraPanel?.setRegion(region)
        updateNarrationCameraLayout()
        refreshNarrationDisplays()
        startNarrationPreview(region)
    }

    func selectNarrationFullScreen() {
        guard rec == nil, let screen = narrationScreen(narrationRecordingDisplayID) else { return }
        setNarrationRegion(toCG(screen.frame))
    }

    func narrationScreensChanged() {
        guard let setup = narrationSetup else { return }
        if let picker = picker {
            picker.onDone = nil
            picker.finish(false)
            self.picker = nil
            unregisterHotkey(.pickEnter); unregisterHotkey(.pickEsc); unregisterHotkey(.pickFull)
            setup.show()
        }
        if let recorder = rec {
            refreshNarrationDisplays()
            guard let screen = narrationScreen(recorder.recordingDisplayID),
                  recorder.recordingDisplayFrame == toCG(screen.frame) else {
                stopNarrationPreview()
                cancelCountdown()
                toast(L("录制屏幕连接或布局已变化，正在结束本次录制。", "Recording display changed. Finishing the current take."))
                recorder.stop()
                return
            }
            return
        }
        stopNarrationPreview()
        guard let screen = narrationScreen(narrationRecordingDisplayID) else {
            narrationRegion = nil
            narrationCameraPanel?.orderOut(nil)
            setup.setRegion(.zero, label: L("录制屏幕已断开", "Recording display disconnected"))
            setup.setPreviewStatus(L("请选择一块已连接的录制屏幕。", "Choose a connected display to record."), error: true)
            refreshNarrationDisplays()
            return
        }
        let display = toCG(screen.frame)
        let region = narrationFullDisplay ? display : (narrationLocalRegion.map { $0.offsetBy(dx: display.minX, dy: display.minY).intersection(display) } ?? display)
        setNarrationRegion(!region.isNull && region.width >= 8 && region.height >= 8 ? region : display)
        updatePreviewPrompter(script: setup.scriptValue, enabled: setup.prompterEnabled)
    }

    func chooseNarrationRegion() {
        guard rec == nil, let setup = narrationSetup, picker == nil,
              narrationScreen(narrationRecordingDisplayID) != nil else { return }
        stopNarrationPreview()
        setup.hideForRegionSelection()
        previewPrompter?.orderOut(nil)
        narrationCameraPanel?.orderOut(nil)
        let p = PickerController()
        p.selectionOnly = true
        p.targetDisplayID = narrationRecordingDisplayID
        p.onDone = { [weak self] region in
            guard let self = self else { return }
            unregisterHotkey(.pickEnter); unregisterHotkey(.pickEsc); unregisterHotkey(.pickFull)
            self.picker = nil
            guard let setup = self.narrationSetup else { return }
            setup.show()
            if let region = region { self.setNarrationRegion(region) }
            else if let previous = self.narrationRegion { self.startNarrationPreview(previous) }
            self.updatePreviewPrompter(script: setup.scriptValue, enabled: setup.prompterEnabled)
            self.refreshNarrationCamera()
        }
        picker = p
        registerHotkey(.pickEnter, key: kVK_Return, mods: 0)
        registerHotkey(.pickEsc, key: kVK_Escape, mods: 0)
        registerHotkey(.pickFull, key: kVK_ANSI_F, mods: 0)
        opts.lastRegion = narrationRegion
        p.show(preselect: narrationRegion)
    }

    func startNarrationPreview(_ region: CGRect) {
        stopNarrationPreview()
        guard let setup = narrationSetup else { return }
        setup.setPreviewStatus(L("正在预览录制画面…", "Loading the recording preview…"), error: false)
        let preview = RecordingPreview()
        preview.displayID = narrationRecordingDisplayID
        preview.expectedDisplayFrame = rec?.recordingDisplayFrame ?? narrationScreen(narrationRecordingDisplayID).map { toCG($0.frame) }
        narrationPreview = preview
        preview.onImage = { [weak self, weak preview] image in
            guard let self = self, let preview = preview, self.narrationPreview === preview else { return }
            self.narrationScreenPreviewImage = image
            self.renderNarrationPreview()
        }
        preview.onError = { [weak self, weak preview] message in
            guard let self = self, let preview = preview, self.narrationPreview === preview else { return }
            self.narrationScreenPreviewImage = nil
            self.narrationSetup?.setPreviewStatus(message, error: true)
        }
        preview.start(region: region)
    }

    func stopNarrationPreview() {
        narrationPreview?.stop()
        narrationPreview = nil
        narrationScreenPreviewImage = nil
    }

    func updatePreviewPrompter(script: String, enabled: Bool) {
        guard rec == nil, let region = narrationRegion else { return }
        if enabled {
            if previewPrompter == nil {
                let panel = TeleprompterPanel(script: script)
                panel.onDisplayChange = { [weak self] id in
                    self?.narrationPrompterDisplayID = id
                    self?.refreshNarrationDisplays()
                }
                panel.setPreviewMode(true)
                panel.place(near: region)
                panel.onClose = { [weak self] in self?.narrationSetup?.setPrompterEnabled(false) }
                panel.onEdit = { [weak self] in self?.showNarrationControls() }
                previewPrompter = panel
                refreshNarrationDisplays()
            }
            previewPrompter?.setScript(script)
            previewPrompter?.orderFrontRegardless()
            if previewPrompterTimer == nil {
                previewPrompterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.previewPrompter?.update(paused: self.previewPrompter?.isVisible != true)
                }
            }
        } else { previewPrompter?.orderOut(nil) }
    }

    func closePreviewPrompter() {
        previewPrompterTimer?.invalidate()
        previewPrompterTimer = nil
        previewPrompter?.stopScrolling()
        previewPrompter?.orderOut(nil)
        previewPrompter = nil
    }

    func refreshNarrationCameraDevices() {
        guard let setup = narrationSetup else { return }
        setup.setCameraDevices(CameraCaptureController.devices().map { (id: $0.uniqueID, name: $0.localizedName) }, selected: setup.cameraDeviceID)
    }

    func updateNarrationCamera(enabled: Bool, deviceID: String?, circular: Bool, mirrored: Bool) {
        guard let setup = narrationSetup else { return }
        if narrationCameraFeed == nil { narrationCameraFeed = NarrationCameraFeed() }
        guard let feed = narrationCameraFeed else { return }
        if !enabled {
            narrationCameraGeneration += 1
            narrationCameraReady = false
            narrationCameraStarting = false
            feed.update(enabled: false, rect: .zero, circular: circular, mirrored: mirrored)
            feed.capture.stop()
            narrationCameraPanel?.orderOut(nil)
            narrationCameraPanel?.setImage(nil)
            narrationCameraTimer?.invalidate()
            narrationCameraTimer = nil
            setup.setCameraStatus(L("摄像头已关闭", "Camera off"), ready: false)
            renderNarrationPreview()
            return
        }
        guard let region = narrationRegion else { return }
        if narrationCameraPanel == nil {
            let panel = CameraOverlayPanel()
            panel.onClose = { [weak self] in self?.narrationSetup?.setCameraEnabled(false) }
            panel.onLayoutChange = { [weak self] _ in self?.updateNarrationCameraLayout() }
            panel.onSizeChange = { [weak self] fraction in self?.narrationSetup?.setCameraSize(fraction) }
            narrationCameraPanel = panel
        }
        narrationCameraPanel?.setRegion(region)
        narrationCameraPanel?.setShape(circular: circular)
        updateNarrationCameraLayout()
        if narrationCameraTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.refreshNarrationCamera() }
            RunLoop.main.add(timer, forMode: .common)
            narrationCameraTimer = timer
        }
        if narrationCameraDeviceID == deviceID && (narrationCameraStarting || narrationCameraReady) {
            refreshNarrationCamera()
            return
        }
        narrationCameraGeneration += 1
        let generation = narrationCameraGeneration
        narrationCameraDeviceID = deviceID
        narrationCameraReady = false
        narrationCameraStarting = true
        feed.update(enabled: false, rect: .zero, circular: circular, mirrored: mirrored)
        narrationCameraPanel?.setImage(nil)
        narrationCameraPanel?.orderOut(nil)
        setup.setCameraStatus(L("正在连接摄像头…", "Connecting to your camera…"), ready: false)
        feed.capture.onFailure = { [weak self, weak feed] message in
            guard let self = self, self.narrationCameraFeed === feed,
                  self.narrationCameraGeneration == generation else { return }
            self.narrationCameraReady = false
            self.narrationCameraStarting = false
            self.narrationCameraPanel?.setImage(nil)
            self.narrationCameraPanel?.orderOut(nil)
            self.updateNarrationCameraLayout()
            self.narrationSetup?.setCameraStatus(message, ready: false)
            if self.rec != nil { toast(message) }
        }
        feed.capture.start(deviceID: deviceID) { [weak self, weak feed] error in
            guard let self = self, self.narrationCameraFeed === feed,
                  self.narrationCameraGeneration == generation,
                  self.narrationSetup?.cameraEnabled == true else { return }
            self.narrationCameraStarting = false
            self.narrationCameraReady = error == nil
            if let error = error {
                self.narrationSetup?.setCameraStatus(error.localizedDescription, ready: false)
            } else {
                self.narrationSetup?.setCameraStatus(L("摄像头已就绪 · 将录入视频", "Camera ready · included in your video"), ready: true)
            }
            self.updateNarrationCameraLayout()
            self.refreshNarrationCamera()
        }
    }

    func updateNarrationCameraLayout() {
        guard let setup = narrationSetup else { return }
        narrationCameraFeed?.update(enabled: setup.cameraEnabled && narrationCameraReady,
                                    rect: narrationCameraPanel?.normalizedRect ?? .zero,
                                    circular: setup.cameraCircular, mirrored: setup.cameraMirrored)
    }

    func refreshNarrationCamera() {
        guard let setup = narrationSetup else { return }
        if setup.cameraEnabled, narrationCameraReady, let state = narrationCameraFeed?.snapshot(),
           let panel = narrationCameraPanel {
            var image = CIImage(cvPixelBuffer: state.pixelBuffer)
            if state.mirrored { image = image.oriented(.upMirrored) }
            panel.setImage(narrationCameraContext.createCGImage(image, from: image.extent))
            if picker == nil && narrationRegion != nil && !panel.isVisible { panel.orderFrontRegardless() }
        }
        renderNarrationPreview()
    }

    func renderNarrationPreview() {
        guard narrationPreview != nil, let base = narrationScreenPreviewImage else { return }
        guard let state = narrationCameraFeed?.snapshot(),
              let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            narrationSetup?.setPreview(base)
            return
        }
        let screen = CIImage(cgImage: cg)
        let composed = CameraCompositor.compositedImage(screen: screen, state: state)
        if let image = narrationCameraContext.createCGImage(composed, from: screen.extent) {
            narrationSetup?.setPreview(NSImage(cgImage: image, size: base.size))
        } else { narrationSetup?.setPreview(base) }
    }

    func closeNarrationCamera() {
        narrationCameraDeviceObservers.forEach { NotificationCenter.default.removeObserver($0) }
        narrationCameraDeviceObservers.removeAll()
        narrationCameraGeneration += 1
        narrationCameraTimer?.invalidate()
        narrationCameraTimer = nil
        narrationCameraFeed?.update(enabled: false, rect: .zero, circular: true, mirrored: true)
        narrationCameraFeed?.capture.onFailure = nil
        narrationCameraFeed?.capture.stop()
        narrationCameraFeed = nil
        narrationCameraPanel?.onClose = nil
        narrationCameraPanel?.onLayoutChange = nil
        narrationCameraPanel?.onSizeChange = nil
        narrationCameraPanel?.setImage(nil)
        narrationCameraPanel?.orderOut(nil)
        narrationCameraPanel = nil
        narrationCameraReady = false
        narrationCameraStarting = false
        narrationCameraDeviceID = nil
    }

    func closeNarrationControls() {
        if let observer = narrationScreenObserver { NotificationCenter.default.removeObserver(observer) }
        narrationScreenObserver = nil
        if narrationSetup != nil, let p = picker {
            p.onDone = nil
            p.finish(false)
            picker = nil
            unregisterHotkey(.pickEnter); unregisterHotkey(.pickEsc); unregisterHotkey(.pickFull)
        }
        stopNarrationPreview()
        closePreviewPrompter()
        closeNarrationCamera()
        let setup = narrationSetup
        narrationSetup = nil
        setup?.onCancel = nil
        setup?.onPrompterChange = nil
        setup?.onCameraChange = nil
        setup?.onCameraSizeChange = nil
        setup?.onHide = nil
        setup?.setRecordingMode(false)
        setup?.cancel()
        narrationRegion = nil
        narrationRecordingDisplayID = nil
        narrationPrompterDisplayID = nil
        narrationLocalRegion = nil
    }

    func startNarrationRecording(region: CGRect, script: String, enabled: Bool, microphone: Bool) {
        guard rec == nil, picker == nil, let setup = narrationSetup else { return }
        guard !setup.cameraEnabled || (narrationCameraReady && narrationCameraFeed?.snapshot() != nil) else { return }
        guard let screen = narrationScreen(narrationRecordingDisplayID),
              narrationRegion == region, toCG(screen.frame).contains(region) else {
            narrationScreensChanged()
            setup.show()
            return
        }
        stopNarrationPreview()
        closePreviewPrompter()
        opts.narrationScript = script
        opts.prompterEnabled = enabled
        opts.mic = microphone
        opts.recordingDisplayID = narrationDisplayID(screen)
        opts.recordingDisplayFrame = toCG(screen.frame)
        let dir = newSessionDir()
        opts.out = dir.appendingPathComponent("recording.mp4").path
        opts.events = dir.appendingPathComponent("events.jsonl").path
        opts.countdown = recordConfig()["countdown"] as? Int ?? 3
        lastSession = dir
        narrationSetup?.setRecordingMode(true)
        begin(region)
    }

    @objc func mStartLast() { startRecording(useLast: true) }
    @objc func mStop() { command("stop") }
    @objc func mPause() { command("toggle") }
    @objc func mRestart() { command("restart") }
    @objc func mDiscard() { command("discard") }
    @objc func mWorkspace(_ it: NSMenuItem) {
        guard let p = it.representedObject as? String else { return }
        setRecordConfig("workspace", p == defaultWorkspace.path ? nil : p)
    }
    @objc func mChooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("绑定", "Bind")
        panel.message = L("录屏会保存到这个项目的 .blurt/sessions 里，agent 可以直接结合代码处理", "Recordings go to <project>/.blurt/sessions so your agent can process them with the code")
        activateApp()
        guard panel.runModal() == .OK, let u = panel.url else { return }
        var list = recordConfig()["workspaces"] as? [String] ?? []
        if !list.contains(u.path) { list.insert(u.path, at: 0) }
        setRecordConfig("workspaces", Array(list.prefix(8)))
        setRecordConfig("workspace", u.path)
    }
    @objc func mOpenWorkspace() { NSWorkspace.shared.open(currentWorkspace()) }
    @objc func mReveal(_ it: NSMenuItem) {
        guard let p = it.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p).appendingPathComponent("recording.mp4")])
    }
    @objc func mCopyVideo(_ it: NSMenuItem) {
        guard let p = it.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: p).appendingPathComponent("recording.mp4") as NSURL])
        toast(L("已拷贝，去飞书 / 微信 / Slack 里直接粘贴", "Copied — paste it into Slack, Feishu, email…"))
    }
    @objc func mProcessClaude(_ it: NSMenuItem) { if let p = it.representedObject as? String { process(URL(fileURLWithPath: p), with: "claude") } }
    @objc func mProcessCodex(_ it: NSMenuItem) { if let p = it.representedObject as? String { process(URL(fileURLWithPath: p), with: "codex") } }
    @objc func mProcessMode(_ it: NSMenuItem) { setRecordConfig("process", it.representedObject as? String) }
    @objc func mCountdown(_ it: NSMenuItem) { setRecordConfig("countdown", it.representedObject as? Int) }
    @objc func mLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { alert(L("设置失败", "Couldn't change it"), error.localizedDescription) }
    }
    @objc func mHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/AGIHunt/blurt")!) }
    @objc func mQuit() { NSApp.terminate(nil) }

    // tiny, non-blocking toast under the menu bar (no notification permission needed)
    var toastWin: NSWindow?
    func toast(_ text: String) {
        toastWin?.orderOut(nil)
        let f = NSFont.systemFont(ofSize: 13, weight: .medium)
        let w = NSAttributedString(string: text, attributes: [.font: f]).size().width + 36
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let frame = NSRect(x: screen.maxX - w - 16, y: screen.maxY - 56, width: w, height: 40)
        let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        v.material = .hudWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        let label = NSTextField(labelWithString: text)
        label.font = f
        label.textColor = .white
        label.frame = NSRect(x: 18, y: 11, width: w - 30, height: 18)
        v.addSubview(label)
        let win = overlayWindow(frame, view: v)
        win.level = .statusBar
        win.orderFrontRegardless()
        toastWin = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self, weak win] in
            if self?.toastWin === win { win?.orderOut(nil) }
        }
    }

    func permissionHelp() {
        let a = NSAlert()
        a.messageText = L("需要「录屏」权限", "Screen Recording permission needed")
        a.informativeText = L("""
            在 系统设置 → 隐私与安全性 → 录屏与系统录音 里打开「Blurt」，然后退出并重新打开口喷鸡（macOS 只在启动时读取权限）。

            如果列表里已经是打开的：选中「Blurt」点下面的「−」删掉，再重新打开口喷鸡授权一次（旧版本留下的授权对新版本无效）。
            """, """
            Turn on “Blurt” in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen blurt \
            (macOS reads the permission at launch).

            Already on? Select “Blurt”, remove it with “−”, reopen blurt and allow it again (a grant from an older build doesn't carry over).
            """)
        a.addButton(withTitle: L("打开系统设置", "Open System Settings"))
        a.addButton(withTitle: L("退出口喷鸡", "Quit blurt"))
        a.addButton(withTitle: L("稍后", "Later"))
        activateApp()
        switch a.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default: break
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        activateApp()
        a.runModal()
    }
}

// A second copy of the app (double-click while it's running) just asks the running one to start recording.
// Only for plain launches — `--process`, `--background` etc. are explicit instructions for this process.
let plainLaunch = !CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") && !$0.hasPrefix("--lang") }
if opts.standalone, plainLaunch, ProcessInfo.processInfo.environment["BLURT_ALLOW_MULTI"] == nil,
   NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.blurt.recorder")
       .contains(where: { $0.processIdentifier != getpid() }) {
    DistributedNotificationCenter.default().postNotificationName(.init("dev.blurt.recorder.start"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
