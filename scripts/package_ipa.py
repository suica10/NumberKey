"""Validate a real device build and wrap it as an unsigned IPA for re-signing."""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
import zipfile
from embed_runtime_frameworks import embed_runtime_frameworks
from verify_ipa import verify_ipa

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/DerivedData/Build/Products/Release-iphoneos/NumberKey.app'
if not APP.is_dir():
    raise SystemExit('Device .app is missing. Build with the iphoneos SDK first.')
embed_runtime_frameworks(APP, ROOT)
with (APP / 'Info.plist').open('rb') as f:
    app_info = plistlib.load(f)
EXT = APP / 'PlugIns/NumberKeyKeyboard.appex'
with (EXT / 'Info.plist').open('rb') as f:
    extension_info = plistlib.load(f)
assert extension_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.keyboard-service'
assert extension_info['CFBundleIdentifier'].startswith(app_info['CFBundleIdentifier'] + '.')
assert extension_info['NSExtension']['NSExtensionAttributes']['RequestsOpenAccess'] is False
for bundle, info in [(APP, app_info), (EXT, extension_info)]:
    executable = bundle / info['CFBundleExecutable']
    archs = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).strip()
    assert archs == 'arm64', f'Unexpected device architectures: {archs}'
    assert 'iPhoneOS' in info['CFBundleSupportedPlatforms'], 'Simulator build cannot be packaged as a device IPA'
    signature = subprocess.run(['codesign', '-dv', str(executable)], capture_output=True)
    assert signature.returncode != 0, 'Expected an unsigned executable'
assert list(APP.rglob('Dictionary')), 'Missing bundled conversion dictionary'
assert (APP / 'ThirdPartyNotices.txt').is_file(), 'Missing license notices'

DIST = ROOT / 'dist'
DIST.mkdir(exist_ok=True)
destination = DIST / 'NumberKey-unsigned.ipa'
with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(APP.rglob('*')):
        if path.is_symlink():
            raise SystemExit(f'Unexpected symlink in app bundle: {path}')
        if path.is_file():
            entry = zipfile.ZipInfo.from_file(path, 'Payload/NumberKey.app/' + path.relative_to(APP).as_posix())
            entry.compress_type = zipfile.ZIP_DEFLATED
            # iOS executables must retain their executable Unix permissions.
            entry.create_system = 3
            archive.writestr(entry, path.read_bytes())
with zipfile.ZipFile(destination) as archive:
    assert archive.testzip() is None
dependency_report = verify_ipa(destination)
(DIST / 'dependency-report.json').write_text(json.dumps(dependency_report, indent=2), encoding='utf-8')
print('Packaged IPA dependency closure verified for app and keyboard extension.')
checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
(DIST / 'SHA256SUMS.txt').write_text(f'{checksum}  {destination.name}\n', encoding='utf-8')
print(f'Created unsigned IPA: {destination} ({destination.stat().st_size:,} bytes)')
