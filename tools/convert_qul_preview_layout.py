#!/usr/bin/env python3
"""Convert saved QUL mushaf layout preview pages into a layout SQLite export (standard library).

QUL publishes some layouts only as web previews (for example the Unicode KFGQPC 1421H layout,
https://qul.tarteel.ai/mushaf_layouts/27?page_number=N). This reads one saved HTML file per page
(p1.html, p2.html, ...) and writes the same `pages` table that QUL's downloadable layout exports
use, with word IDs looked up by location in the matching word export. Text is not copied.

Pages listed with --patch-pages are taken from another layout export (--patch-from) instead,
for preview pages with known defects, such as missing words or words moved between adjacent
lines. A patched page must start and end with the same words as its preview page.
"""

import argparse
import html
from pathlib import Path
import re
import sqlite3
import sys

LINE = re.compile(r'<div class="line-container" data-line="(\d+)">')
LINE_CLASS = re.compile(r'<div class="line([^"]*)"')
WORD = re.compile(r'data-location="(\d+:\d+:\d+)"')
SURAH = re.compile(r"surah(\d{3})")


class PreviewError(Exception):
    """A preview page is missing or not in the expected shape."""


def parse_page(text: str, page: int, word_ids: dict) -> list:
    """Returns (line, type, centered, first_word, last_word, surah) rows for one page."""
    marker = f'id="page-{page}"'
    if marker not in text:
        raise PreviewError(f"page {page}: no {marker} element")
    parts = LINE.split(text[text.index(marker):])[1:]
    rows = []
    for number, chunk in zip(parts[0::2], parts[1::2]):
        found = LINE_CLASS.search(chunk)
        if not found:
            raise PreviewError(f"page {page} line {number}: no line element")
        classes = found.group(1).split()
        centered = 1 if "line--center" in classes else 0
        heading = "line--surah-name" in classes or "line--bismillah" in classes
        if heading and WORD.search(chunk):
            raise PreviewError(f"page {page} line {number}: heading line contains words")
        if "line--surah-name" in classes:
            surah = SURAH.search(chunk)
            if not surah:
                raise PreviewError(f"page {page} line {number}: surah title without a surah number")
            rows.append([int(number), "surah_name", centered, None, None, int(surah.group(1))])
        elif "line--bismillah" in classes:
            rows.append([int(number), "basmallah", centered, None, None, None])
        else:
            locations = WORD.findall(chunk)
            ids = []
            for location in locations:
                if location not in word_ids:
                    raise PreviewError(f"page {page} line {number}: unknown word location {location}")
                ids.append(word_ids[location])
            if ids and ids != list(range(ids[0], ids[0] + len(ids))):
                raise PreviewError(f"page {page} line {number}: word IDs are not consecutive")
            rows.append([int(number), "ayah", centered, ids[0] if ids else None, ids[-1] if ids else None, None])
    # Previews pad short pages with empty lines at the end; any other empty line is an error.
    while rows and rows[-1][1] == "ayah" and rows[-1][3] is None:
        rows.pop()
    for row in rows:
        if row[1] == "ayah" and row[3] is None:
            raise PreviewError(f"page {page} line {row[0]}: empty line before the end of the page")
    if [row[0] for row in rows] != list(range(1, len(rows) + 1)):
        raise PreviewError(f"page {page}: line numbers are not consecutive")
    ayah_rows = [row for row in rows if row[1] == "ayah"]
    for before, after in zip(ayah_rows, ayah_rows[1:]):
        if after[3] != before[4] + 1:
            raise PreviewError(f"page {page} line {after[0]}: starts at word {after[3]} after word {before[4]}")
    return rows


def read_patch(patch_from: Path, pages: set) -> dict:
    connection = sqlite3.connect(patch_from.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        rows = connection.execute(
            "SELECT page_number, line_number, line_type, is_centered, first_word_id, last_word_id, surah_number "
            "FROM pages ORDER BY page_number, line_number").fetchall()
    finally:
        connection.close()
    patch = {}
    for page, *row in rows:
        if page in pages:
            patch.setdefault(page, []).append([None if value == "" else value for value in row])
    missing = sorted(pages - set(patch))
    if missing:
        raise PreviewError(f"patch layout has no page {missing[0]}")
    return patch


def word_span(rows: list) -> tuple:
    ids = [row[3] for row in rows if row[1] == "ayah"] + [row[4] for row in rows if row[1] == "ayah"]
    return min(ids), max(ids)


def convert(pages_dir: Path, words_db: Path, output: Path, page_count: int, name: str,
            patch_from: Path = None, patch_pages: set = frozenset()) -> None:
    connection = sqlite3.connect(words_db.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        word_ids = dict(connection.execute("SELECT location, id FROM words"))
    finally:
        connection.close()
    patch = read_patch(patch_from, set(patch_pages)) if patch_pages else {}
    rows = []
    last_word = 0
    for page in range(1, page_count + 1):
        path = pages_dir / f"p{page}.html"
        if not path.is_file():
            raise PreviewError(f"missing {path}")
        text = html.unescape(path.read_text(encoding="utf-8"))
        if page in patch:
            # A defective preview's first and last words still bound the page.
            locations = WORD.findall(text[text.index(f'id="page-{page}"'):])
            expected = (word_ids[locations[0]], word_ids[locations[-1]])
            if word_span(patch[page]) != expected:
                raise PreviewError(f"page {page}: patch covers words {word_span(patch[page])}, preview {expected}")
            page_rows = patch[page]
        else:
            page_rows = parse_page(text, page, word_ids)
        words = [row for row in page_rows if row[1] == "ayah"]
        if words and rows and words[0][3] != last_word + 1:
            raise PreviewError(f"page {page}: starts at word {words[0][3]} after word {last_word}")
        if words:
            last_word = words[-1][4]
        for row in page_rows:
            rows.append((page, *row))
    output.unlink(missing_ok=True)
    connection = sqlite3.connect(output)
    try:
        connection.executescript("""
            CREATE TABLE info (name TEXT, number_of_pages INTEGER, lines_per_page INTEGER, font_name TEXT);
            CREATE TABLE pages (page_number INTEGER, line_number INTEGER, line_type TEXT, is_centered INTEGER,
                                first_word_id INTEGER, last_word_id INTEGER, surah_number INTEGER);
        """)
        with connection:
            connection.execute("INSERT INTO info VALUES (?, ?, 15, NULL)", (name, page_count))
            connection.executemany("INSERT INTO pages VALUES (?, ?, ?, ?, ?, ?, ?)", rows)
        connection.execute("VACUUM")
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pages", type=Path, required=True, help="directory of p1.html … pN.html")
    parser.add_argument("--words", type=Path, required=True, help="matching QUL word export (SQLite)")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--page-count", type=int, required=True)
    parser.add_argument("--name", required=True, help="layout name stored in the info table")
    parser.add_argument("--patch-from", type=Path, help="layout export supplying --patch-pages")
    parser.add_argument("--patch-pages", default="", help="comma-separated pages with defective previews")
    args = parser.parse_args()
    patch_pages = {int(p) for p in args.patch_pages.split(",") if p.strip()}
    if patch_pages and not args.patch_from:
        parser.error("--patch-pages requires --patch-from")
    try:
        convert(args.pages, args.words, args.output, args.page_count, args.name, args.patch_from, patch_pages)
    except (PreviewError, OSError, sqlite3.Error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
