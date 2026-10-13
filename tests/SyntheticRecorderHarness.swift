// Test-only appended program. Production Recorder code is extracted by run_synthetic.py.
// No NSApplication launch, SCStream construction, capture permission request, or microphone.

enum HarnessBoundary {
    static var captureStarts = 0
    static var microphoneStarts = 0
    static var chromeStarts = 0
    static var completionSounds = 0
    static let fakeStream: HarnessStream? = HarnessStream()
}
final class HarnessStream {
    func startCapture(_ completion: @escaping (Error?) -> Void) {
        HarnessBoundary.captureStarts += 1
        completion(nil)
    }
}

enum HarnessError: Error { case invalid(String) }
let scenarioIndex = CommandLine.arguments.firstIndex(of: "--scenario")!
let scenario = CommandLine.arguments[scenarioIndex + 1]
let testURL = URL(fileURLWithPath: opts.out)
let testRecorder = Recorder(region: CGRect(x: 0, y: 0, width: 320, height: 180))
var terminalEvents = [[String: Any]]()
var terminalCodes = [Int32]()
var emittedReport = false

func report(_ passed: Bool, _ details: [String: Any]) {
    guard !emittedReport else { return }
    emittedReport = true
    var info = details
    info["test"] = scenario
    info["passed"] = passed
    info["capture_start_attempts"] = HarnessBoundary.captureStarts
    info["microphone_start_attempts"] = HarnessBoundary.microphoneStarts
    info["chrome_start_attempts"] = HarnessBoundary.chromeStarts
    info["terminal_events"] = terminalEvents
    info["terminal_codes"] = terminalCodes
    emit(info)
    exit(passed ? 0 : 1)
}

func installWriter() throws {
    try? FileManager.default.removeItem(at: testURL)
    testRecorder.writer = try AVAssetWriter(outputURL: testURL, fileType: .mp4)
    testRecorder.writer.shouldOptimizeForNetworkUse = false
    testRecorder.vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000,
                                          AVVideoExpectedSourceFrameRateKey: 30,
                                          AVVideoMaxKeyFrameIntervalKey: 60]])
    testRecorder.vIn.expectsMediaDataInRealTime = true
    testRecorder.writer.add(testRecorder.vIn)
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96000])
    audio.expectsMediaDataInRealTime = true
    testRecorder.writer.add(audio)
    testRecorder.aIn = audio
}

func audioSample(_ frame: Int, _ time: CMTime) throws -> CMSampleBuffer {
    let count = 1600
    var values = [Float]()
    let angularStep = 2.0 * Double.pi * 440.0 / 48000.0
    for i in 0..<count { values.append(Float(sin(angularStep * Double(frame * count + i)) * 0.25)) }
    var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
        mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
        let format = format else { throw HarnessError.invalid("Cannot describe generated audio") }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 4,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count * 4,
        flags: 0, blockBufferOut: &block) == noErr, let block = block else {
        throw HarnessError.invalid("Cannot allocate generated audio")
    }
    let copyResult = values.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 4)
    }
    guard copyResult == noErr else { throw HarnessError.invalid("Cannot copy generated audio") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
        presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
        sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
        let sample = sample else { throw HarnessError.invalid("Cannot create generated audio sample") }
    return sample
}

func sample(_ frame: Int, _ time: CMTime) throws -> CMSampleBuffer {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                             &buffer) == kCVReturnSuccess, let pixels = buffer else {
        throw HarnessError.invalid("Cannot create generated pixel buffer")
    }
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<180 {
        for x in 0..<320 {
            let p = y * stride + x * 4
            // Two constant patches prove decoded content came from this generated fixture.
            // A moving lower bar prevents the fixture from being a single repeated frame.
            let movingBar = y > 135 && x >= frame * 3 % 280 && x < frame * 3 % 280 + 32
            base[p] = movingBar ? 245 : (x < 160 ? 30 : 220)
            base[p + 1] = movingBar ? 245 : 35
            base[p + 2] = movingBar ? 245 : (x < 160 ? 220 : 30)
            base[p + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                                                       formatDescriptionOut: &format) == noErr,
          let format = format else { throw HarnessError.invalid("Cannot describe generated frame") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                   presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var out: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
                                                   formatDescription: format, sampleTiming: &timing,
                                                   sampleBufferOut: &out) == noErr,
          let out = out else { throw HarnessError.invalid("Cannot create generated sample") }
    return out
}

func verifyVideo() throws -> [String: Any] {
    let bytes = try Data(contentsOf: testURL)
    guard bytes.count > 1024, String(data: bytes[4..<8], encoding: .ascii) == "ftyp" else {
        throw HarnessError.invalid("Output is not a nonempty ISO base media container")
    }
    let asset = AVURLAsset(url: testURL)
    guard asset.isPlayable, let track = asset.tracks(withMediaType: .video).first else {
        throw HarnessError.invalid("Output does not have a playable video track")
    }
    guard let format = track.formatDescriptions.first,
          CMFormatDescriptionGetMediaSubType(format as! CMFormatDescription) == kCMVideoCodecType_H264 else {
        throw HarnessError.invalid("Output video codec is not H.264")
    }
    guard let audioTrack = asset.tracks(withMediaType: .audio).first,
          let audioFormat = audioTrack.formatDescriptions.first,
          CMFormatDescriptionGetMediaSubType(audioFormat as! CMFormatDescription) == kAudioFormatMPEG4AAC else {
        throw HarnessError.invalid("Output does not have an AAC track")
    }
    let duration = CMTimeGetSeconds(asset.duration)
    guard duration > 1.9, duration < 5 else { throw HarnessError.invalid("Unexpected duration: \(duration)") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track,
                                         outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading() else { throw HarnessError.invalid("Decoder did not start") }
    var decoded = 0
    var badPatches = 0
    while let sample = output.copyNextSampleBuffer() {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for (x, expectedR, expectedB) in [(60, 220, 30), (250, 30, 220)] {
            let p = 55 * stride + x * 4
            if abs(Int(base[p + 2]) - expectedR) > 25 || abs(Int(base[p]) - expectedB) > 25
                || abs(Int(base[p + 1]) - 35) > 25 { badPatches += 1 }
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        decoded += 1
    }
    guard reader.status == .completed, decoded == 60, badPatches == 0 else {
        throw HarnessError.invalid("Decode validation: status=\(reader.status.rawValue), frames=\(decoded), incorrect patches=\(badPatches)")
    }
    let audioReader = try AVAssetReader(asset: asset)
    let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1])
    audioReader.add(audioOutput)
    guard audioReader.startReading() else { throw HarnessError.invalid("Audio decoder did not start") }
    var audioSamples = 0
    var energy: Double = 0
    while let sample = audioOutput.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard result == noErr else { throw HarnessError.invalid("Cannot inspect decoded audio") }
        data.withUnsafeBytes { bytes in
            for value in bytes.bindMemory(to: Float.self) { energy += Double(value * value); audioSamples += 1 }
        }
    }
    let rms = sqrt(energy / Double(max(1, audioSamples)))
    guard audioReader.status == .completed, abs(audioSamples - 96000) <= 2048, rms > 0.15, rms < 0.2 else {
        throw HarnessError.invalid("Audio validation: samples=\(audioSamples), rms=\(rms), status=\(audioReader.status.rawValue)")
    }
    return ["file": testURL.path, "bytes": bytes.count, "codec": "H.264", "decoded_frames": decoded,
            "duration": duration, "generated_color_patches_match": true, "audio_codec": "AAC",
            "decoded_audio_samples": audioSamples, "decoded_audio_rms": rms,
            "writer_completed": testRecorder.writer.status == .completed]
}

