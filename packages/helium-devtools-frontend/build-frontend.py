#!/usr/bin/python3 -I
"""Build a themed copy of Helium's own DevTools frontend.

Usage: build-frontend.py <helium binary> <resources.pak> <output dir>

Helium (Chromium) bundles the DevTools frontend in resources.pak and serves it
as devtools://devtools/bundled/<path>. The pak holds only numeric resource ids;
the path -> id table is compiled into the binary as an array of
{const char *path; uint16 id; ...} records, 32 bytes each, whose path
pointers are RELATIVE relocations. This script reads that table, extracts
every file, links the theme files from this directory into each HTML entry
point, and writes <output dir>/.complete last. Helium's wrapper passes the
result to Helium as --custom-devtools-frontend (packages/helium).

It is the packaged Helium's own frontend, so it always matches the browser
version. Only the three theme files are ours.
"""
import gzip
import os
import shutil
import struct
import sys
import tempfile

import brotli

HERE = os.path.dirname(os.path.realpath(__file__))
THEME_FILES = ('catppuccin-mocha.css', 'square-shadow-roots.js')
ANCHOR = b'entrypoints/devtools_app/devtools_app.js\0'
STRIDE = 32


def resource_table(binary):
    """Return [(path, id)] of the DevTools resource map in the binary."""
    shoff, = struct.unpack_from('<Q', binary, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', binary, 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', binary, shoff + i * shentsize)
            for i in range(shnum)]
    names = secs[shstrndx][4]

    def name(sec):
        start = names + sec[0]
        return binary[start:binary.index(b'\0', start)].decode()

    by_name = {name(s): s for s in secs}

    def v2o(vaddr):
        for s in secs:  # skip NOBITS (type 8), it has no file bytes
            if s[1] != 8 and s[3] and s[3] <= vaddr < s[3] + s[5]:
                return vaddr - s[3] + s[4]
        raise ValueError(hex(vaddr))

    rela = by_name['.rela.dyn']
    reloc = {}
    for off, info, addend in struct.iter_unpack(
            '<QQq', binary[rela[4]:rela[4] + rela[5]]):
        if info & 0xffffffff == 8:  # R_X86_64_RELATIVE
            reloc[off] = addend

    anchor = binary.index(ANCHOR)
    slots = [o for o, a in reloc.items() if a == anchor]
    if len(slots) != 1:
        raise SystemExit(f'expected one table slot for the anchor, got {len(slots)}')

    def entry(slot):
        if slot not in reloc:
            return None
        try:
            start = v2o(reloc[slot])
            path = binary[start:binary.index(b'\0', start)].decode()
        except (ValueError, UnicodeDecodeError):
            return None
        if not path or path.startswith('/') or '..' in path.split('/'):
            return None
        rid, = struct.unpack_from('<H', binary, v2o(slot) + 8)
        return path, rid

    lo = hi = slots[0]
    while entry(lo - STRIDE):
        lo -= STRIDE
    while entry(hi + STRIDE):
        hi += STRIDE
    return [entry(s) for s in range(lo, hi + STRIDE, STRIDE)]


def pak_resources(pak):
    version, = struct.unpack_from('<I', pak, 0)
    if version != 5:
        raise SystemExit(f'unsupported pak version {version}')
    count, = struct.unpack_from('<H', pak, 8)
    table = [struct.unpack_from('<HI', pak, 12 + 6 * i) for i in range(count + 1)]
    return {table[i][0]: (table[i][1], table[i + 1][1]) for i in range(count)}


def decode(blob):
    if blob[:2] == b'\x1e\x9b':  # Chromium brotli header: magic + 6-byte size
        return brotli.decompress(blob[8:])
    if blob[:2] == b'\x1f\x8b':
        return gzip.decompress(blob)
    return blob


def inject(html):
    # The script goes before the app's module script, so it patches the
    # prototypes before any component exists. The stylesheet goes in front of
    # <body>, after the two token stylesheets.
    script = b'<script type="module" src="./square-shadow-roots.js"></script>\n'
    sheet = b'<link href="./catppuccin-mocha.css" rel="stylesheet">\n'
    pos = html.find(b'<script type="module"')
    if pos < 0:
        return None
    html = html[:pos] + script + html[pos:]
    pos = html.find(b'<body')
    if pos < 0:
        return None
    return html[:pos] + sheet + html[pos:]


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    helium, pak_path = sys.argv[1], sys.argv[2]
    out = os.path.abspath(sys.argv[3])
    parent = os.path.dirname(out)
    os.makedirs(parent, exist_ok=True)

    binary = open(helium, 'rb').read()
    entries = resource_table(binary)
    del binary
    paths = {p for p, _ in entries}
    if len(entries) < 500 or 'devtools_app.html' not in paths:
        raise SystemExit(f'resource table looks wrong: {len(entries)} entries')

    pak = open(pak_path, 'rb').read()
    index = pak_resources(pak)
    tmp = tempfile.mkdtemp(prefix='.build-', dir=parent)
    try:
        injected = 0
        for path, rid in entries:
            start, end = index[rid]
            if end > len(pak):  # a slice past the end would be a short file
                raise SystemExit(f'{path}: resource {rid} runs past the end of the pak')
            data = decode(pak[start:end])
            if path.endswith('.html'):
                themed = inject(data)
                if themed is not None:
                    data, injected = themed, injected + 1
            dest = os.path.join(tmp, path)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, 'wb') as f:
                f.write(data)
        if not injected:
            raise SystemExit('no HTML entry point took the theme links')
        for name in THEME_FILES:  # symlinks into the theme's store path
            os.symlink(os.path.join(HERE, name), os.path.join(tmp, name))
        with open(os.path.join(tmp, '.complete'), 'w') as f:
            f.write(f'{len(entries)} files, {injected} entry points themed\n')
        os.chmod(tmp, 0o755)
        try:
            os.rename(tmp, out)
        except OSError:  # a parallel launch finished first
            if not os.path.exists(os.path.join(out, '.complete')):
                raise
            shutil.rmtree(tmp, ignore_errors=True)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    print(f'{out}: {len(entries)} files, {injected} entry points themed')


if __name__ == '__main__':
    main()
