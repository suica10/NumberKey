"""Embed the llama runtime framework into an archived .app and sign it.

Xcode does not embed this package's transitive binary framework into the
keyboard app (the same omission embed_runtime_frameworks.py works around
for unsigned builds): the keyboard extension links
@rpath/llama.framework/llama, but the framework never lands in the .app,
which would make the extension fail to load on device. Copy the iOS
device slice out of the resolved llama.xcframework into the archived
app's Frameworks folder and re-sign it with the team's distribution
identity (the publisher signature it ships with is not ours). The
subsequent exportArchive step re-seals the bundle for distribution.

Usage: embed_archive_frameworks.py <path-to-archived-.app> <project-root>
The signing identity comes from EMBED_SIGN_IDENTITY (default
"Apple Distribution").
"""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys


def main():
    app = Path(sys.argv[1]).resolve()
    project_root = Path(sys.argv[2]).resolve()
    identity = os.environ.get('EMBED_SIGN_IDENTITY', 'Apple Distribution')
    if not app.is_dir():
        raise SystemExit(f'Archived app is missing: {app}')
    executables = [
        app / 'NumberKey',
        app / 'PlugIns/NumberKeyKeyboard.appex/NumberKeyKeyboard',
    ]
    required = any(
        '@rpath/llama.framework/llama' in subprocess.check_output(
            ['otool', '-L', str(binary)], text=True)
        for binary in executables)
    if not required:
        print('No llama runtime dependency in archived executables.')
        return
    destination = app / 'Frameworks/llama.framework'
    if destination.exists():
        print('llama.framework already embedded in archived app.')
        return
    source = None
    for directory in [project_root / 'build/SourcePackages/artifacts',
                      project_root / 'build/DerivedData/SourcePackages/artifacts']:
        if not directory.is_dir():
            continue
        for xcframework in sorted(directory.rglob('llama.xcframework')):
            with (xcframework / 'Info.plist').open('rb') as f:
                libraries = plistlib.load(f)['AvailableLibraries']
            for library in libraries:
                if (library.get('SupportedPlatform') == 'ios'
                        and not library.get('SupportedPlatformVariant')
                        and 'arm64' in library.get('SupportedArchitectures', [])):
                    source = xcframework / library['LibraryIdentifier'] / library['LibraryPath']
                    break
            if source:
                break
        if source:
            break
    if source is None or not source.is_dir():
        raise SystemExit('Required llama iOS device framework is missing '
                         'from resolved package artifacts')
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=False)
    binary = destination / 'llama'
    architectures = subprocess.check_output(
        ['lipo', '-archs', str(binary)], text=True).split()
    if architectures != ['arm64']:
        raise SystemExit(f'Wrong llama device framework architectures: {architectures}')
    # Replace the publisher signature with the team's distribution identity.
    subprocess.run(['codesign', '--force', '--sign', identity, str(destination)],
                   check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(destination)],
                   check=True)
    print(f'Embedded and signed device runtime: {destination}')


if __name__ == '__main__':
    main()