var sessionEnded: (Int32, [String: Any]) -> Void = { code, event in
    terminalCodes.append(code)
    terminalEvents.append(event)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        let oneTerminal = terminalEvents.count == 1
        let boundaryUntouched = HarnessBoundary.captureStarts == 0 && HarnessBoundary.microphoneStarts == 0
            && HarnessBoundary.chromeStarts == 0
        switch scenario {
        case "encode":
            do {
                let details = try verifyVideo()
                report(oneTerminal && boundaryUntouched && code == 0 && event["event"] as? String == "stopped", details)
            } catch { report(false, ["reason": String(describing: error)]) }
        case "cancel_before_start":
            report(oneTerminal && boundaryUntouched && code != 0 && event["event"] as? String == "cancelled",
                   ["cancelled_without_capture": boundaryUntouched])
        case "writer_failure", "cancelled_after_start":
            report(oneTerminal && boundaryUntouched && code != 0 && event["event"] as? String == "error",
                   ["failure_reported_without_success": code != 0 && event["event"] as? String == "error"])
        default: report(false, ["reason": "Unknown scenario"])
        }
    }
}

DispatchQueue.main.async {
    do {
        try installWriter()
        switch scenario {
        case "encode":
            let base = CMTimeSubtract(hostNow(), CMTime(seconds: 2, preferredTimescale: 1_000_000_000))
            try testRecorder.q.sync {
                for i in 0..<60 {
                    let deadline = Date(timeIntervalSinceNow: 2)
                    while testRecorder.started && !testRecorder.vIn.isReadyForMoreMediaData && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    if testRecorder.started && !testRecorder.vIn.isReadyForMoreMediaData {
                        throw HarnessError.invalid("Encoder backpressure did not clear")
                    }
                    testRecorder.handleVideo(try sample(i, CMTimeAdd(base, CMTime(value: Int64(i), timescale: 30))))
                    let audioDeadline = Date(timeIntervalSinceNow: 2)
                    while testRecorder.aIn?.isReadyForMoreMediaData == false && Date() < audioDeadline {
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    guard testRecorder.aIn?.isReadyForMoreMediaData == true else {
                        throw HarnessError.invalid("Audio encoder backpressure did not clear")
                    }
                    testRecorder.handleAudio(try audioSample(i, CMTimeAdd(base, CMTime(value: Int64(i), timescale: 30))))
                }
            }
            testRecorder.stop()
        case "cancel_before_start":
            testRecorder.stop(discard: true)
            // Reproduce the stale countdown/prepare callback after cancellation.
            testRecorder.start()
        case "writer_failure":
            // A per-process tiny file limit induces a real encoder write failure.
            signal(SIGXFSZ, SIG_IGN)
            var limit = rlimit(rlim_cur: 512, rlim_max: 512)
            guard setrlimit(RLIMIT_FSIZE, &limit) == 0 else { throw HarnessError.invalid("Could not install test file-size limit") }
            try testRecorder.q.sync { testRecorder.handleVideo(try sample(0, hostNow())) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { testRecorder.stop() }
        case "cancelled_after_start":
            try testRecorder.q.sync { testRecorder.handleVideo(try sample(0, hostNow())) }
            testRecorder.q.sync { testRecorder.writer.cancelWriting() }
            testRecorder.stop()
        default: report(false, ["reason": "Unknown scenario"])
        }
    } catch { report(false, ["reason": String(describing: error)]) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
    report(false, ["reason": "No terminal result within six seconds", "writer_status": testRecorder.writer?.status.rawValue ?? -1])
}
RunLoop.main.run()
