#!/usr/bin/env python3
"""Inspect local source downloads without changing them (Python standard library)."""

import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import sys


def inspect_file(path: Path, root: Path) -> dict:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        header = source.read(16)
        digest.update(header)
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    result = {
        "path": path.relative_to(root).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": digest.hexdigest(),
    }
    if header == b"SQLite format 3\x00":
        connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
        try:
            connection.execute("PRAGMA query_only = ON")
            connection.execute("PRAGMA trusted_schema = OFF")
            tables = []
            for (name,) in connection.execute(
                "SELECT name FROM sqlite_schema "
                "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            ):
                # Identifiers cannot be bound as parameters; quote embedded quotes.
                quoted = '"' + name.replace('"', '""') + '"'
                columns = connection.execute(f"PRAGMA table_info({quoted})").fetchall()
                tables.append({
                    "name": name,
                    "columns": [{"name": column[1], "type": column[2]} for column in columns],
                })
            result.update(format="sqlite", tables=tables)
        finally:
            connection.close()
    elif path.suffix.lower() == ".json":
        with path.open(encoding="utf-8-sig") as source:
            value = json.load(source)
        result.update(format="json", root_type=type(value).__name__)
        if isinstance(value, (dict, list)):
            result["entries"] = len(value)
        if isinstance(value, dict):
            result["sample_keys"] = list(value)[:8]
        elif isinstance(value, list) and value and isinstance(value[0], dict):
            result["first_entry_fields"] = list(value[0])
    else:
        result["format"] = path.suffix.lower().lstrip(".") or "unknown"
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path,
                        default=Path(__file__).resolve().parent / "data" / "raw")
    args = parser.parse_args()
    root = args.directory.resolve()
    if not root.is_dir():
        print(f"Source directory does not exist: {root}", file=sys.stderr)
        return 1
    paths = sorted(path for path in root.rglob("*")
                   if path.is_file() and not path.is_symlink() and path.name != ".DS_Store")
    if not paths:
        print(f"No source files found in {root}", file=sys.stderr)
        return 1
    reports = []
    failed = False
    for path in paths:
        try:
            reports.append(inspect_file(path, root))
        except (OSError, ValueError, sqlite3.Error) as error:
            failed = True
            reports.append({"path": path.relative_to(root).as_posix(), "error": str(error)})
    print(json.dumps({"files": reports}, ensure_ascii=False, indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
