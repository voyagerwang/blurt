// Synthetic camera/screen fixture, appended to production Recorder by test_camera_compositor.py.
let testScenario = CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--scenario")! + 1]
let testRecorder = Recorder(region: CGRect(x: 1920, y: -240, width: 320, height: 240))
let testURL = URL(fileURLWithPath: opts.out)
var checks: [[String: Any]] = []
var currentCamera: CameraCompositeState?
var pauseFrameCount = 0
var stopCallbacks = 0

func check(_ value: Bool, _ name: String) { checks.append(["name": name, "passed": value]) }
func fixture(width: Int, height: Int, camera: Bool) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    precondition(result == kCVReturnSuccess)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    let p = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<height { for x in 0..<width {
        let offset = y * stride + x * 4
        let red = camera && x >= 40 && x < 80
        let green = camera && x >= 80 && x < 120
        p[offset] = red ? 20 : green ? 30 : 130
        p[offset + 1] = red ? 20 : green ? 210 : 40
        p[offset + 2] = red ? 225 : green ? 20 : 15
        p[offset + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    return pixels
}
func sample(_ pixels: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &buffer) == noErr)
    return buffer!
}
func near(_ pixels: CVPixelBuffer, _ x: Int, _ y: Int, _ rgb: [Int]) -> Bool {
    CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let i = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
    return abs(Int(p[i + 2]) - rgb[0]) < 38 && abs(Int(p[i + 1]) - rgb[1]) < 38 && abs(Int(p[i]) - rgb[2]) < 38
}
func screenNV12Fixture() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    // A Rec.709 video-range screen fixture, matching ScreenCaptureKit's production format.
    let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<240 { for x in 0..<320 { luma[y * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) + x] = 51 } }
    for y in 0..<120 { for x in stride(from: 0, to: 320, by: 2) {
        let i = y * CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) + x
        chroma[i] = 176; chroma[i + 1] = 111
    } }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return pixels
}
let screenFixture = screenNV12Fixture()
let cameraFixture = fixture(width: 160, height: 80, camera: true)
let red = [225, 20, 20], green = [20, 210, 30], background = [15, 40, 130]
let firstRect = CGRect(x: 20.0 / 320, y: 20.0 / 240, width: 80.0 / 320, height: 80.0 / 240)
let movedRect = CGRect(x: 200.0 / 320, y: 130.0 / 240, width: 96.0 / 320, height: 96.0 / 240)

func validateFile(_ event: [String: Any], code: Int32) {
    do {
        check(code == 0 && event["event"] as? String == "stopped", "writer completed MP4")
        let asset = AVURLAsset(url: testURL)
        let track = asset.tracks(withMediaType: .video).first!
        check(Int(track.naturalSize.width) == 320 && Int(track.naturalSize.height) == 240, "MP4 keeps selected output dimensions")
        check(asset.tracks(withMediaType: .audio).isEmpty, "synthetic camera path does not add microphone")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); check(reader.startReading(), "MP4 decoder starts")
        var decoded: [(Double, CVPixelBuffer)] = []
        while let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) {
            decoded.append((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), pixels))
        }
        check(reader.status == .completed, "MP4 decoder reaches end")
        check(zip(decoded, decoded.dropFirst()).allSatisfy { $0.0.0 < $0.1.0 }, "all decoded timestamps strictly increase")
        if testScenario == "camera" {
            check(decoded.count >= 50, "camera updates keep static screen video advancing")
            func frame(_ time: Double) -> CVPixelBuffer { decoded.min(by: { abs($0.0 - time) < abs($1.0 - time) })!.1 }
            let square = frame(0.25)
            check(near(square, 25, 25, red) && near(square, 95, 25, green), "square fills corners and uses top-left normalized position")
            check(near(square, 35, 60, red) && near(square, 85, 60, green), "aspect fill crops wide camera sides without letterboxing")
            check(near(square, 200, 180, background), "screen outside camera preserved")
            let circle = frame(0.7)
            check(near(circle, 22, 22, background), "circular camera leaves corners transparent")
            check(near(circle, 40, 60, green) && near(circle, 80, 60, red), "mirror setting encoded in actual MP4")
            let moved = frame(1.15)
            check(near(moved, 60, 60, background), "moving camera leaves no ghost at old position")
            check(near(moved, 220, 178, red) && near(moved, 278, 178, green), "resized camera moves within selected external-display region")
            check(near(moved, 202, 132, background), "resized circle keeps transparent corner")
            let off = frame(1.6)
            check(near(off, 60, 60, background) && near(off, 245, 175, background), "turning camera off restores static screen immediately")
            let duration = CMTimeGetSeconds(asset.duration)
            check(duration > 2.05 && duration < 2.5, "paused time excluded from MP4 duration")
            check(stopCallbacks == 1, "stop callback releases camera once")
        } else {
            check(decoded.count == 12, "camera-off path preserves original frame count")
            check(decoded.allSatisfy { near($0.1, 35, 35, background) && near($0.1, 250, 180, background) }, "camera-off MP4 preserves screen content")
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        emit(["test": testScenario, "passed": passed, "checks": checks, "decoded_frames": decoded.count,
              "duration": CMTimeGetSeconds(asset.duration), "file": opts.out])
        exit(passed ? 0 : 1)
    } catch {
        emit(["test": testScenario, "passed": false, "error": error.localizedDescription, "checks": checks]); exit(1)
    }
}
var sessionEnded: (Int32, [String: Any]) -> Void = { code, event in validateFile(event, code: code) }

