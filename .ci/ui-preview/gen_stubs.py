#!/usr/bin/env python3
"""UI preview: C stubs for every function the Swift frontend calls through its bridging header.

Each stub returns an empty/zero value; v3k_pref_path returns Documents/vita/ in the app's sandbox so
the home screen finds the fake games the preview app writes there.
Usage: gen_stubs.py header.h... > stubs.c
"""
import re
import sys

proto = re.compile(r'^\s*([A-Za-z_][\w\s\*]*?[\s\*])(v3k_\w+)\s*\(([^;]*)\)\s*;')
out = ['#include <stdbool.h>', '#include <stdint.h>', '#include <stdlib.h>', '#include <string.h>', '#include <stdio.h>',
       'typedef void (*v3k_progress_fn)(void *context, float percent);',
       'typedef void (*v3k_n3ds_event_fn)(void *context, int kind, int a, int b, const char *text);', '']
seen = set()
for header in sys.argv[1:]:
    # prototypes split over several lines (after a comma) are joined first
    text = re.sub(r',[ \t]*\n[ \t]*', ', ', open(header).read())
    for line in text.split('\n'):
        m = proto.match(line)
        if not m:
            continue
        ret, name, args = m.group(1).strip(), m.group(2), m.group(3).strip()
        if name in seen:
            continue
        seen.add(name)
        if name == 'v3k_pref_path':
            body = ('char buf[1024]; snprintf(buf, sizeof buf, "%s/Documents/vita/", getenv("HOME")); '
                    'return strdup(buf);')
        elif ret == 'void':
            body = ''
        elif ret.replace(' ', '') == 'constchar*':
            body = 'return "";'
        elif ret.replace(' ', '') == 'char*':
            body = 'return strdup("");'
        elif ret.endswith('*'):
            body = 'return 0;'
        elif ret == 'bool':
            body = 'return false;'
        else:
            body = 'return 0;'
        out.append(f'{ret} {name}({args}) {{ {body} }}')
print('\n'.join(out))
