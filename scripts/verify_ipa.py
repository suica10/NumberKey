"""Check strong Mach-O dylib dependencies inside the actual packaged IPA."""
from pathlib import Path, PurePosixPath
import json
import plistlib
import posixpath
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

SYSTEM_PREFIXES = ('/System/Library/', '/usr/lib/')
DYLIB_COMMANDS = {0xC, 0x8000001F, 0x80000023}
WEAK_DYLIB = 0x80000018
RPATH = 0x8000001C

def macho_slices(data):
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide = data[:4] == b'\xca\xfe\xba\xbf'
        count = struct.unpack_from('>I', data, 4)[0]
        size = 32 if wide else 20
        for index in range(count):
            entry = 8 + index * size
            offset, length = struct.unpack_from('>QQ' if wide else '>II', data, entry + 8)
            yield data[offset:offset + length]
    else:
        yield data

def commands(data):
    dependencies, rpaths = set(), []
    for part in macho_slices(data):
        if part[:4] != b'\xcf\xfa\xed\xfe':
            raise ValueError('Expected a little-endian 64-bit device Mach-O')
        count, command_bytes = struct.unpack_from('<II', part, 16)
        offset = 32
        end = offset + command_bytes
        if end > len(part):
            raise ValueError('Truncated Mach-O load commands')
        for _ in range(count):
            command, length = struct.unpack_from('<II', part, offset)
            if length < 8 or offset + length > end:
                raise ValueError('Invalid Mach-O load command')
            if command in DYLIB_COMMANDS or command == RPATH:
                name_offset = struct.unpack_from('<I', part, offset + 8)[0]
                value = part[offset + name_offset:offset + length].split(b'\0', 1)[0].decode('utf-8')
                if command == RPATH:
                    if value not in rpaths:
                        rpaths.append(value)
                else:
                    dependencies.add(value)
            offset += length
    return sorted(dependencies), rpaths

def expand(path, loader, executable):
    for token, base in [('@loader_path', loader), ('@executable_path', executable)]:
        if path == token or path.startswith(token + '/'):
            return posixpath.normpath(base + path[len(token):])
    return posixpath.normpath(path)

def verify_ipa(path):
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        app_plists = [name for name in names if name.startswith('Payload/') and name.count('/') == 2 and name.endswith('.app/Info.plist')]
        if len(app_plists) != 1:
            raise ValueError('Expected exactly one app in Payload')
        app_dir = str(PurePosixPath(app_plists[0]).parent)
        plist_paths = [app_plists[0]] + sorted(name for name in names if name.startswith(app_dir + '/PlugIns/') and name.count('/') == 4 and name.endswith('.appex/Info.plist'))
        roots = []
        for name in plist_paths:
            info = plistlib.loads(archive.read(name))
            if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
                raise ValueError(f'Not an iPhoneOS bundle: {name}')
            roots.append(str(PurePosixPath(name).parent / info['CFBundleExecutable']))
        if len(roots) < 2:
            raise ValueError('IPA is missing its keyboard extension')
        checked = []
        for executable in roots:
            visited = set()
            def check(binary, inherited_paths):
                if binary in visited:
                    return
                visited.add(binary)
                if binary not in names:
                    raise ValueError(f'Missing executable: {binary}')
                dependencies, rpaths = commands(archive.read(binary))
                loader_dir = str(PurePosixPath(binary).parent)
                executable_dir = str(PurePosixPath(executable).parent)
                search = [expand(p, loader_dir, executable_dir) for p in rpaths] + inherited_paths
                for dependency in dependencies:
                    if dependency.startswith(SYSTEM_PREFIXES):
                        continue
                    if dependency.startswith('@rpath/'):
                        tail = dependency[len('@rpath/'):]
                        candidates = [posixpath.normpath(base + '/' + tail) for base in search]
                    else:
                        candidates = [expand(dependency, loader_dir, executable_dir)]
                    resolved = next((candidate for candidate in candidates if candidate in names), None)
                    if resolved is None and any(candidate.startswith(SYSTEM_PREFIXES) for candidate in candidates):
                        continue
                    if resolved is None:
                        raise ValueError(f'Missing runtime library: {dependency}\n  Required by: {binary}\n  Searched: {candidates}')
                    if not resolved.startswith(app_dir + '/'):
                        raise ValueError(f'Runtime dependency escapes the app: {resolved}')
                    checked.append({'executable': executable, 'loader': binary, 'dependency': dependency, 'resolved': resolved})
                    check(resolved, search)
            check(executable, [])
        appex_runpaths = audit_appex_runpaths(path)
        privacy_manifests = audit_privacy_manifests(path)
        return {'executables': roots, 'bundledDependencies': checked, 'appexRunpaths': appex_runpaths, 'privacyManifests': privacy_manifests, 'status': 'passed'}

def otool(arguments, binary):
    if shutil.which('otool') is None:
        raise ValueError('otool not found: the appex runpath audit requires macOS otool')
    result = subprocess.run(['otool', *arguments, str(binary)], capture_output=True, text=True)
    if result.returncode != 0:
        raise ValueError(f'otool {" ".join(arguments)} failed for {binary}: {result.stderr.strip()}')
    return result.stdout

