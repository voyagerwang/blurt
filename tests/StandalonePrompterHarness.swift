// App callback regression checks; capture, microphone, windows, and config are isolated by Python.
struct StandaloneTestFailure: Error { let message: String }
var checks: [String] = []
var entryPreviewStarts = 0
var entryPreviewRegions: [CGRect] = []
var entryPickerShows = 0
var entryPrepareCalls = 0
var entrySyntheticRecorderStarts = 0
var entrySyntheticRecorderStops = 0
var entryPendingPrepareCompletion: ((Error?) -> Void)?
var entrySavedNarrationScript: String?
var entryLegacyStarts = 0
var multipleDisplaysTested = false

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw StandaloneTestFailure(message: message) }
    checks.append(message)
}
func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
func shownWindow(_ title: String) throws -> NSWindow {
    guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else {
        throw StandaloneTestFailure(message: "Missing visible window: \(title)")
    }
    return window
}
func editorIn(_ window: NSWindow) throws -> NSTextView {
    guard let content = window.contentView, let editor = views(content).compactMap({ $0 as? NSTextView }).first else {
        throw StandaloneTestFailure(message: "Missing script editor")
    }
    return editor
}
func panelScript(_ panel: TeleprompterPanel) -> String {
    panel.contentView.map { views($0).compactMap({ $0 as? NSTextView }).first?.string ?? "" } ?? ""
}
func button(_ title: String, in window: NSWindow) throws -> NSButton {
    guard let content = window.contentView, let button = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
        throw StandaloneTestFailure(message: "Missing button: \(title)")
    }
    return button
}
func menu(_ app: App) -> NSMenu { let menu = NSMenu(); app.menuNeedsUpdate(menu); menu.update(); return menu }
func dispatch(_ name: String, app: App) throws {
    let current = menu(app)
    guard let item = current.items.first(where: { $0.action.map(NSStringFromSelector) == name }), let action = item.action, item.isEnabled else {
        throw StandaloneTestFailure(message: "Missing enabled menu action: \(name)")
    }
    try check(NSApp.sendAction(action, to: item.target, from: item), "dispatch menu action \(name)")
}
func edit(_ value: String, editor: NSTextView, setup: StandalonePrompterController) {
    editor.string = value
    setup.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
}
func drain(_ seconds: Double = 0.4) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
func noCapture(_ app: App, _ message: String, previewCount: Int) throws {
    try check(app.rec == nil && app.narrationPreview == nil && app.lastSession == nil && entryPreviewStarts == previewCount && entryPrepareCalls == 0 && entrySyntheticRecorderStarts == 0, message)
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
opts.standalone = true
opts.lang = "zh"
opts.out = "unchanged-output-sentinel"
opts.events = "unchanged-events-sentinel"
opts.mic = false
let app = App()
setRecordConfig("narration_script", "standalone seed")
setRecordConfig("narration_prompter_enabled", false)
setRecordConfig("standalone_prompter_enabled", true)
setRecordConfig("narration_recording_display_uuid", "recording-display-sentinel")
setRecordConfig("countdown", 0)
let initialOpts = String(reflecting: opts)

do {
    try check(!NSScreen.screens.isEmpty, "display metadata available without capture")
    try dispatch("mStandalonePrompter", app: app)
    guard let setup = app.standalonePrompterSetup, let panel = app.standalonePrompter else { throw StandaloneTestFailure(message: "Standalone controller/panel missing") }
    let window = try shownWindow("提词器设置 · Blurt")
    let editor = try editorIn(window)
    try noCapture(app, "standalone entry creates no preview, recorder or session", previewCount: 0)
    try check(app.narrationSetup == nil && app.picker == nil && !app.busy, "standalone entry does not own recording-preparation state")
    try check(String(reflecting: opts) == initialOpts, "standalone entry leaves all recording options unchanged")
    try check(editor.string == "standalone seed" && panelScript(panel) == editor.string, "settings and panel restore shared saved draft")
    try check(panel.isVisible && app.standalonePrompterTimer?.isValid == true && app.standaloneScreenObserver != nil, "enabled standalone owns one panel timer and display observer")
    try check(recordConfig()["launch_mode"] as? String == "prompter", "standalone becomes preferred reopen mode")

    edit("last edit immediately before hiding", editor: editor, setup: setup)
    try button("完成设置", in: window).performClick(nil)
    try check(!window.isVisible && panel.isVisible, "Done hides settings while prompter stays visible")
    try check(recordConfig()["narration_script"] as? String == editor.string && panelScript(panel) == editor.string, "Done flushes undebounced draft to storage and panel")
    let firstTimer = app.standalonePrompterTimer
    app.reopenResident()
    try check(window.isVisible && app.standalonePrompterSetup === setup && app.standalonePrompter === panel && app.standalonePrompterTimer === firstTimer, "reopen restores same settings panel and timer")
    window.orderOut(nil)
    _ = app.applicationShouldHandleReopen(application, hasVisibleWindows: false)
    try check(window.isVisible && entryPreviewStarts == 0, "application reopen restores standalone without preview")
    setup.hide()
    panel.onEdit?()
    try check(window.isVisible && panel.isVisible, "floating edit action restores standalone settings")

    panel.onClose?()
    try check(!setup.prompterEnabled && !panel.isVisible && app.standalonePrompterTimer == nil && firstTimer?.isValid == false, "closing prompter hides retained panel and stops timer")
    try check(recordConfig()["standalone_prompter_enabled"] as? Bool == false && recordConfig()["narration_prompter_enabled"] as? Bool == false, "standalone close does not change narration visibility preference")
    edit("edited while prompter is hidden", editor: editor, setup: setup)
    setup.hide()
    try check(!panel.isVisible && app.standalonePrompterTimer == nil, "saving hidden-panel draft cannot reopen prompter")
    try dispatch("mToggleStandalonePrompter", app: app)
    try check(setup.prompterEnabled && panel.isVisible && app.standalonePrompter === panel && panelScript(panel) == "edited while prompter is hidden", "toggle restores same panel with newest draft")
    try check(recordConfig()["narration_prompter_enabled"] as? Bool == false, "independent toggle never enables recording prompter")

    let firstScreen = NSScreen.screens.first!
    let otherScreen = NSScreen.screens.dropFirst().first ?? firstScreen
    multipleDisplaysTested = NSScreen.screens.count > 1
    let previewBeforeDisplay = entryPreviewStarts
    let beforeDisplayOpts = String(reflecting: opts)
    setup.setPrompterEnabled(false)
    app.selectStandalonePrompterDisplay(narrationDisplayID(otherScreen))
    try check(!panel.isVisible && !setup.prompterEnabled && app.standalonePrompterTimer == nil, "display selection while hidden preserves disabled state")
    setup.setPrompterEnabled(true)
    try check(panel.currentDisplayID == narrationDisplayID(otherScreen) && otherScreen.visibleFrame.contains(panel.frame), "standalone display selection moves whole panel to selected screen")
    try check(entryPreviewStarts == previewBeforeDisplay && String(reflecting: opts) == beforeDisplayOpts && app.narrationRecordingDisplayID == nil && recordConfig()["narration_recording_display_uuid"] as? String == "recording-display-sentinel", "prompter display changes leave recording target and options untouched")

    // Closing then changing modes must cancel pending debounce and preserve latest text.
    edit("fresh standalone text before mode switch", editor: editor, setup: setup)
    let lateStandaloneChange = setup.onChange
    let closedTimer = app.standalonePrompterTimer
    app.mNarration()
    guard let narration = app.narrationSetup else { throw StandaloneTestFailure(message: "Narration switch missing setup") }
    let narrationWindow = try shownWindow("录制准备 · Blurt")
    let narrationEditor = try editorIn(narrationWindow)
    try check(app.standalonePrompterSetup == nil && app.standalonePrompter == nil && app.standalonePrompterTimer == nil && app.standaloneScreenObserver == nil && closedTimer?.isValid == false && !window.isVisible, "switch to narration closes standalone settings timer panel and observer")
    try check(narrationEditor.string == "fresh standalone text before mode switch", "narration receives latest undebounced shared script")
    lateStandaloneChange?("stale standalone callback", true)
    drain()
    try check(app.standalonePrompter == nil && narration.scriptValue == "fresh standalone text before mode switch", "late standalone change cannot reopen old mode or overwrite current script")
    try check(entryPreviewStarts == 1 && app.rec == nil && app.lastSession == nil, "switch starts only isolated preview until explicit Record")

    narrationEditor.string = "fresh narration text before standalone"
    narration.textDidChange(Notification(name: NSText.didChangeNotification, object: narrationEditor))
    let oldPreview = app.narrationPreview
    let latePreviewImage = oldPreview?.onImage
    let lateNarrationChange = narration.onPrompterChange
    app.chooseNarrationRegion()
    let oldPicker = app.picker
    let latePickerCallback = oldPicker?.onDone
    try check(oldPicker != nil, "selection-only picker prepared before standalone switch")
    app.mStandalonePrompter()
    guard let switched = app.standalonePrompterSetup, let switchedPanel = app.standalonePrompter else { throw StandaloneTestFailure(message: "Standalone switch failed from busy preparation") }
    let switchedWindow = try shownWindow("提词器设置 · Blurt")
    try check(switched.scriptValue == "fresh narration text before standalone", "standalone receives latest narration draft despite busy preparation")
    try check(app.narrationSetup == nil && app.narrationPreview == nil && app.previewPrompter == nil && app.previewPrompterTimer == nil && app.narrationScreenObserver == nil && app.picker == nil && !app.busy, "switch from area selection releases every narration resource")
    oldPicker?.finish(true)
    latePickerCallback?(toCG(firstScreen.frame))
    latePreviewImage?(NSImage(size: NSSize(width: 10, height: 10)))
    lateNarrationChange?("stale narration callback", true)
    drain()
    try check(app.narrationSetup == nil && app.narrationPreview == nil && app.rec == nil && app.standalonePrompter === switchedPanel && switched.scriptValue == "fresh narration text before standalone", "late picker preview and narration callbacks cannot resurrect prior mode")

    // Busy/recorder guards must be checked before mutating launch preference or draft.
    app.closeStandalonePrompter()
    app.busy = true
    let busyMode = recordConfig()["launch_mode"] as? String
    app.mStandalonePrompter()
    try check(app.standalonePrompterSetup == nil && app.busy && recordConfig()["launch_mode"] as? String == busyMode, "unrelated busy/save state refuses standalone without side effects")
    app.busy = false
    app.mNarration()
    let protectedNarration = app.narrationSetup
    app.rec = Recorder(region: toCG(firstScreen.frame))
    let protectedRecorder = app.rec
    app.mStandalonePrompter()
    try check(app.rec === protectedRecorder && app.narrationSetup === protectedNarration && app.standalonePrompterSetup == nil, "active recorder or countdown refuses standalone without dismantling recording controls")
    app.rec = nil
    app.narrationSetup?.cancel()

    // All legacy entry points must reuse production standalone cleanup before capture boundary.
    for entry in ["ordinary", "last-region", "record-shortcut"] {
        app.mStandalonePrompter()
        let setup = app.standalonePrompterSetup!
        let window = try shownWindow("提词器设置 · Blurt")
        let editor = try editorIn(window)
        edit("latest before \(entry)", editor: editor, setup: setup)
        let timer = app.standalonePrompterTimer
        if entry == "ordinary" { app.mStart() }
        else if entry == "last-region" { app.mStartLast() }
        else { app.hotkey(.toggleRec) }
        try check(app.standalonePrompterSetup == nil && app.standalonePrompter == nil && app.standaloneScreenObserver == nil && app.standalonePrompterTimer == nil && timer?.isValid != true && !window.isVisible, "\(entry) flushes and removes standalone before isolated recording boundary")
        try check(recordConfig()["narration_script"] as? String == "latest before \(entry)", "\(entry) keeps final pending keystroke")
    }
    try check(entryLegacyStarts == 3, "all three legacy starts reached audited no-capture boundary")

    app.mStandalonePrompter()
    let endSetup = app.standalonePrompterSetup!
    let endWindow = try shownWindow("提词器设置 · Blurt")
    let endEditor = try editorIn(endWindow)
    edit("termination must retain newest character", editor: endEditor, setup: endSetup)
    let endTimer = app.standalonePrompterTimer
    let endPanel = app.standalonePrompter!
    app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    try check(recordConfig()["narration_script"] as? String == "termination must retain newest character", "application termination flushes pending standalone edit")
    try check(app.standalonePrompterSetup == nil && app.standalonePrompter == nil && app.standalonePrompterTimer == nil && app.standaloneScreenObserver == nil && !endWindow.isVisible && !endPanel.isVisible && endTimer?.isValid != true, "termination removes editor panel timer and display observer")
    drain()
    try check(app.standalonePrompter == nil && app.narrationSetup == nil, "cancelled debounces and queued display refresh do not resurrect terminated modes")
    let countBeforePreferred = entryPreviewStarts
    app.reopenResident()
    try check(app.standalonePrompterSetup?.scriptValue == "termination must retain newest character" && app.narrationSetup == nil && entryPreviewStarts == countBeforePreferred, "fresh preferred-mode reopen restores standalone and draft without capture")
    app.closeStandalonePrompter()
    setRecordConfig("launch_mode", "narration")
    app.reopenResident()
    try check(app.narrationSetup != nil && app.standalonePrompterSetup == nil && entryPreviewStarts == countBeforePreferred + 1, "narration preference still opens recording preparation")
    app.narrationSetup?.cancel()
    try check(entryPrepareCalls == 0 && entrySyntheticRecorderStarts == 0 && app.lastSession == nil, "entire lifecycle suite creates no recorder take or session directory")
    emit(["test": "standalone_prompter_lifecycle", "passed": true, "checks": checks, "synthetic_preview_starts": entryPreviewStarts, "legacy_boundaries": entryLegacyStarts, "multiple_displays_tested": multipleDisplaysTested])
    exit(0)
} catch {
    app.rec = nil
    app.closeStandalonePrompter()
    app.closeNarrationControls()
    emit(["test": "standalone_prompter_lifecycle", "passed": false, "error": String(describing: error), "checks": checks])
    exit(1)
}
