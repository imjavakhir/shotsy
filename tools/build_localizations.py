#!/usr/bin/env python3
"""Builds the String Catalogs from per-language translation JSON files.

Inputs (in a folder passed as argv[1]):
  all_keys.json         English source strings (the keys)
  tr_<lang>.json        {key: "translation" | {"one": ..., "few": ..., "many": ..., "other": ...}}
  tr_en_plurals.json    {key: {"one": ..., "other": ...}} English plural forms
  infoplist.json        {InfoPlistKey: English value}

Outputs:
  Shotsy/Resources/Localizable.xcstrings
  Shotsy/Resources/InfoPlist.xcstrings

Validates that every translation keeps the same placeholders as its English key.
Usage: python3 tools/build_localizations.py <translations-folder>
"""
import collections
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = ["ru", "es", "pt-BR", "fr", "de", "it", "ja", "ko", "zh-Hans", "zh-Hant", "id", "vi"]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|%)")


def placeholders(s):
    return collections.Counter(re.sub(r"\d+\$", "", p) for p in PLACEHOLDER.findall(s))


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def localization(value):
    if isinstance(value, dict):
        forms = {k: unit(v) for k, v in value.items() if k in ("zero", "one", "two", "few", "many", "other")}
        if list(forms) == ["other"]:
            return unit(value["other"])
        return {"variations": {"plural": forms}}
    return unit(value)


def main(folder):
    keys = json.load(open(os.path.join(folder, "all_keys.json")))
    translations = {lang: json.load(open(os.path.join(folder, "tr_%s.json" % lang))) for lang in LANGS}
    en_plurals = json.load(open(os.path.join(folder, "tr_en_plurals.json")))
    problems = []

    strings = {}
    for key in keys:
        entry = {"localizations": {}}
        if key in en_plurals:
            entry["localizations"]["en"] = localization(en_plurals[key])
        for lang in LANGS:
            value = translations[lang].get(key)
            if value is None:
                problems.append("%s missing: %r" % (lang, key))
                continue
            forms = value.values() if isinstance(value, dict) else [value]
            for form in forms:
                if placeholders(form) != placeholders(key):
                    problems.append("%s placeholder mismatch: %r -> %r" % (lang, key, form))
            entry["localizations"][lang] = localization(value)
        strings[key] = entry

    if problems:
        print("\n".join(problems[:50]))
        print("%d problems" % len(problems))
        sys.exit(1)

    def write(path, table):
        with open(os.path.join(ROOT, path), "w") as f:
            json.dump({"sourceLanguage": "en", "strings": table, "version": "1.0"}, f, ensure_ascii=False, indent=2,
                      sort_keys=True)

    write("Shotsy/Resources/Localizable.xcstrings", strings)

    # Info.plist strings, keyed by Info.plist key.
    info = json.load(open(os.path.join(folder, "infoplist.json")))
    info_table = {}
    for plist_key, english in info.items():
        entry = {"localizations": {}}
        for lang in LANGS:
            value = translations[lang].get(english, english)
            entry["localizations"][lang] = unit(value if isinstance(value, str) else value.get("other", english))
        info_table[plist_key] = entry
    write("Shotsy/Resources/InfoPlist.xcstrings", info_table)

    print("OK: %d keys x %d languages; %d English plurals" % (len(keys), len(LANGS), len(en_plurals)))


if __name__ == "__main__":
    main(sys.argv[1])
