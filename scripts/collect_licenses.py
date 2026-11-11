"""Bundle upstream notices, including dictionary and transitive package licenses."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SEARCH = [ROOT / 'Vendor', ROOT / '.build/checkouts', ROOT / 'build/SourcePackages/checkouts']
chunks = [
    'NumberKey uses AzooKeyKanaKanjiConverter and its bundled dictionaries.\n'
    'Converter revision: 5a9c4f672f627c8db48241a3abc22409257f92cb\n'
    'Source: https://github.com/azooKey/AzooKeyKanaKanjiConverter\n'
]
count = 0
for folder in SEARCH:
    if not folder.exists():
        continue
    for path in sorted(folder.rglob('*')):
        if not path.is_file() or '.git' in path.parts:
            continue
        name = path.name.upper()
        if name.startswith(('LICENSE', 'LICENCE', 'COPYING', 'NOTICE', 'AUTHORS', 'COPYRIGHT')):
            text = path.read_text(encoding='utf-8', errors='replace')
            chunks.append(f'\n{"=" * 70}\n{path.relative_to(ROOT).as_posix()}\n{"=" * 70}\n{text}\n')
            count += 1
if count == 0:
    raise SystemExit('No upstream license files found; run bootstrap first.')
(ROOT / 'App/ThirdPartyNotices.txt').write_text('\n'.join(chunks), encoding='utf-8')
print(f'Bundled {count} upstream notices.')
