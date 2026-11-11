"""Embed the transitive binary framework Xcode omits from this keyboard app."""
from pathlib import Path
import plistlib
import shutil
import subprocess

def embed_runtime_frameworks(app, project_root):
    # The package currently autolinks llama even when its neural traits are off.
    # Its presence must follow the binary dependency, not the selected UI feature.
    roots = [app / 'NumberKey', app / 'PlugIns/NumberKeyKeyboard.appex/NumberKeyKeyboard']
    required = any('@rpath/llama.framework/llama' in subprocess.check_output(['otool', '-L', str(binary)], text=True) for binary in roots)
    if not required:
        print('No llama runtime dependency in device executables.')
        return
    destination = app / 'Frameworks/llama.framework'
    if not destination.exists():
        source = None
        for directory in [project_root / 'build/SourcePackages/artifacts', project_root / 'build/DerivedData/SourcePackages/artifacts']:
            for xcframework in directory.rglob('llama.xcframework'):
                with (xcframework / 'Info.plist').open('rb') as f:
                    libraries = plistlib.load(f)['AvailableLibraries']
                for library in libraries:
                    if library.get('SupportedPlatform') == 'ios' and not library.get('SupportedPlatformVariant') and 'arm64' in library.get('SupportedArchitectures', []):
                        source = xcframework / library['LibraryIdentifier'] / library['LibraryPath']
                        break
                if source:
                    break
            if source:
                break
        if source is None or not source.is_dir():
            raise RuntimeError('Required llama iOS device framework is missing from resolved package artifacts')
        destination.parent.mkdir(exist_ok=True)
        shutil.copytree(source, destination, symlinks=False)
    binary = destination / 'llama'
    architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    if architectures != ['arm64']:
        raise RuntimeError(f'Wrong llama device framework architectures: {architectures}')
    if subprocess.run(['codesign', '-dv', str(binary)], capture_output=True).returncode == 0:
        subprocess.run(['codesign', '--remove-signature', str(binary)], check=True)
    signature = destination / '_CodeSignature'
    if signature.exists():
        if not signature.resolve().is_relative_to(app.resolve()):
            raise RuntimeError('Framework signature path escapes the generated app bundle')
        shutil.rmtree(signature)
    print('Embedded required device runtime: NumberKey.app/Frameworks/llama.framework')
