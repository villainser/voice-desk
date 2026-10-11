#!/usr/bin/env python3
"""Check native strings catalogs, literal L calls, and format placeholders."""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STRING = r'"(?:[^"\\]|\\.)*"'
ENTRY = re.compile(rf'({STRING})\s*=\s*({STRING})\s*;')
CALL = re.compile(rf'(?:\b(?:L|ImportFailure|AppFailure|run)\(\s*|\blimitMessage:\s*|\b(?:status|connection|detail)\s*=\s*)({STRING})')
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+#0 ]*\d*(?:\.\d+)?(?:hh|ll|[hljztL])?([@diuoxXfFeEgGaAcCsSp])')


def decode(value):
    return json.loads(value)


def placeholders(value):
    # Ignore literal percent signs before checking arguments by index and type.
    return sorted((int(index) if index else offset, kind) for offset, (index, kind) in
                  enumerate(FORMAT.findall(value.replace('%%', '')), start=1))


def read_catalog(language, table='Localizable'):
    path = ROOT / 'Resources' / f'{language}.lproj' / f'{table}.strings'
    contents = path.read_text(encoding='utf-8')
    entries = {}
    for match in ENTRY.finditer(contents):
        key, value = map(decode, match.groups())
        if key in entries:
            raise ValueError(f'{path.relative_to(ROOT)}: duplicate key {key!r}')
        entries[key] = value
    return entries


def main():
    errors = []
    catalogs = {language: read_catalog(language) for language in ('en', 'pl')}
    english = catalogs['en']
    for language, catalog in catalogs.items():
        for key in sorted(english.keys() - catalog.keys()):
            errors.append(f'{language}: missing {key!r}')
        for key in sorted(catalog.keys() - english.keys()):
            errors.append(f'{language}: unexpected {key!r}')
        for key, value in catalog.items():
            if placeholders(key) != placeholders(value):
                errors.append(f'{language}: format placeholders differ for {key!r}')
    permission_keys = {'NSMicrophoneUsageDescription'}
    for language in ('en', 'pl'):
        permissions = read_catalog(language, 'InfoPlist')
        if permissions.keys() != permission_keys or not all(permissions.values()):
            errors.append(f'{language}: localized microphone purpose text is missing or invalid')
    references = set()
    for source in sorted((ROOT / 'Sources').glob('*.swift')):
        for match in CALL.finditer(source.read_text(encoding='utf-8')):
            literal = match.group(1)
            if '\\(' in literal:
                errors.append(f'{source.name}: use a format placeholder instead of interpolation: {literal}')
                continue
            key = decode(literal)
            if not key:
                continue
            references.add(key)
            if key not in english:
                errors.append(f'{source.name}: missing catalog entry {key!r}')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'PASS: {len(english)} matching English/Polish entries; {len(references)} literal source keys; format placeholders and permission catalogs valid')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
