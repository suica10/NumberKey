"""Check strong Mach-O dylib dependencies inside the actual packaged IPA."""
from pathlib import PurePosixPath
import json
import plistlib
import posixpath
import struct
import sys
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
        return {'executables': roots, 'bundledDependencies': checked, 'status': 'passed'}

if __name__ == '__main__':
    try:
        print(json.dumps(verify_ipa(sys.argv[1]), indent=2))
    except (ValueError, KeyError, struct.error) as error:
        raise SystemExit(str(error))