def audit_appex_runpaths(path):
    """Fail if an appex links an @rpath framework its LC_RPATH cannot reach.

    The pure-Python walk above resolves @rpath dependencies against the
    union of every search path it has seen, which let build 85 pass even
    though the keyboard appex had no LC_RPATH entry reaching the app's
    Frameworks/ and dyld aborted it at launch (2026-11-26). This audit
    uses otool on the extracted bundle and resolves each appex's
    @rpath/<X>.framework/<X> dependencies strictly against that appex's
    own LC_RPATH entries (with @executable_path/@loader_path expanded
    relative to the appex), so a framework that is bundled in the app's
    Frameworks/ but unreachable from the extension fails verification.
    """
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(path) as archive:
            archive.extractall(tmp)
        apps = list(Path(tmp).glob('Payload/*.app'))
        if len(apps) != 1:
            raise ValueError('Expected exactly one app in Payload')
        app = apps[0]
        frameworks = app / 'Frameworks'
        appexes = sorted((app / 'PlugIns').glob('*.appex'))
        if not appexes:
            raise ValueError('No .appex found in the IPA')
        audited = []
        for appex in appexes:
            info = plistlib.loads((appex / 'Info.plist').read_bytes())
            executable = appex / info['CFBundleExecutable']
            rpaths = []
            lines = otool(['-l'], executable).splitlines()
            for index, line in enumerate(lines):
                if line.strip() == 'cmd LC_RPATH':
                    for following in lines[index:index + 4]:
                        match = re.match(r'\s*path\s+(.+?)\s*\(offset \d+\)\s*$', following)
                        if match:
                            rpaths.append(match.group(1))
            dependencies = []
            for line in otool(['-L'], executable).splitlines()[1:]:
                token = line.strip().split(' ', 1)[0]
                match = re.fullmatch(r'@rpath/([^/]+\.framework)/([^/]+)', token)
                if match and match.group(2) == match.group(1)[:-len('.framework')]:
                    dependencies.append(token)
            for dependency in dependencies:
                tail = dependency[len('@rpath/'):]
                candidates = []
                for rpath in rpaths:
                    expanded = rpath.replace('@executable_path', str(appex)).replace('@loader_path', str(appex))
                    candidates.append(str(Path(expanded) / tail))
                resolved = next((candidate for candidate in candidates if Path(candidate).is_file()), None)
                bundled = (frameworks / tail).is_file()
                if resolved is None:
                    detail = 'it is bundled in the app\'s Frameworks/ but no LC_RPATH entry reaches it' if bundled else 'it is not bundled in the app\'s Frameworks/ either'
                    raise ValueError(
                        f'Unreachable @rpath framework: {dependency}\n'
                        f'  Linked by: {executable}\n'
                        f'  LC_RPATH entries: {rpaths}\n'
                        f'  Searched: {candidates}\n'
                        f'  dyld would abort this extension at launch: {detail}')
                audited.append({'appex': appex.name, 'dependency': dependency, 'resolved': resolved})
        return audited

def audit_privacy_manifests(path):
    """Fail if a bundle ships without its PrivacyInfo.xcprivacy.

    A source audit on 2026-11-27 found required-reason API use in every
    bundle of this IPA: the app and both app extensions use UserDefaults
    (the App Group suite and the standard defaults), and the keyboard
    extension also uses ProcessInfo.systemUptime for on-device
    performance measurement. App Store Connect rejects uploads with
    ITMS-91053 when a bundle uses such APIs but ships no privacy
    manifest, and builds 85-88 shipped with no manifest in any bundle
    because the sources simply had none. Every bundle here — the .app
    and each .appex — must therefore carry a PrivacyInfo.xcprivacy at
    its bundle root, and the file must parse as a plist.
    """
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        app_plists = [name for name in names if name.startswith('Payload/') and name.count('/') == 2 and name.endswith('.app/Info.plist')]
        if len(app_plists) != 1:
            raise ValueError('Expected exactly one app in Payload')
        app_dir = str(PurePosixPath(app_plists[0]).parent)
        bundle_dirs = [app_dir] + sorted(
            str(PurePosixPath(name).parent)
            for name in names
            if name.startswith(app_dir + '/PlugIns/') and name.count('/') == 4 and name.endswith('.appex/Info.plist'))
        checked = []
        for bundle_dir in bundle_dirs:
            manifest = bundle_dir + '/PrivacyInfo.xcprivacy'
            if manifest not in names:
                raise ValueError(
                    f'Missing privacy manifest: {manifest}\n'
                    '  Every bundle in this IPA uses required-reason APIs (UserDefaults; the keyboard extension also systemUptime) and must ship a PrivacyInfo.xcprivacy')
            plistlib.loads(archive.read(manifest))
            checked.append(manifest)
        return checked

if __name__ == '__main__':
    try:
        print(json.dumps(verify_ipa(sys.argv[1]), indent=2))
    except (ValueError, KeyError, struct.error) as error:
        raise SystemExit(str(error))
