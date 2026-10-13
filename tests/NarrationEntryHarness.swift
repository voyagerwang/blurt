// AppKit integration harness appended after the current production classes.
// Preview/capture doubles are inserted by test_narration_entry.py; App callbacks
// and setup/recorder/teleprompter interaction are the real production methods.
struct EntryTestFailure: Error { let message: String }
var entryChecks: [String] = []
var entryPreviewStarts = 0
var entryPreviewRegions: [CGRect] = []
var entryPickerShows = 0
var entryPrepareCalls = 0
var entrySyntheticRecorderStarts = 0
var entrySyntheticRecorderStops = 0
var entryPendingPrepareCompletion: ((Error?) -> Void)?
var entrySavedNarrationScript: String?
var entryMultiDisplayRan = false
var entryMultiDisplaySkipReason: String?

func checkEntry(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() == false { throw EntryTestFailure(message: message) }
    entryChecks.append(message)
}
func descendantsEntry(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendantsEntry) }
func entryMenu(_ delegate: App) -> NSMenu {
    let menu = NSMenu()
    delegate.menuNeedsUpdate(menu)
    menu.update()
    return menu
}
func dispatchEntry(_ name: String, from menu: NSMenu) throws {
    guard let item = menu.items.first(where: { $0.action.map(NSStringFromSelector) == name }),
          let action = item.action, item.isEnabled else {
        throw EntryTestFailure(message: "Missing/enabled action: \(name); items: \(menu.items.map(\.title))")
    }
    try checkEntry(NSApp.sendAction(action, to: item.target, from: item), "menu dispatch \(name)")
}
func currentEntryWindow() throws -> NSWindow {
    guard let window = NSApp.windows.first(where: {
        ($0.title == "录制准备 · Blurt" || $0.title == "录制中 · Blurt") && $0.isVisible
    }) else { throw EntryTestFailure(message: "Visible narration preparation window was not created") }
    return window
}
func entryButton(_ title: String, in window: NSWindow) throws -> NSButton {
    guard let content = window.contentView,
          let button = descendantsEntry(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title })
    else { throw EntryTestFailure(message: "Missing button: \(title)") }
    return button
}
func entryEditor(_ window: NSWindow) throws -> NSTextView {
    guard let content = window.contentView,
          let editor = descendantsEntry(content).compactMap({ $0 as? NSTextView }).first
    else { throw EntryTestFailure(message: "Missing script editor") }
    return editor
}
func editEntry(_ value: String, editor: NSTextView, setup: NarrationSetupController) {
    editor.string = value
    setup.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
}
func closeEntry(_ window: NSWindow) throws {
    guard let button = descendantsEntry(window.contentView!).compactMap({ $0 as? IconButton }).first(where: { $0.symbol == "xmark" })
    else { throw EntryTestFailure(message: "Missing borderless-window close control") }
    button.performClick(nil)
}
func syntheticEntryFrame() -> NSImage {
    NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
        NSColor(calibratedRed: 0.14, green: 0.2, blue: 0.3, alpha: 1).setFill()
        rect.fill()
        let text = NSAttributedString(string: "SYNTHETIC PREVIEW", attributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor.white])
        text.draw(at: NSPoint(x: 36, y: 165))
        return true
    }
}
func entryArrow(_ code: Int, shift: Bool, to view: PickerView) throws {
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                      modifierFlags: shift ? .shift : [], timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: UInt16(code)) else {
        throw EntryTestFailure(message: "Cannot construct isolated arrow-key event")
    }
    // Invoke only this offscreen view; never post keys to the user's application.
    view.keyDown(with: event)
}

let entryApp = NSApplication.shared
entryApp.setActivationPolicy(.prohibited)
opts.standalone = true
opts.lang = "zh"
let entryDelegate = App()
setRecordConfig("narration_script", "isolated draft seed")
setRecordConfig("narration_prompter_enabled", true)
setRecordConfig("countdown", 0)

