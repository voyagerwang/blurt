// Production App/controllers with only hardware, session writer and window-server boundaries doubled.
struct CameraLifecycleFailure: Error { let message: String }
var checks: [String] = []
var entryPreviewStarts = 0
var entryPreviewRegions: [CGRect] = []
var entryPickerShows = 0
var entryPrepareCalls = 0
var entrySyntheticRecorderStarts = 0
var entrySyntheticRecorderStops = 0
var entryPendingPrepareCompletion: ((Error?) -> Void)?
var entrySavedNarrationScript: String?
var entryToasts: [String] = []
func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
    guard value() else { throw CameraLifecycleFailure(message: label) }
    checks.append(label)
}
func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
func setupWindow() -> NSWindow { NSApp.windows.first { $0.isVisible && ($0.title == "录制准备 · Blurt" || $0.title == "录制中 · Blurt") }! }
func control<T: NSView>(_ type: T.Type, label: String) -> T {
    allViews(setupWindow().contentView!).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label }!
}
func recordButton() -> NSButton { allViews(setupWindow().contentView!).compactMap { $0 as? NSButton }.first { $0.title == "开始录制" }! }
func scriptEditor() -> NSTextView { allViews(setupWindow().contentView!).compactMap { $0 as? NSTextView }.first! }
func previewImage() -> NSImage {
    NSImage(size: CGSize(width: 640, height: 360), flipped: false) { rect in
        NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.4, alpha: 1).setFill(); rect.fill(); return true
    }
}
func cameraPixels() -> CVPixelBuffer {
    var pixels: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    guard CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixels) == kCVReturnSuccess else { fatalError("Synthetic pixel allocation") }
    CIContext().render(CIImage(color: CIColor(red: 0.1, green: 0.9, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120)), to: pixels!)
    return pixels!
}
func deliverFrame(_ capture: CameraCaptureController) {
    capture.testFrame = cameraPixels()
    capture.testPendingCompletion?(nil)
}
func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
opts.standalone = true
opts.lang = "zh"
opts.mic = false
setRecordConfig("narration_script", "Synthetic camera lifecycle draft")
setRecordConfig("narration_prompter_enabled", true)
setRecordConfig("narration_microphone_enabled", false)
setRecordConfig("standalone_prompter_enabled", false)
setRecordConfig("narration_camera_enabled", true)
setRecordConfig("countdown", 0)
let app = App()
var externalDisplayTested = false

