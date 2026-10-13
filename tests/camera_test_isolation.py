"""Audited camera hardware boundary for native, offscreen integration tests.

Production compositing, App callbacks and camera geometry remain unchanged.
Only camera device enumeration, permission requests and capture sessions are
replaced; tests can explicitly deliver a synthetic frame or late completion.
"""
from __future__ import annotations

CAMERA_CAPTURE_DOUBLE = r'''// MARK: - Camera capture

struct CameraTestDevice {
    let uniqueID: String
    let localizedName: String
}
final class CameraCaptureController: NSObject {
    static var testDevices = [CameraTestDevice(uniqueID: "camera-a", localizedName: "Synthetic camera A"),
                              CameraTestDevice(uniqueID: "camera-b", localizedName: "Synthetic camera B")]
    static var testTotalStarts = 0
    static var testTotalStops = 0
    static func devices() -> [CameraTestDevice] { testDevices }
    var onFailure: ((String) -> Void)?
    var testFrame: CVPixelBuffer?
    var testPendingCompletion: ((Error?) -> Void)?
    var testStarts = 0
    var testStops = 0
    var testDeviceIDs: [String?] = []
    func start(deviceID: String?, completion: @escaping (Error?) -> Void) {
        Self.testTotalStarts += 1
        testStarts += 1
        testDeviceIDs.append(deviceID)
        testFrame = nil
        testPendingCompletion = completion
    }
    func stop() {
        Self.testTotalStops += 1
        testStops += 1
        testFrame = nil
    }
    func snapshot() -> CVPixelBuffer? { testFrame }
}

'''


def isolate_camera_capture(source: str) -> str:
    start_marker = "// MARK: - Camera capture"
    end_marker = "// MARK: - Camera compositing"
    if source.count(start_marker) != 1 or source.count(end_marker) != 1:
        raise SystemExit("Camera hardware isolation boundary changed; review the test")
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    if "struct CameraCompositeState" in source[start:end]:
        raise SystemExit("Composite state moved into hardware boundary; review the test")
    return source[:start] + CAMERA_CAPTURE_DOUBLE + source[end:]


def isolate_camera_panel(source: str) -> str:
    declaration = "final class CameraOverlayPanel: NSPanel {"
    if source.count(declaration) != 1:
        raise SystemExit("Camera window isolation boundary changed; review the test")
    start = source.index(declaration)
    end = source.index("// MARK: - Live recording preview", start)
    panel = source[start:end]
    if panel.count("super.orderOut(sender)") != 1:
        raise SystemExit("Camera hide isolation boundary changed; review the test")
    panel = panel.replace("super.orderOut(sender)", "cameraTestVisible = false", 1)
    panel = panel.replace(declaration, declaration + r'''
    // Logical visibility only: these test windows never reach the desktop.
    private var cameraTestVisible = false
    override var isVisible: Bool { cameraTestVisible }
    override func makeKeyAndOrderFront(_ sender: Any?) { cameraTestVisible = true }
    override func orderFrontRegardless() { cameraTestVisible = true }
    override func orderFront(_ sender: Any?) { cameraTestVisible = true }
''', 1)
    return source[:start] + panel + source[end:]