do {
    try checkEntry(!NSScreen.screens.isEmpty, "display metadata available without screen capture")
    try dispatchEntry("mNarration", from: entryMenu(entryDelegate))
    guard let setup = entryDelegate.narrationSetup else { throw EntryTestFailure(message: "No setup controller") }
    let window = try currentEntryWindow()
    let editor = try entryEditor(window)
    let start = try entryButton("开始录制", in: window)
    try checkEntry(entryDelegate.busy && entryDelegate.picker == nil && entryDelegate.rec == nil,
                   "narration entry opens preparation preview, not picker or recorder")
    try checkEntry(entryPreviewStarts == 1 && entryPrepareCalls == 0, "entry requests preview only")
    try checkEntry(editor.string == "isolated draft seed", "opening restores isolated draft")
    try checkEntry(window.collectionBehavior.contains(.moveToActiveSpace), "setup requests current Space")
    try checkEntry(!start.isEnabled, "start disabled until a valid preview arrives")
    _ = NSApp.sendAction(start.action!, to: start.target, from: start)
    try checkEntry(entryPrepareCalls == 0, "start callback rejects missing preview even if directly invoked")
    entryDelegate.narrationPreview?.onImage?(syntheticEntryFrame())
    try checkEntry(start.isEnabled, "valid synthetic preview enables explicit start")

    editEntry("unsaved edited draft stays in same editor", editor: editor, setup: setup)
    window.orderOut(nil)
    let preparedMenu = entryMenu(entryDelegate)
    try checkEntry(preparedMenu.items.contains(where: { $0.title == "录制讲解视频（带提词）…" && $0.isEnabled }),
                   "same narration entry remains available while preparation is busy")
    try dispatchEntry("mNarration", from: preparedMenu)
    try checkEntry(entryDelegate.narrationSetup === setup && window.isVisible, "menu restores same hidden setup")
    try checkEntry(editor.string == "unsaved edited draft stays in same editor", "menu recovery preserves pending editor draft")
    window.orderOut(nil)
    _ = entryDelegate.applicationShouldHandleReopen(entryApp, hasVisibleWindows: false)
    try checkEntry(entryDelegate.narrationSetup === setup && window.isVisible, "application reopen restores existing preparation")
    window.orderOut(nil)
    entryDelegate.reopenResident()
    try checkEntry(entryDelegate.narrationSetup === setup && window.isVisible, "resident reopen restores existing preparation")

    let oldPreview = entryDelegate.narrationPreview
    try entryButton("选择区域", in: window).performClick(nil)
    guard let picker = entryDelegate.picker else { throw EntryTestFailure(message: "No selection-only picker") }
    try checkEntry(picker.selectionOnly && entryPickerShows == 1, "region action opens selection-only picker")
    try checkEntry(!window.isVisible && entryDelegate.previewPrompter?.isVisible != true,
                   "preparation and prompter remain hidden during region selection after draft flush")
    try checkEntry(entryDelegate.narrationPreview == nil && oldPreview?.onImage == nil, "selection stops and detaches prior preview")
    let pickerDisplayFrame = toCG((narrationScreen(picker.targetDisplayID) ?? NSScreen.screens.first!).frame)
    let desired = CGRect(x: pickerDisplayFrame.minX + 20, y: pickerDisplayFrame.minY + 20, width: 640, height: 360)
    picker.selection = toNS(desired)
    picker.finish(true)
    try checkEntry(entryDelegate.picker == nil && entryDelegate.narrationSetup === setup && window.isVisible,
                   "confirming region returns to same preparation interface")
    try checkEntry(entryDelegate.narrationRegion == desired && entryPrepareCalls == 0 && entryDelegate.rec == nil,
                   "region confirmation updates preview without starting recording")
    try checkEntry(!start.isEnabled, "new region invalidates old preview readiness")
    entryDelegate.narrationPreview?.onImage?(syntheticEntryFrame())
    try checkEntry(start.isEnabled, "new region becomes ready only after its own preview")
    entryDelegate.narrationPreview?.onError?("Synthetic preview unavailable")
    try checkEntry(!start.isEnabled, "preview error disables start")
    let previewCountBeforeRetry = entryPreviewStarts
    try entryButton("重试", in: window).performClick(nil)
    try checkEntry(entryPreviewStarts == previewCountBeforeRetry + 1 && !start.isEnabled, "retry starts a new gated preview")
    entryDelegate.narrationPreview?.onImage?(syntheticEntryFrame())
    setup.setRegion(.zero, label: "invalid synthetic region")
    setup.setPreview(syntheticEntryFrame())
    try checkEntry(!start.isEnabled, "invalid region cannot be recorded even with an image")
    entryDelegate.setNarrationRegion(desired)
    entryDelegate.narrationPreview?.onImage?(syntheticEntryFrame())

    try entryButton("选择区域", in: window).performClick(nil)
    try dispatchEntry("mNarration", from: entryMenu(entryDelegate))
    try checkEntry(entryDelegate.picker == nil && entryDelegate.narrationRegion == desired && window.isVisible,
                   "menu recovery while selecting cancels selection and restores previous region")
    editEntry("cancel while selecting preserves this draft", editor: editor, setup: setup)
    try entryButton("选择区域", in: window).performClick(nil)
    let cancelledPicker = entryDelegate.picker
    try dispatchEntry("mCancelNarration", from: entryMenu(entryDelegate))
    try checkEntry(!entryDelegate.busy && entryDelegate.narrationSetup == nil && entryDelegate.picker == nil,
                   "cancel from selection menu clears setup, picker, and busy state")
    try checkEntry(entryDelegate.narrationPreview == nil && entryDelegate.previewPrompter == nil && !window.isVisible,
                   "cancel stops preview and removes preparation chrome")
    cancelledPicker?.finish(true)
    try checkEntry(entryDelegate.narrationSetup == nil && !window.isVisible, "late picker callback cannot reopen cancelled preparation")
    try checkEntry(recordConfig()["narration_script"] as? String == "cancel while selecting preserves this draft", "cancel flushes latest draft")

    entryDelegate.reopenResident()
    let reopened = try currentEntryWindow()
    try checkEntry(entryDelegate.narrationSetup != nil && entryDelegate.picker == nil && entryPrepareCalls == 0,
                   "idle resident reopen now enters preparation preview rather than legacy picker")
    try closeEntry(reopened)
    try checkEntry(!entryDelegate.busy && entryDelegate.narrationSetup == nil, "borderless close control releases preparation")
    try dispatchEntry("mNarration", from: entryMenu(entryDelegate))
    entryDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    try checkEntry(!entryDelegate.busy && entryDelegate.narrationSetup == nil, "termination flushes and clears preparation")

    try dispatchEntry("mNarration", from: entryMenu(entryDelegate))
    guard let recordingSetup = entryDelegate.narrationSetup else { throw EntryTestFailure(message: "Missing recording setup") }
    let recordingWindow = try currentEntryWindow()
    let recordingEditor = try entryEditor(recordingWindow)
    editEntry("", editor: recordingEditor, setup: recordingSetup)
    recordingSetup.setPrompterEnabled(false)
    try entryButton("麦克风", in: recordingWindow).performClick(nil)
    entryDelegate.narrationPreview?.onImage?(syntheticEntryFrame())
    try checkEntry(try entryButton("开始录制", in: recordingWindow).isEnabled, "empty script is valid with prompter disabled")
    try entryButton("开始录制", in: recordingWindow).performClick(nil)
    guard let recorder = entryDelegate.rec else { throw EntryTestFailure(message: "Production start did not reach isolated recorder boundary") }
    try checkEntry(entryPrepareCalls == 1 && entrySyntheticRecorderStarts == 0,
                   "explicit start alone reaches isolated preparation boundary")
    try checkEntry(recordingWindow.isVisible && entryDelegate.narrationSetup === recordingSetup,
                   "setup stays visible until recorder preparation succeeds")
    try checkEntry(entryDelegate.narrationPreview == nil && entryDelegate.previewPrompter == nil,
                   "start stops preview stream and preview-only prompter")
    try checkEntry(opts.narrationScript == "" && !opts.prompterEnabled && !opts.mic,
                   "explicit start forwards empty script, prompter off, and microphone off")
    entryPendingPrepareCompletion?(nil)
    entryPendingPrepareCompletion = nil
    try checkEntry(entrySyntheticRecorderStarts == 1 && !recordingWindow.isVisible,
                   "preparation success hides setup and reaches synthetic recorder start")

    let recordingMenu = entryMenu(entryDelegate)
    try checkEntry(recordingMenu.items.contains(where: { $0.title == "录制设置与讲稿…" && $0.isEnabled }),
                   "recording menu retains preparation-and-script entry")
    try dispatchEntry("mNarration", from: recordingMenu)
    try checkEntry(entryDelegate.narrationSetup === recordingSetup && recordingWindow.isVisible && recordingWindow.title == "录制中 · Blurt",
                   "recording menu reopens the retained interface in recording mode")
    try checkEntry(!(try entryButton("全屏", in: recordingWindow)).isEnabled && !(try entryButton("选择区域", in: recordingWindow)).isEnabled && !(try entryButton("麦克风", in: recordingWindow)).isEnabled,
                   "recording mode locks region and microphone controls")
    try checkEntry((try entryButton("完成录制", in: recordingWindow)).isEnabled,
                   "finish stays available while recording preview is loading")
    editEntry("recording draft flushes when returning", editor: recordingEditor, setup: recordingSetup)
    try entryButton("返回录制", in: recordingWindow).performClick(nil)
    try checkEntry(!recordingWindow.isVisible && entryDelegate.narrationPreview == nil && entryDelegate.rec === recorder && entryDelegate.busy,
                   "return hides controls and stops only the preview, keeping recording alive")
    try checkEntry(opts.narrationScript == "recording draft flushes when returning", "return flushes script into active recorder")
    recorder.onEditNarration?()
    try checkEntry(recordingWindow.isVisible && entryDelegate.narrationPreview != nil, "recorder edit callback restores retained controls and preview")
    recordingSetup.setPrompterEnabled(true)
    try checkEntry(recorder.prompterVisible && opts.prompterEnabled, "recording interface can enable teleprompter")
    recorder.teleprompter?.onClose?()
    try checkEntry(!recorder.prompterVisible && !recordingSetup.prompterEnabled, "closing recording prompter updates interface toggle")
    editEntry("final words before debounce fires", editor: recordingEditor, setup: recordingSetup)
    try entryButton("完成录制", in: recordingWindow).performClick(nil)
    try checkEntry(entrySyntheticRecorderStops == 1 && opts.narrationScript == "final words before debounce fires",
                   "finish flushes latest script then sends one stop through production callback")
    entryDelegate.takeEnded(2, ["event": "cancelled"])
    try checkEntry(entryDelegate.rec == nil && entryDelegate.narrationSetup == nil && entryDelegate.narrationPreview == nil && !entryDelegate.busy,
                   "take completion releases recording, preview, and retained controls")

    // Exercise the separate HUD/menu-finish path: completion must persist edits
    // made less than one debounce interval ago, without using setup's Finish.
    try dispatchEntry("mNarration", from: entryMenu(entryDelegate))
    guard let externalFinishSetup = entryDelegate.narrationSetup else { throw EntryTestFailure(message: "Missing second setup") }
    let externalFinishWindow = try currentEntryWindow()
    let externalFinishEditor = try entryEditor(externalFinishWindow)
    entryDelegate.narrationPreview?.onImage?(syntheticEntryFrame())
    try entryButton("开始录制", in: externalFinishWindow).performClick(nil)
    entryPendingPrepareCompletion?(nil)
    entryPendingPrepareCompletion = nil
    entryDelegate.showNarrationControls()
    try checkEntry(entryDelegate.narrationPreview != nil, "recording controls have preview before restart")
    entryDelegate.rec?.onRestart?()
    try checkEntry(entryDelegate.narrationPreview == nil && entryPrepareCalls == 3,
                   "restart stops controls preview before preparing replacement recorder")
    entryPendingPrepareCompletion?(nil)
    entryPendingPrepareCompletion = nil
    entryDelegate.showNarrationControls()
    editEntry("HUD completion must keep the last 300 ms of edits", editor: externalFinishEditor, setup: externalFinishSetup)
    entryDelegate.takeEnded(0, ["event": "stopped", "duration": 1.0])
    try checkEntry(entrySavedNarrationScript == "HUD completion must keep the last 300 ms of edits",
                   "external take completion writes latest undebounced script before teardown")
    try checkEntry(entryDelegate.rec == nil && entryDelegate.narrationSetup == nil && !entryDelegate.busy,
                   "successful take completion releases retained controls without an export dialog in tests")

    let attachedScreens = NSScreen.screens
    if attachedScreens.count >= 2 {
        entryMultiDisplayRan = true
        let internalScreen = (attachedScreens.first(where: { CGDisplayIsBuiltin(narrationDisplayID($0)) != 0 }) ?? attachedScreens.first)!
        let externalScreen = attachedScreens.first { narrationDisplayID($0) != narrationDisplayID(internalScreen) }!
        let internalID = narrationDisplayID(internalScreen)
        let externalID = narrationDisplayID(externalScreen)
        let externalFrame = toCG(externalScreen.frame)
        try dispatchEntry("mNarration", from: entryMenu(entryDelegate))
        guard let dualSetup = entryDelegate.narrationSetup else { throw EntryTestFailure(message: "Missing multi-display setup") }
        let dualWindow = try currentEntryWindow()
        dualSetup.setPrompterEnabled(false)
        dualSetup.onSelectRecordingDisplay?(externalID)
        try checkEntry(entryDelegate.narrationRecordingDisplayID == externalID && entryDelegate.narrationRegion == externalFrame,
                       "multi-display: recording selector chooses external display full frame")
        try checkEntry(entryDelegate.narrationPreview?.displayID == externalID && entryDelegate.narrationPreview?.expectedDisplayFrame == externalFrame,
                       "multi-display: preview pins external display ID and expected frame")
        dualSetup.onSelectPrompterDisplay?(internalID)
        try checkEntry(entryDelegate.narrationPrompterDisplayID == internalID && !dualSetup.prompterEnabled && entryDelegate.previewPrompter?.isVisible != true,
                       "multi-display: choosing internal prompter screen while off does not enable it")
        try checkEntry(entryDelegate.narrationRecordingDisplayID == externalID && entryDelegate.narrationRegion == externalFrame && entryDelegate.narrationPreview?.displayID == externalID,
                       "multi-display: prompter screen change preserves external recording and preview target")
        try checkEntry(TeleprompterPanel.preferredDisplayID(fallback: externalID) == internalID,
                       "multi-display: independent prompter display preference is saved")
        dualSetup.setPrompterEnabled(true)
        guard let previewPanel = entryDelegate.previewPrompter else { throw EntryTestFailure(message: "Missing multi-display preview prompter") }
        try checkEntry(previewPanel.isVisible && previewPanel.currentDisplayID == internalID && internalScreen.visibleFrame.contains(previewPanel.frame),
                       "multi-display: enabling prompter places its complete window on internal screen")
        let prompterFrame = previewPanel.frame
        dualSetup.onSelectRecordingDisplay?(internalID)
        dualSetup.onSelectRecordingDisplay?(externalID)
        try checkEntry(previewPanel.currentDisplayID == internalID && previewPanel.frame == prompterFrame,
                       "multi-display: switching recording screens never moves prompter")
        try entryButton("选择区域", in: dualWindow).performClick(nil)
        guard let targetedPicker = entryDelegate.picker else { throw EntryTestFailure(message: "No external-display picker") }
        try checkEntry(targetedPicker.targetDisplayID == externalID && targetedPicker.selectionOnly,
                       "multi-display: area picker is targeted to selected external display")
        try checkEntry(targetedPicker.screenFrame(containing: internalScreen.frame.origin) == externalScreen.frame,
                       "multi-display: picker bounds remain external even with pointer on internal screen")
        targetedPicker.fullScreen()
        targetedPicker.finish(true)
        try checkEntry(entryDelegate.narrationRegion == externalFrame && entryDelegate.narrationRecordingDisplayID == externalID,
                       "multi-display: picker full-screen confirmation preserves external target")
        try checkEntry(previewPanel.currentDisplayID == internalID && previewPanel.isVisible,
                       "multi-display: returning from area selection restores prompter on internal screen")

        // Confirmation is a second boundary: a stale or escaped rectangle must
        // not retarget another monitor, even if it bypassed the mouse picker.
        try entryButton("选择区域", in: dualWindow).performClick(nil)
        let foreignPicker = entryDelegate.picker!
        foreignPicker.selection = internalScreen.frame.insetBy(dx: 30, dy: 30)
        foreignPicker.finish(true)
        try checkEntry(entryDelegate.narrationRegion == externalFrame && entryDelegate.narrationRecordingDisplayID == externalID,
                       "multi-display: confirmation wholly on another screen cannot retarget capture")
        try entryButton("选择区域", in: dualWindow).performClick(nil)
        let partialPicker = entryDelegate.picker!
        let partlyOutside = CGRect(x: externalFrame.minX - 100, y: externalFrame.minY + 20, width: 200, height: 160)
        partialPicker.selection = toNS(partlyOutside)
        partialPicker.finish(true)
        try checkEntry(entryDelegate.narrationRegion == partlyOutside.intersection(externalFrame) && entryDelegate.narrationRecordingDisplayID == externalID,
                       "multi-display: confirmation clips partial overflow to chosen display")
        entryDelegate.selectNarrationFullScreen()
        try entryButton("选择区域", in: dualWindow).performClick(nil)
        let sliverPicker = entryDelegate.picker!
        sliverPicker.selection = toNS(CGRect(x: externalFrame.minX - 95, y: externalFrame.minY + 20, width: 100, height: 160))
        sliverPicker.finish(true)
        try checkEntry(entryDelegate.narrationRegion == externalFrame && entryDelegate.narrationRecordingDisplayID == externalID,
                       "multi-display: sub-eight-point intersection is rejected without changing capture")
        try entryButton("选择区域", in: dualWindow).performClick(nil)
        let missingPicker = entryDelegate.picker!
        let missingID = (CGDirectDisplayID.max - 1000...CGDirectDisplayID.max).first { narrationScreen($0) == nil }!
        missingPicker.targetDisplayID = missingID
        missingPicker.selection = externalScreen.frame
        missingPicker.finish(true)
        try checkEntry(entryDelegate.narrationRegion == externalFrame && entryDelegate.narrationRecordingDisplayID == externalID,
                       "multi-display: missing target rejects confirmation without selecting a different screen")

        try entryButton("选择区域", in: dualWindow).performClick(nil)
        let nudgePicker = entryDelegate.picker!
        let nudgeView = PickerView(frame: .zero)
        nudgeView.controller = nudgePicker
        let bounds = externalScreen.frame
        let size = NSSize(width: 160, height: 90)
        let edgeCases: [(Int, NSPoint, String)] = [
            (kVK_LeftArrow, NSPoint(x: bounds.minX, y: bounds.midY), "left"),
            (kVK_RightArrow, NSPoint(x: bounds.maxX - size.width, y: bounds.midY), "right"),
            (kVK_UpArrow, NSPoint(x: bounds.midX, y: bounds.maxY - size.height), "top"),
            (kVK_DownArrow, NSPoint(x: bounds.midX, y: bounds.minY), "bottom")]
        for (key, origin, edge) in edgeCases {
            for shift in [false, true] {
                let before = NSRect(origin: origin, size: size)
                nudgePicker.selection = before
                try entryArrow(key, shift: shift, to: nudgeView)
                try checkEntry(nudgePicker.selection == before && nudgePicker.targetDisplayID == externalID,
                               "multi-display: \(shift ? "ten" : "one")-point \(edge) keyboard nudge stays inside target without resizing")
            }
        }
        nudgePicker.finish(true)
        try checkEntry(entryDelegate.narrationRecordingDisplayID == externalID && externalFrame.contains(entryDelegate.narrationRegion!),
                       "multi-display: keyboard-adjusted confirmation cannot switch recording display")
        entryDelegate.selectNarrationFullScreen()
        entryDelegate.narrationPreview?.onImage?(syntheticEntryFrame())
        try entryButton("开始录制", in: dualWindow).performClick(nil)
        guard let dualRecorder = entryDelegate.rec else { throw EntryTestFailure(message: "No multi-display recorder") }
        try checkEntry(opts.recordingDisplayID == externalID && opts.recordingDisplayFrame == externalFrame,
                       "multi-display: explicit start pins external display ID and frame in options")
        try checkEntry(dualRecorder.recordingDisplayID == externalID && dualRecorder.recordingDisplayFrame == externalFrame && dualRecorder.region == externalFrame,
                       "multi-display: recorder captures pinned display identity and bounds")
        try checkEntry(dualRecorder.teleprompter?.currentDisplayID == internalID && dualRecorder.prompterVisible,
                       "multi-display: recording prompter preserves internal screen after preview teardown")
        entryPendingPrepareCompletion?(nil)
        entryPendingPrepareCompletion = nil
        entryDelegate.showNarrationControls()
        try checkEntry(entryDelegate.narrationPreview?.displayID == externalID && entryDelegate.narrationPreview?.expectedDisplayFrame == externalFrame,
                       "multi-display: reopened controls preview remains pinned to external recording")
        dualSetup.setPrompterEnabled(false)
        dualSetup.onSelectPrompterDisplay?(externalID)
        try checkEntry(!dualRecorder.prompterVisible && !dualSetup.prompterEnabled && dualRecorder.recordingDisplayID == externalID,
                       "multi-display: changing disabled prompter destination during take does not enable or retarget capture")
        dualSetup.onSelectPrompterDisplay?(internalID)
        dualSetup.setPrompterEnabled(true)
        try checkEntry(dualRecorder.teleprompter?.currentDisplayID == internalID && dualRecorder.prompterVisible && dualRecorder.recordingDisplayID == externalID,
                       "multi-display: recording external and prompting internal stay independent throughout take")
        entryDelegate.takeEnded(2, ["event": "cancelled"])
        try checkEntry(!entryDelegate.busy && entryDelegate.rec == nil && entryDelegate.narrationSetup == nil,
                       "multi-display: cleanup releases both screen roles")
    } else {
        entryMultiDisplaySkipReason = "Only one display is attached; external-record/internal-prompter integration requires two displays."
    }

    entryDelegate.busy = true
    let busyMenu = entryMenu(entryDelegate)
    try checkEntry(busyMenu.items.count == 1 && busyMenu.items[0].action == nil && !busyMenu.items[0].isEnabled,
                   "unrelated recording preparation stays noninteractive")
    entryDelegate.mNarration()
    entryDelegate.reopenResident()
    try checkEntry(entryDelegate.narrationSetup == nil && entryDelegate.busy, "unrelated busy state does not start another setup")
    emit(["test": "narration_entry_v2", "passed": true, "checks": entryChecks,
          "synthetic_preview_starts": entryPreviewStarts, "selection_only_picker_shows": entryPickerShows,
          "isolated_recorder_prepares": entryPrepareCalls, "synthetic_recorder_starts": entrySyntheticRecorderStarts,
          "synthetic_recorder_stops": entrySyntheticRecorderStops,
          "multi_display_ran": entryMultiDisplayRan,
          "multi_display_skip_reason": entryMultiDisplaySkipReason ?? ""])
    exit(0)
} catch {
    entryDelegate.rec?.cleanupChrome()
    entryDelegate.rec = nil
    entryDelegate.closeNarrationControls()
    emit(["test": "narration_entry_v2", "passed": false, "error": String(describing: error), "checks": entryChecks])
    exit(1)
}