try? FileManager.default.removeItem(at: testURL)
testRecorder.writer = try AVAssetWriter(outputURL: testURL, fileType: .mp4)
testRecorder.vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoExpectedSourceFrameRateKey: 30]])
testRecorder.vIn.expectsMediaDataInRealTime = true
testRecorder.writer.add(testRecorder.vIn)
testRecorder.onWillStop = { _ in stopCallbacks += 1 }

if testScenario == "camera" {
    let pending = Recorder(region: CGRect(x: 0, y: 0, width: 320, height: 240))
    var pendingStops = 0
    pending.startingCapture = true
    pending.onWillStop = { restart in if !restart { pendingStops += 1 } }
    pending.stop()
    pending.stop()
    check(pendingStops == 1 && pending.pendingStop != nil, "stop during capture startup releases camera immediately once")
    let pendingRestart = Recorder(region: CGRect(x: 0, y: 0, width: 320, height: 240))
    var restartStops = 0
    pendingRestart.startingCapture = true
    pendingRestart.onWillStop = { _ in restartStops += 1 }
    pendingRestart.stop(restart: true)
    check(restartStops == 0 && pendingRestart.pendingStop?.restart == true, "restart during startup retains camera for the next take")
    currentCamera = CameraCompositeState(pixelBuffer: cameraFixture, normalizedRect: firstRect, circular: false, mirrored: false)
    let composed = CameraCompositor().compositedBuffer(screen: screenFixture, state: currentCamera!)!
    check(CVBufferCopyAttachment(composed, kCVImageBufferColorPrimariesKey, nil) as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String, "compositing preserves screen color primaries")
    check(CVBufferCopyAttachment(composed, kCVImageBufferTransferFunctionKey, nil) as? String == kCVImageBufferTransferFunction_ITU_R_709_2 as String, "compositing preserves screen transfer metadata")
    testRecorder.cameraFrameProvider = { currentCamera }
    testRecorder.q.sync { testRecorder.handleScreenVideo(sample(screenFixture, at: hostNow())) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
        testRecorder.q.sync { currentCamera = CameraCompositeState(pixelBuffer: cameraFixture, normalizedRect: firstRect, circular: true, mirrored: true) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
        testRecorder.q.sync { currentCamera = CameraCompositeState(pixelBuffer: cameraFixture, normalizedRect: movedRect, circular: true, mirrored: false) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) { testRecorder.q.sync { currentCamera = nil } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
        testRecorder.togglePause()
        testRecorder.q.sync { pauseFrameCount = testRecorder.frames }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.15) {
        testRecorder.q.sync { check(testRecorder.frames == pauseFrameCount, "camera refresh appends no frames while paused") }
        testRecorder.togglePause()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { testRecorder.stop() }
} else {
    testRecorder.q.sync {
        let base = CMTimeSubtract(hostNow(), CMTime(seconds: 0.5, preferredTimescale: 1_000_000_000))
        for i in 0..<12 {
            while testRecorder.started && !testRecorder.vIn.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            testRecorder.handleVideo(sample(screenFixture, at: CMTimeAdd(base, CMTime(value: Int64(i), timescale: 30))))
        }
    }
    DispatchQueue.main.async { testRecorder.stop() }
}
RunLoop.main.run()
