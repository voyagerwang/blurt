#!/usr/bin/env python3
"""Encode/decode synthetic MP4 through production Recorder and camera compositor.

No real camera, screen, microphone, app launch, or user configuration is accessed.
The only screen input is one generated frame; camera changes must still reach MP4.
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
from run_synthetic import replace_method


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1] / 'skills/blurt/recorder/macos/BlurtRecorder.swift')
    parser.add_argument('--output', type=Path, default=Path(__file__).parent / 'results' / 'camera-compositor')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Requires macOS and Xcode Command Line Tools')
    args.output.mkdir(parents=True, exist_ok=True)
    source = args.source.read_text()
    prefix = isolate_camera_panel(isolate_camera_capture(source.split('// MARK: - Hotkeys', 1)[0]))
    for signature, following in [
        ('    func start(region: CGRect) {', '    func stop() {'),
        ('    func prepare(completion: @escaping (Error?) -> Void) {', '    func configure('),
        ('    func configure(_ content: SCShareableContent) throws {', '    func setupLegacyMic() throws {'),
        ('    func setupLegacyMic() throws {', '    // --- run'),
        ('    func start() {', '    func showChrome() {'),
    ]:
        prefix = replace_method(prefix, signature, following, '        fatalError("TEST SAFETY: capture unavailable")')
    prefix = prefix.replace('NSSound(named: "Submarine")?.play()', '// No completion sound in isolated test.')
    forbidden = ('SCShareableContent.get', 'SCStream(filter:', 'AVCaptureDeviceInput(device:', 'requestAccess(for:', 'captureSession?.startRunning()')
    if any(token in prefix for token in forbidden):
        raise SystemExit('Unisolated hardware boundary detected')
    with tempfile.TemporaryDirectory(prefix='blurt-camera-test-') as build:
        build = Path(build)
        config = 'let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".blurt/config.json")'
        assert prefix.count(config) == 1
        prefix = prefix.replace(config, f'let configURL = URL(fileURLWithPath: {json.dumps(str(build / "config.json"))})')
        swift = build / 'main.swift'
        swift.write_text(prefix + '\n' + (Path(__file__).parent / 'CameraCompositorHarness.swift').read_text())
        binary = build / 'camera-test'
        proc = subprocess.run(['xcrun', 'swiftc', '-O', str(swift), '-o', str(binary)], capture_output=True, text=True, timeout=180)
        (args.output / 'compile.log').write_text(proc.stdout + proc.stderr)
        if proc.returncode:
            raise SystemExit(f'Compile failed: {args.output / "compile.log"}')
        results = []
        for scenario in ('camera', 'off'):
            proc = subprocess.run([str(binary), '--out', str(args.output / f'{scenario}.mp4'), '--no-mic', '--scenario', scenario], capture_output=True, text=True, timeout=20)
            (args.output / f'{scenario}.log').write_text(proc.stdout + proc.stderr)
            reports = [json.loads(line) for line in proc.stdout.splitlines() if line.startswith('{')]
            report = next((r for r in reversed(reports) if r.get('test') == scenario), {'passed': False, 'test': scenario, 'reason': 'No report'})
            report['process_exit'] = proc.returncode
            report['passed'] = report['passed'] and proc.returncode == 0
            results.append(report)
        report = {'passed': all(r['passed'] for r in results), 'tests': results, 'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
                  'screen_capture_started': False, 'camera_capture_started': False, 'microphone_capture_started': False,
                  'real_config_accessed': False, 'limitations': ['Synthetic MP4 verifies compositing and recorder lifecycle; real camera permission and screen capture require separate interactive validation.']}
        (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
        raise SystemExit(0 if report['passed'] else 1)

if __name__ == '__main__':
    main()
