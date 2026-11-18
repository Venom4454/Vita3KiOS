#!/usr/bin/env python3
"""Lists the menu text in vita3k/ios/ui that a language has no translation for yet.

Usage: missing.py [language]   (es, fr, de, it, pt-BR, zh-Hans, ja; all when omitted)

The keys are the English text itself: SwiftUI literals (Text("..."), Button("..."), Toggle("..."), ...)
and L("...") for UIKit menus and titles kept in data. Text with an interpolation (\\(...)) isn't
covered. Add a missing line to <language>.lproj/Localizable.strings as "English" = "Translation";
"""
import pathlib
import re
import sys

here = pathlib.Path(__file__).resolve().parent
ui = here.parent / "ui"
lit = r'"((?:[^"\\\n]|\\.)*)"'
patterns = [
    r'\b(?:Text|Button|Toggle|Label|Section|Picker|LabeledContent|TextField|SecureField|Link|Menu|NavigationLink|'
    r'ContentUnavailableView|GroupBox|DisclosureGroup|Stepper|L|SettingsForm)\(\s*' + lit,
    r'\.(?:navigationTitle|alert|confirmationDialog|help)\(\s*' + lit,
    r'Group\(title: ' + lit,
    r'\bpage\("[^"]*", ' + lit, r'\bpage\("[^"]*", "(?:[^"\\]|\\.)*", ' + lit,
    r'\bdescribed\(' + lit, r'\bdescribed\("(?:[^"\\]|\\.)*", ' + lit,
    r'\("[a-z0-9-]+", ' + lit + r'\)',
]
keys = {}
for source in sorted(ui.glob("*.swift")):
    text = source.read_text()
    for pattern in patterns:
        for match in re.finditer(pattern, text):
            key = match.group(1)
            if "\\(" not in key and re.search("[A-Za-z]", key):
                keys.setdefault(key, source.name)

languages = sys.argv[1:] or sorted(p.name[:-6] for p in here.glob("*.lproj") if p.name != "en.lproj")
for language in languages:
    strings = (here / f"{language}.lproj" / "Localizable.strings").read_text()
    done = set(re.findall(r'^"((?:[^"\\]|\\.)*)" = ', strings, re.M))
    missing = [(key, where) for key, where in keys.items() if key not in done]
    print(f"{language}: {len(missing)} of {len(keys)} untranslated")
    for key, where in missing:
        print(f"  {where}: {key[:100]}")
