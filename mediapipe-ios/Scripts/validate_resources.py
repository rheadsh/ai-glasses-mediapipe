#!/usr/bin/env python3
"""Verify checked-in dependency/model pins and optionally a built Release .app."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def model_pins(script):
    pins = re.findall(r'download_model\s*\\\s*\n\s*"([^"/]+)"\s*\\\s*\n\s*"https://[^"\n]+"\s*\\\s*\n\s*"([0-9a-f]{64})"', script)
    if len(pins) != 12 or len(dict(pins)) != 12:
        raise ValueError('Expected exactly 12 unique SHA-256-pinned model downloads')
    return dict(pins)


def verify_models(directory, pins):
    for filename, expected in pins.items():
        path = directory / filename
        hasher = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                hasher.update(chunk)
        digest = hasher.hexdigest()
        if digest != expected:
            raise ValueError(f'Model checksum mismatch: {path}')


def verify_dependencies(app_root):
    resolved = [json.loads(path.read_text()) for path in (
        app_root / 'mediapipe-ios.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
        app_root / 'mediapipe-ios.xcworkspace/xcshareddata/swiftpm/Package.resolved')]
    if resolved[0] != resolved[1]:
        raise ValueError('Shared Package.resolved files differ')
    dat = [pin for pin in resolved[0]['pins'] if pin['identity'] == 'meta-wearables-dat-ios']
    if len(dat) != 1 or dat[0]['state'].get('version') != '1.0.1':
        raise ValueError('Expected DAT 1.0.1 in both shared resolutions')
    lock = (app_root / 'Podfile.lock').read_text().split('\nDEPENDENCIES:', 1)[0]
    for name in ('MediaPipeTasksCommon', 'MediaPipeTasksVision'):
        versions = re.findall(r'^  - ' + name + r' \(([^)]+)\)', lock, re.M)
        if not versions or any(version != '0.10.35' for version in versions):
            raise ValueError(f'Expected {name} 0.10.35 in Podfile.lock')


def verify_release(app, pins):
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    dat = info.get('MWDAT')
    required = ('MetaAppID', 'AppLinkURLScheme', 'TeamID', 'ClientToken')
    if not isinstance(dat, dict) or any(key not in dat for key in required):
        raise ValueError('Release DAT configuration is missing required fields')
    if any(not isinstance(dat[key], str) for key in required):
        raise ValueError('Release DAT configuration fields must be strings')
    # Report field names only; never expose tokens or other plist credentials.
    if any('$(' in str(value) for value in dat.values()):
        raise ValueError('Release DAT configuration has unresolved build settings')
    if re.fullmatch(r'0|[1-9][0-9]*', dat['MetaAppID']) is None:
        raise ValueError('Release DAT configuration has an invalid MetaAppID')
    if dat['AppLinkURLScheme'] != 'mediapipe-ios://':
        raise ValueError('Release DAT configuration has an invalid AppLinkURLScheme')
    if not dat['TeamID'].strip():
        raise ValueError('Release DAT configuration requires a nonempty TeamID')
    developer_mode = dat['MetaAppID'] == '0'
    if not developer_mode and not dat['ClientToken'].strip():
        raise ValueError('Release DAT configuration requires a ClientToken for a nonzero MetaAppID')
    verify_models(app, pins)
    forbidden = [str(path.relative_to(app)) for path in app.rglob('*')
                 if path.name in ('plant.png', 'plant.mp4', 'TestResources')
                 or 'MWDATMockDevice' in path.name]
    if forbidden:
        raise ValueError('Release contains test/mock resources: ' + ', '.join(forbidden))
    executable = app / info['CFBundleExecutable']
    dependencies = subprocess.run(['xcrun', 'otool', '-L', str(executable)],
                                  check=True, text=True, capture_output=True).stdout
    if 'MWDATMockDevice' in dependencies:
        raise ValueError('Release executable links MockDeviceKit')
    print('Release: model hashes verified; no test fixtures or mock frameworks/dependencies')
    print('DAT configuration: ' + ('Developer Mode (MetaAppID=0); not production registration'
                                     if developer_mode else 'nonzero MetaAppID; production registration not verified'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-app', type=Path, help='Built .app (macOS with Xcode required)')
    args = parser.parse_args()
    app_root = ROOT / 'mediapipe-ios'
    pins = model_pins((app_root / 'Scripts/download_models.sh').read_text())
    verify_dependencies(app_root)
    verify_models(app_root / 'mediapipe-ios/Models', pins)
    print('Verified 12 model hashes, identical DAT 1.0.1 resolutions and MediaPipe 0.10.35 lock')
    if args.release_app:
        verify_release(args.release_app.resolve(), pins)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Validation failed: {error}', file=sys.stderr)
        sys.exit(1)