do {
    app.mStandalonePrompter()
    try check(CameraCaptureController.testTotalStarts == 0 && app.narrationCameraFeed == nil && app.narrationCameraPanel == nil, "standalone launch never starts remembered recording camera")
    app.reopenResident()
    try check(CameraCaptureController.testTotalStarts == 0 && app.rec == nil, "standalone reopen remains camera-free")
    app.closeStandalonePrompter()
    setRecordConfig("narration_camera_enabled", false)
    app.mNarration()
    let setup = app.narrationSetup!
    let initialRegion = app.narrationRegion!
    app.narrationPreview?.onImage?(previewImage())
    try check(CameraCaptureController.testTotalStarts == 0 && recordButton().isEnabled, "disabled camera requires no device and leaves screen-only recording available")
    setup.setCameraEnabled(true)
    let capture = app.narrationCameraFeed!.capture
    let firstCompletion = capture.testPendingCompletion!
    let firstTimer = app.narrationCameraTimer!
    try check(capture.testStarts == 1 && app.narrationCameraStarting && !app.narrationCameraReady && app.narrationCameraPanel?.isVisible != true, "enabling waits for first frame without exposing empty camera panel")
    try check(!recordButton().isEnabled && app.narrationCameraFeed?.snapshot() == nil, "permission or connection in progress cannot create a camera-less take")
    app.startNarrationRecording(region: initialRegion, script: setup.scriptValue, enabled: true, microphone: false)
    try check(app.rec == nil && app.lastSession == nil && entryPrepareCalls == 0, "direct Record callback is gated until enabled camera has a frame")
    setup.setCameraEnabled(false)
    capture.testFrame = cameraPixels()
    firstCompletion(nil)
    try check(!app.narrationCameraReady && app.narrationCameraFeed?.snapshot() == nil && app.narrationCameraPanel?.isVisible != true, "late permission success after disabling cannot restore camera")
    try check(app.narrationCameraTimer == nil && !firstTimer.isValid && capture.testStops > 0 && recordButton().isEnabled, "disabling stops camera timer and restores screen-only readiness")
    setup.setCameraEnabled(true)
    let secondCompletion = capture.testPendingCompletion!
    firstCompletion(nil)
    try check(!app.narrationCameraReady && app.narrationCameraStarting, "older generation cannot mark a newer camera request ready")
    capture.testFrame = cameraPixels(); secondCompletion(nil)
    let panel = app.narrationCameraPanel!
    try check(app.narrationCameraReady && panel.isVisible && app.narrationCameraFeed?.snapshot() != nil && recordButton().isEnabled, "first synthetic frame enables preview and explicit recording")
    let startsBeforeStyle = capture.testStarts
    let shape = control(NSSegmentedControl.self, label: "摄像头形状")
    shape.selectedSegment = 1
    _ = NSApp.sendAction(shape.action!, to: shape.target, from: shape)
    let mirror = control(NSButton.self, label: "镜像摄像头画面和成片")
    mirror.state = .off
    _ = NSApp.sendAction(mirror.action!, to: mirror.target, from: mirror)
    try check(app.narrationCameraFeed?.snapshot()?.circular == false && app.narrationCameraFeed?.snapshot()?.mirrored == false && capture.testStarts == startsBeforeStyle, "shape and mirror changes reach export feed without restarting camera")
    let slider = control(NSSlider.self, label: "摄像头大小，占录制区域短边的比例")
    slider.doubleValue = 0.4
    _ = NSApp.sendAction(slider.action!, to: slider.target, from: slider)
    try check(abs(panel.frame.width - min(initialRegion.width, initialRegion.height) * 0.4) <= 1 && panel.frame.width == panel.frame.height, "size control uses recording shorter side and keeps camera square")
    let beforePrompterDisplay = app.narrationPrompterDisplayID
    if NSScreen.screens.count > 1 {
        let target = NSScreen.screens.first { narrationDisplayID($0) != app.narrationRecordingDisplayID }!
        app.selectNarrationRecordingDisplay(narrationDisplayID(target))
        externalDisplayTested = true
        try check(toCG(target.frame).contains(toCG(panel.frame)) && app.narrationRecordingDisplayID == narrationDisplayID(target), "selecting another display rehomes camera wholly within recorded screen")
        try check(app.narrationPrompterDisplayID == beforePrompterDisplay && capture.testStarts == startsBeforeStyle, "recording display change preserves separate prompter and running camera")
    }
    app.narrationPreview?.onImage?(previewImage())
    app.chooseNarrationRegion()
    try check(app.picker != nil && !panel.isVisible && capture.testStarts == startsBeforeStyle, "area selection hides camera chrome while retaining capture session")
    app.refreshNarrationCamera()
    try check(!panel.isVisible, "camera refresh cannot cover area picker")
    let display = toCG(narrationScreen(app.narrationRecordingDisplayID)!.frame)
    let crop = CGRect(x: display.minX + 40, y: display.minY + 30, width: 640, height: 360)
    app.picker!.selection = toNS(crop)
    app.picker!.finish(true)
    try check(app.narrationRegion == crop && panel.isVisible && crop.contains(toCG(panel.frame)), "chosen crop restores camera and clamps it inside output region")
    let normalized = app.narrationCameraFeed!.snapshot()!.normalizedRect
    try check(abs(normalized.width * crop.width - panel.frame.width) < 0.01 && abs(normalized.height * crop.height - panel.frame.height) < 0.01, "export normalized geometry matches overlay on off-origin crop")
    app.narrationPreview?.onImage?(previewImage())
    app.narrationPreview?.onError?("Synthetic preview failure")
    app.refreshNarrationCamera()
    try check(!recordButton().isEnabled && app.narrationScreenPreviewImage == nil, "camera timer cannot erase a screen-preview failure or enable Record")
    app.narrationPreview?.onImage?(previewImage())
    let deviceSelector = control(NSPopUpButton.self, label: "摄像头设备")
    deviceSelector.selectItem(at: 1)
    _ = NSApp.sendAction(deviceSelector.action!, to: deviceSelector.target, from: deviceSelector)
    let deviceBCompletion = capture.testPendingCompletion!
    try check(capture.testDeviceIDs.last! == "camera-b" && !app.narrationCameraReady && app.narrationCameraFeed?.snapshot() == nil, "switching device clears old face and re-gates recording")
    secondCompletion(nil)
    try check(!app.narrationCameraReady, "old device completion cannot enable replacement camera")
    deviceBCompletion(NSError(domain: "SyntheticCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic permission denied"]))
    try check(!app.narrationCameraReady && !app.narrationCameraStarting && !recordButton().isEnabled && !panel.isVisible, "camera denial leaves screen draft intact and camera-enabled Record disabled")
    setup.setCameraEnabled(false)
    try check(recordButton().isEnabled && setup.scriptValue == "Synthetic camera lifecycle draft", "turning off failed camera allows recording without changing script")
    setup.setCameraEnabled(true)
    deliverFrame(capture)
    let editor = scriptEditor()
    editor.string = "Newest pending draft before standalone camera cleanup"
    setup.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    let staleCompletion = capture.testPendingCompletion!
    let staleFailure = capture.onFailure!
    let oldTimer = app.narrationCameraTimer!
    app.mStandalonePrompter()
    try check(app.narrationCameraFeed == nil && app.narrationCameraPanel == nil && app.narrationCameraTimer == nil && !oldTimer.isValid && !panel.isVisible, "switching to standalone releases camera panel timer and feed")
    try check(app.standalonePrompterSetup?.scriptValue == editor.string && recordConfig()["narration_camera_enabled"] as? Bool == true, "mode switch flushes latest shared draft while remembering camera preference")
    let startsBeforeLate = CameraCaptureController.testTotalStarts
    staleCompletion(nil); staleFailure("Late synthetic failure")
    try check(app.narrationCameraFeed == nil && app.narrationCameraPanel == nil && CameraCaptureController.testTotalStarts == startsBeforeLate, "late camera callbacks cannot recreate recording mode or camera during standalone")

    app.mNarration()
    let recordingSetup = app.narrationSetup!
    let recordingCapture = app.narrationCameraFeed!.capture
    deliverFrame(recordingCapture)
    app.narrationPreview?.onImage?(previewImage())
    let recordingRegion = app.narrationRegion!
    app.startNarrationRecording(region: recordingRegion, script: recordingSetup.scriptValue, enabled: true, microphone: false)
    guard let recorder = app.rec else { throw CameraLifecycleFailure(message: "Recorder not created after ready camera") }
    try check(recorder.cameraFrameProvider?() != nil && entryPrepareCalls == 1 && opts.mic == false, "recording receives stable camera provider without changing microphone choice")
    recordingSetup.setCameraEnabled(false)
    try check(recorder.cameraFrameProvider?() == nil && app.rec === recorder, "camera can turn off during active take while screen recorder continues")
    recordingSetup.setCameraEnabled(true)
    deliverFrame(recordingCapture)
    try check(recorder.cameraFrameProvider?() != nil && app.rec === recorder, "same provider resumes live camera during same recording")
    recordingCapture.testFrame = nil
    recordingCapture.onFailure?("Synthetic camera disconnected")
    try check(app.rec === recorder && recorder.cameraFrameProvider?() == nil && !app.narrationCameraReady && !entryToasts.isEmpty, "device disconnection removes camera and reports issue without discarding take")
    recordingSetup.setCameraEnabled(false); recordingSetup.setCameraEnabled(true); deliverFrame(recordingCapture)
    let activePanel = app.narrationCameraPanel!
    recorder.onWillStop?(true)
    try check(app.narrationCameraFeed != nil && activePanel.isVisible, "restart keeps camera capture and placement available for replacement take")
    recorder.onWillStop?(false)
    try check(app.narrationCameraFeed == nil && app.narrationCameraPanel == nil && recorder.cameraFrameProvider?() == nil && !activePanel.isVisible, "final stop closes camera immediately before writer completion")
    app.takeEnded(2, ["event": "cancelled"])
    try check(app.rec == nil && app.narrationSetup == nil && !app.busy, "cancelled take releases recording and setup state")
    app.mNarration()
    let endingCapture = app.narrationCameraFeed!.capture
    let lateTermination = endingCapture.testPendingCompletion!
    app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    lateTermination(nil)
    drain()
    try check(app.narrationSetup == nil && app.narrationCameraFeed == nil && app.narrationCameraTimer == nil && endingCapture.testStops > 0, "termination cancels pending camera request and rejects late callbacks")
    emit(["test": "camera_lifecycle", "passed": true, "checks": checks, "external_display_tested": externalDisplayTested,
          "hardware_camera_starts": 0, "synthetic_camera_requests": CameraCaptureController.testTotalStarts])
    exit(0)
} catch {
    app.rec = nil
    app.closeNarrationControls()
    app.closeStandalonePrompter()
    emit(["test": "camera_lifecycle", "passed": false, "error": String(describing: error), "checks": checks])
    exit(1)
}
