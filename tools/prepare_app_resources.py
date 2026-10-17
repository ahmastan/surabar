#!/usr/bin/env python3
"""Generate the Quran data the app bundles, into Surabar/Resources/Bundled (Python standard library).

Builds and verifies the Quran database from tools/quran_sources.json and copies each layout's
font and the default translation (QuranEnc.com) beside it. The output folder is ignored by Git: redistribution of
these assets is still under review. Xcode bundles whatever is in the folder; without it the
app builds and explains that the data is missing.
"""

import argparse
import json
from pathlib import Path
import shutil
import sys

import build_quran_db

TOOLS = Path(__file__).resolve().parent
DEFAULT_OUTPUT = TOOLS.parent / "Surabar" / "Resources" / "Bundled"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, default=TOOLS / "quran_sources.json")
    parser.add_argument("--raw", type=Path, default=TOOLS / "data" / "raw")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    raw = args.raw.resolve()
    layouts = sorted(manifest["layouts"])
    args.output.mkdir(parents=True, exist_ok=True)

    errors = build_quran_db.build(args.manifest, raw, args.output / "quran.sqlite", layouts, allow_unverified=False)
    try:
        for layout in layouts:
            font = manifest["layouts"][layout]["font"]
            source = build_quran_db.resolve(font, raw, f"{layout} font")
            # The database records the font by file name; keep names distinct per layout.
            shutil.copyfile(source, args.output / Path(font["path"]).name)
        # The default translation: QuranEnc's SQLite file, unmodified, with what the app shows about it.
        key, translation = next(iter(manifest["translations"].items()))
        source = build_quran_db.resolve(translation, raw, "translation")
        shutil.copyfile(source, args.output / "translation.sqlite")
        info = {field: translation[field] for field in
                ("source", "title", "display_name", "description", "language", "direction", "version", "last_update")}
        (args.output / "translation.json").write_text(json.dumps({"key": key, **info}, ensure_ascii=False, indent=2) + "\n",
                                                      encoding="utf-8")
        stale = args.output / "translation-en-sahih.json"
        if stale.exists():
            stale.unlink()
    except build_quran_db.SourceError as error:
        errors.append(str(error))
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"prepared {args.output}")
    for path in sorted(args.output.iterdir()):
        print(f"  {path.name} ({path.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
