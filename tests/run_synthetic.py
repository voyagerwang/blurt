#!/usr/bin/env python3
"""Exercise Blurt's native MP4 pipeline without screen/audio capture or application launch.

The runner builds Recorder directly from the current Swift source. It isolates preparation, preview, and hardware capture boundaries, and replaces
the three hardware/UI calls in Recorder.start and the completion sound with probes.
Configuration uses a temporary file. No real screen or microphone capture is reachable.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from camera_test_isolation import isolate_camera_capture, isolate_camera_panel


def replace_method(source: str, signature: str, following: str, body: str) -> str:
    """Replace an exact audited boundary; source drift requires a manual review."""
    if source.count(signature) != 1:
        raise SystemExit(f"Isolation boundary changed: {signature}")
    start = source.index(signature)
    end = source.find(following, start + len(signature))
    if end < 0:
        raise SystemExit(f"Isolation end boundary changed: {following}")
    indent = signature[:len(signature) - len(signature.lstrip())]
    return source[:start] + signature + "\n" + body + "\n" + indent + "}\n\n" + source[end:]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1] / "skills/blurt/recorder/macos/BlurtRecorder.swift")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "results")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("These native recorder checks require macOS and Xcode Command Line Tools")
    args.output.mkdir(parents=True, exist_ok=True)
    source = args.source.read_text()
    marker = "// MARK: - Hotkeys"
    if marker not in source:
        raise SystemExit("Recorder extraction marker not found; review the test before running.")
    prefix = source.split(marker, 1)[0]
    prefix = isolate_camera_panel(isolate_camera_capture(prefix))
    for signature, following in [
        ("    func start(region: CGRect) {", "    func stop() {"),
        ("    func prepare(completion: @escaping (Error?) -> Void) {", "    func configure("),
        ("    func configure(_ content: SCShareableContent) throws {", "    func setupLegacyMic() throws {"),
        ("    func setupLegacyMic() throws {", "    // --- run"),
    ]:
        prefix = replace_method(prefix, signature, following,
                                '        fatalError("TEST SAFETY: live capture is unavailable")')
    replacements = {
        "let stream = stream else { return }": "let stream = HarnessBoundary.fakeStream else { return }",
        "self.captureSession?.startRunning()": "HarnessBoundary.microphoneStarts += 1",
        "self.showChrome()": "HarnessBoundary.chromeStarts += 1",
        'NSSound(named: "Submarine")?.play()': "HarnessBoundary.completionSounds += 1",
    }
    hooks = {}
    for old, new in replacements.items():
        count = prefix.count(old)
        if count != 1:
            raise SystemExit(f"Expected one platform boundary {old!r}; found {count}. Review the test before running.")
        prefix = prefix.replace(old, new, 1)
        hooks[old] = new
    forbidden = ["SCStream(filter:", "SCShareableContent.get", "AVCaptureDeviceInput(device:",
                 "captureSession?.startRunning()"]
    if any(token in prefix for token in forbidden):
        raise SystemExit("Capture safety check failed; review unisolated capture code")
    harness = (Path(__file__).parent / "SyntheticRecorderHarness.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="blurt-synthetic-") as build:
        build_path = Path(build)
        config_declaration = 'let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".blurt/config.json")'
        if prefix.count(config_declaration) != 1:
            raise SystemExit("Config isolation boundary changed; review the test before running")
        prefix = prefix.replace(config_declaration,
                                f'let configURL = URL(fileURLWithPath: {json.dumps(str(build_path / "config.json"))})', 1)
        main_swift = build_path / "main.swift"
        main_swift.write_text(prefix + "\n\n" + harness)
        binary = build_path / "synthetic-recorder"
        command = ["xcrun", "swiftc", "-O", str(main_swift), "-o", str(binary),
                   "-framework", "AppKit", "-framework", "AVFoundation", "-framework", "Carbon",
                   "-framework", "CoreMedia", "-framework", "ScreenCaptureKit", "-framework", "ServiceManagement"]
        compiled = subprocess.run(command, text=True, capture_output=True, timeout=120)
        (args.output / "compile.log").write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise SystemExit(f"Compilation failed. See {args.output / 'compile.log'}")
        results = []
        for scenario in ("encode", "cancel_before_start", "writer_failure", "cancelled_after_start"):
            output = args.output / f"{scenario}.mp4"
            proc = subprocess.run([str(binary), "--out", str(output), "--scenario", scenario],
                                  text=True, capture_output=True, timeout=15)
            (args.output / f"{scenario}.log").write_text(proc.stdout + proc.stderr)
            reports = []
            for line in proc.stdout.splitlines():
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if data.get("test") == scenario:
                    reports.append(data)
            report = reports[-1] if reports else {"test": scenario, "passed": False, "reason": "No test report"}
            report["process_exit"] = proc.returncode
            if proc.returncode:
                report["passed"] = False
            results.append(report)
        summary = {
            "source": str(args.source),
            "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "real_config_accessed": False,
            "screen_capture_started": False,
            "microphone_capture_started": False,
            "source_boundary_probes": hooks,
            "limitations": ["Generated images test encoding and lifecycle, not ScreenCaptureKit application filtering.",
                            "No real narration or desktop recording was started."],
            "tests": results,
            "passed": all(result.get("passed") for result in results),
        }
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
