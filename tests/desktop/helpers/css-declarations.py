#!/usr/bin/env python3
"""Prints the declarations of a stylesheet, one per line, for a diff.

    css-declarations.py FILE

Each line is `SELECTOR | PROPERTY: VALUE`, in the order of the file, with the
comments cut out and the white space of selectors and values collapsed. A hex
color #rrggbb in a value is written as rgb(R G B), the form the generated
stylesheet uses, so the Fedora stylesheet (all hex) and ravnix's (no hex) can
be compared color for color. A file that holds anything but plain rules (an
@-rule, a block that does not close, a declaration without a colon) is an
error, so a broken stylesheet cannot compare equal by saying nothing.
"""
import re
import sys


def rgb(match):
    h = match.group(1)
    return 'rgb(%d %d %d)' % (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def main():
    text = open(sys.argv[1], encoding='utf-8').read()
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    if '/*' in text or '*/' in text:
        sys.exit(f'{sys.argv[1]}: a comment does not close')
    pos = 0
    rules = re.compile(r'\s*([^{}]+?)\s*\{([^{}]*)\}', re.S)
    while True:
        m = rules.match(text, pos)
        if not m:
            break
        selector = ' '.join(m.group(1).split())
        if selector.startswith('@'):
            sys.exit(f'{sys.argv[1]}: an @-rule: {selector}')
        for decl in m.group(2).split(';'):
            decl = ' '.join(decl.split())
            if not decl:
                continue
            if ':' not in decl:
                sys.exit(f'{sys.argv[1]}: no declaration: {decl}')
            prop, value = (s.strip() for s in decl.split(':', 1))
            value = re.sub(r'#([0-9a-fA-F]{6})\b', rgb, value)
            print(f'{selector} | {prop}: {value}')
        pos = m.end()
    if text[pos:].strip():
        sys.exit(f'{sys.argv[1]}: cannot read from: {text[pos:pos + 60]!r}')


if __name__ == '__main__':
    main()
