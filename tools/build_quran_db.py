#!/usr/bin/env python3
"""Build and verify Surabar's read-only Quran database (Python standard library).

`build` imports the QUL exports listed in tools/quran_sources.json into a new
SQLite database, then verifies it. `verify` checks an existing database on its
own, without the raw downloads. Source text is copied byte-for-byte; the tool
never normalizes or rewrites Quranic text.

A layout may also have glyph-code words and one font per page (QCF V2). The
page fonts are not bundled: the database lists each file with its size and
SHA-256 so the app can download and check them, and the layout's single font
is the fallback until they are present.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile

SCHEMA_VERSION = 2
SURAH_COUNT = 114
AYAH_COUNT = 6236
# Quran divisions: (manifest key, JSON number field, count).
DIVISIONS = (("juz", "juz_number", 30), ("hizb", "hizb_number", 60), ("rub", "rub_number", 240))
LINE_TYPES = ("ayah", "surah_name", "basmallah")
TOOLS = Path(__file__).resolve().parent

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE surahs (
    number INTEGER PRIMARY KEY,
    name_arabic TEXT NOT NULL,
    name_simple TEXT NOT NULL,
    name_complex TEXT NOT NULL,
    revelation_place TEXT NOT NULL,
    ayah_count INTEGER NOT NULL,
    bismillah_pre INTEGER NOT NULL
);
CREATE TABLE ayahs (
    surah INTEGER NOT NULL REFERENCES surahs(number),
    ayah INTEGER NOT NULL,
    juz INTEGER NOT NULL,
    hizb INTEGER NOT NULL,
    rub INTEGER NOT NULL,
    PRIMARY KEY (surah, ayah)
) WITHOUT ROWID;
CREATE TABLE layouts (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    page_count INTEGER NOT NULL,
    lines_per_page INTEGER NOT NULL,
    verified INTEGER NOT NULL,
    font_file TEXT NOT NULL,
    font_sha256 TEXT NOT NULL,
    font_calibration REAL,
    page_font_url TEXT,
    page_font_calibration REAL,
    page_font_line_height REAL,
    page_font_ascent REAL
) WITHOUT ROWID;
CREATE TABLE words (
    layout TEXT NOT NULL REFERENCES layouts(id),
    word INTEGER NOT NULL,
    surah INTEGER NOT NULL,
    ayah INTEGER NOT NULL,
    position INTEGER NOT NULL,
    text TEXT NOT NULL,
    glyph TEXT,
    PRIMARY KEY (layout, word),
    FOREIGN KEY (surah, ayah) REFERENCES ayahs(surah, ayah)
) WITHOUT ROWID;
CREATE TABLE lines (
    layout TEXT NOT NULL REFERENCES layouts(id),
    page INTEGER NOT NULL,
    line INTEGER NOT NULL,
    type TEXT NOT NULL,
    centered INTEGER NOT NULL,
    first_word INTEGER,
    last_word INTEGER,
    surah INTEGER REFERENCES surahs(number),
    PRIMARY KEY (layout, page, line)
) WITHOUT ROWID;
CREATE TABLE ayah_pages (
    layout TEXT NOT NULL REFERENCES layouts(id),
    surah INTEGER NOT NULL,
    ayah INTEGER NOT NULL,
    page INTEGER NOT NULL,
    PRIMARY KEY (layout, surah, ayah, page)
) WITHOUT ROWID;
CREATE TABLE page_fonts (
    layout TEXT NOT NULL REFERENCES layouts(id),
    page INTEGER NOT NULL,
    file TEXT NOT NULL,
    bytes INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    PRIMARY KEY (layout, page)
) WITHOUT ROWID;
CREATE INDEX words_by_ayah ON words (layout, surah, ayah);
CREATE INDEX ayah_pages_by_page ON ayah_pages (layout, page);
"""

# Tables and key order used for the logical content digest.
DIGEST_TABLES = (
    ("surahs", "number"),
    ("ayahs", "surah, ayah"),
    ("layouts", "id"),
    ("words", "layout, word"),
    ("lines", "layout, page, line"),
    ("ayah_pages", "layout, surah, ayah, page"),
    ("page_fonts", "layout, page"),
)


class SourceError(Exception):
    """A source file is missing, mismatched, or not in the documented shape."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve(entry: dict, raw: Path, label: str) -> Path:
    if not entry.get("path"):
        raise SourceError(f"{label}: no path recorded in the manifest (download {entry.get('url')})")
    path = raw / entry["path"]
    if not path.is_file():
        raise SourceError(f"{label}: file not found: {path}")
    expected = entry.get("sha256")
    if not expected:
        raise SourceError(f"{label}: no sha256 recorded in the manifest for {entry['path']}")
    actual = sha256(path)
    if actual != expected:
        raise SourceError(f"{label}: sha256 mismatch for {entry['path']}: {actual} != {expected}")
    return path


def field(record: dict, label: str, *names):
    for name in names:
        if name in record:
            return record[name]
    raise SourceError(f"{label}: none of the fields {names} present; found {sorted(record)}")


def records(value, label: str) -> list:
    if isinstance(value, dict):
        return list(value.values())
    if isinstance(value, list):
        return value
    raise SourceError(f"{label}: expected a JSON object or array, found {type(value).__name__}")


def load_json(path: Path):
    with path.open(encoding="utf-8-sig") as source:
        return json.load(source)


def open_source_db(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    connection.execute("PRAGMA query_only = ON")
    connection.execute("PRAGMA trusted_schema = OFF")
    return connection


def columns_of(connection: sqlite3.Connection, table: str, label: str) -> list:
    columns = [row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')]
    if not columns:
        tables = [row[0] for row in connection.execute(
            "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")]
        raise SourceError(f"{label}: table {table!r} not found; tables are {tables}")
    return columns


def pick(columns: list, label: str, *names) -> str:
    for name in names:
        if name in columns:
            return name
    raise SourceError(f"{label}: none of the columns {names} present; found {columns}")


def read_surahs(path: Path) -> list:
    rows = []
    for record in records(load_json(path), "surahs"):
        label = f"surahs[{record.get('id')}]"
        bismillah = field(record, label, "bismillah_pre")
        rows.append((
            int(field(record, label, "id", "surah_number")),
            str(field(record, label, "name_arabic")),
            str(field(record, label, "name_simple")),
            str(field(record, label, "name", "name_complex")),
            str(field(record, label, "revelation_place")),
            int(field(record, label, "verses_count", "ayah_count")),
            1 if bismillah in (True, 1, "true", "1") else 0,
        ))
    return sorted(rows)


def read_ayahs(path: Path) -> list:
    rows = []
    for record in records(load_json(path), "ayahs"):
        label = f"ayahs[{record.get('id')}]"
        rows.append((int(field(record, label, "surah_number")),
                     int(field(record, label, "ayah_number"))))
    return sorted(rows)


def read_division(path: Path, name: str, number_field: str) -> dict:
    """Maps (surah, ayah) to a juz, hizb, or rub number using its verse_mapping ranges."""
    division = {}
    for record in records(load_json(path), name):
        label = f"{name}[{record.get(number_field)}]"
        number = int(field(record, label, number_field))
        for surah, span in field(record, label, "verse_mapping").items():
            first, _, last = str(span).partition("-")
            for ayah in range(int(first), int(last or first) + 1):
                key = (int(surah), ayah)
                if key in division:
                    raise SourceError(f"{label}: {surah}:{ayah} is also in {name} {division[key]}")
                division[key] = number
    return division


def read_words(path: Path, layout: str) -> list:
    label = f"{layout} words"
    connection = open_source_db(path)
    try:
        columns = columns_of(connection, "words", label)
        index = pick(columns, label, "word_index", "id")
        key = pick(columns, label, "word_key", "location")
        surah = pick(columns, label, "surah")
        ayah = pick(columns, label, "ayah")
        text = pick(columns, label, "text")
        source = connection.execute(
            f'SELECT "{index}", "{key}", "{surah}", "{ayah}", "{text}" FROM words ORDER BY "{index}"'
        ).fetchall()
    finally:
        connection.close()
    rows = []
    positions = {}
    for word, word_key, surah_number, ayah_number, word_text in source:
        if not isinstance(word_text, str) or not word_text:
            raise SourceError(f"{label}: word {word} has no text")
        parts = str(word_key).split(":")
        if [int(p) for p in parts[:2]] != [int(surah_number), int(ayah_number)]:
            raise SourceError(f"{label}: word {word} key {word_key} disagrees with "
                              f"{surah_number}:{ayah_number}")
        ayah_key = (int(surah_number), int(ayah_number))
        positions[ayah_key] = positions.get(ayah_key, 0) + 1
        position = int(parts[2]) if len(parts) == 3 else positions[ayah_key]
        rows.append((layout, int(word), ayah_key[0], ayah_key[1], position, word_text, None))
    return rows


def add_glyphs(words: list, path: Path, layout: str) -> list:
    """Attaches each word's glyph codes from a glyph-script export with the same word ids and locations."""
    label = f"{layout} glyphs"
    connection = open_source_db(path)
    try:
        columns = columns_of(connection, "words", label)
        index = pick(columns, label, "word_index", "id")
        key = pick(columns, label, "word_key", "location")
        text = pick(columns, label, "text")
        glyphs = {int(word): (str(location), glyph) for word, location, glyph in connection.execute(
            f'SELECT "{index}", "{key}", "{text}" FROM words')}
    finally:
        connection.close()
    if len(glyphs) != len(words):
        raise SourceError(f"{label}: {len(glyphs)} words, but the text has {len(words)}")
    rows = []
    for row in words:
        word, surah, ayah, position = row[1:5]
        location, glyph = glyphs.get(word, (None, None))
        if location is None:
            raise SourceError(f"{label}: word {word} is missing")
        if location != f"{surah}:{ayah}:{position}":
            raise SourceError(f"{label}: word {word} is at {location}, the text has {surah}:{ayah}:{position}")
        if not isinstance(glyph, str) or not glyph or any(ord(c) < 0xF000 and c != " " for c in glyph):
            raise SourceError(f"{label}: word {word} has unexpected glyph codes {glyph!r}")
        rows.append((*row[:6], glyph))
    return rows


def read_page_fonts(spec: dict, raw: Path, layout: str, page_count: int) -> list:
    """Hashes one font file per page and checks the set against the manifest's directory digest."""
    label = f"{layout} page fonts"
    directory = raw / spec["directory"]
    rows, listing = [], []
    for page in range(1, page_count + 1):
        name = spec["file"].format(page=page)
        path = directory / name
        if not path.is_file():
            raise SourceError(f"{label}: missing {path} (download {spec['download'].format(page=page)})")
        digest = sha256(path)
        rows.append((layout, page, name, path.stat().st_size, digest))
        listing.append(f"{name} {digest}\n")
    actual = hashlib.sha256("".join(listing).encode()).hexdigest()
    if actual != spec.get("directory_sha256"):
        raise SourceError(f"{label}: directory digest {actual} != {spec.get('directory_sha256')}")
    return rows


def read_lines(path: Path, layout: str) -> list:
    label = f"{layout} layout"
    connection = open_source_db(path)
    try:
        columns = columns_of(connection, "pages", label)
        wanted = ("page_number", "line_number", "line_type", "is_centered",
                  "first_word_id", "last_word_id", "surah_number")
        missing = [name for name in wanted if name not in columns]
        if missing:
            raise SourceError(f"{label}: missing columns {missing}; found {columns}")
        source = connection.execute(
            "SELECT " + ", ".join(f'"{name}"' for name in wanted) +
            " FROM pages ORDER BY page_number, line_number").fetchall()
    finally:
        connection.close()

    def optional_int(value):
        return None if value in (None, "") else int(value)

    return [(layout, int(page), int(line), str(kind),
             1 if centered in (True, 1, "1", "true", "t") else 0,
             optional_int(first), optional_int(last), optional_int(surah))
            for page, line, kind, centered, first, last, surah in source]


def derive_ayah_pages(words: list, lines: list) -> list:
    word_ayah = {(row[0], row[1]): (row[2], row[3]) for row in words}
    pages = set()
    for layout, page, _, kind, _, first, last, _ in lines:
        if kind != "ayah" or first is None or last is None:
            continue
        for word in range(first, last + 1):
            if (layout, word) in word_ayah:
                pages.add((layout, *word_ayah[(layout, word)], page))
    return sorted(pages)


def content_digest(connection: sqlite3.Connection) -> str:
    digest = hashlib.sha256()
    for table, order in DIGEST_TABLES:
        digest.update(f"[{table}]\n".encode())
        for row in connection.execute(f"SELECT * FROM {table} ORDER BY {order}"):
            digest.update(json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode())
            digest.update(b"\n")
    return digest.hexdigest()


def build(manifest_path: Path, raw: Path, output: Path, layouts: list,
          allow_unverified: bool) -> list:
    manifest = load_json(manifest_path)
    errors = []
    sources = {}

    def need(entry, label):
        try:
            sources[label] = resolve(entry, raw, label)
        except SourceError as error:
            errors.append(str(error))

    need(manifest["metadata"]["surahs"], "surahs")
    need(manifest["metadata"]["ayahs"], "ayahs")
    for name, _, _ in DIVISIONS:
        need(manifest["metadata"][name], name)
    for layout in layouts:
        spec = manifest["layouts"].get(layout)
        if spec is None:
            errors.append(f"unknown layout {layout!r}")
            continue
        if not spec["verified"] and not allow_unverified:
            errors.append(f"{layout}: layout is not verified ({spec['verification_note']}); "
                          "use --allow-unverified only for inspection builds")
        for part in ("words", "layout", "font", "glyphs"):
            if part in spec:
                need(spec[part], f"{layout} {part}")
    if errors:
        return errors

    try:
        surahs = read_surahs(sources["surahs"])
        ayahs = read_ayahs(sources["ayahs"])
        divisions = [read_division(sources[name], name, number_field)
                     for name, number_field, _ in DIVISIONS]
        missing = [f"{name} for {s}:{a}" for (s, a) in ayahs
                   for (name, _, _), division in zip(DIVISIONS, divisions) if (s, a) not in division]
        if missing:
            raise SourceError(f"{len(missing)} ayahs lack a division, first {missing[0]}")
        ayahs = [(s, a, *(division[(s, a)] for division in divisions)) for s, a in ayahs]
        layout_rows, words, lines, page_fonts = [], [], [], []
        for layout in layouts:
            spec = manifest["layouts"][layout]
            font = spec["font"]
            paged = spec.get("page_fonts")
            layout_rows.append((layout, spec["name"], spec["page_count"], spec["lines_per_page"],
                                1 if spec["verified"] else 0, Path(font["path"]).name,
                                font["sha256"], font.get("calibration"),
                                *((paged["download"], paged["calibration"], paged["line_height"],
                                   paged["ascent"]) if paged else (None, None, None, None))))
            layout_words = read_words(sources[f"{layout} words"], layout)
            if f"{layout} glyphs" in sources:
                layout_words = add_glyphs(layout_words, sources[f"{layout} glyphs"], layout)
            words += layout_words
            lines += read_lines(sources[f"{layout} layout"], layout)
            if paged:
                page_fonts += read_page_fonts(paged, raw, layout, spec["page_count"])
    except (SourceError, OSError, ValueError, TypeError, sqlite3.Error) as error:
        return [str(error)]

    output.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=output.parent, suffix=".sqlite.tmp")
    os.close(handle)
    temporary = Path(temporary)
    try:
        connection = sqlite3.connect(temporary)
        try:
            connection.execute("PRAGMA page_size = 4096")
            connection.execute("PRAGMA journal_mode = DELETE")
            connection.executescript(SCHEMA)
            with connection:
                connection.executemany("INSERT INTO surahs VALUES (?, ?, ?, ?, ?, ?, ?)", surahs)
                connection.executemany("INSERT INTO ayahs VALUES (?, ?, ?, ?, ?)", ayahs)
                connection.executemany("INSERT INTO layouts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                                       sorted(layout_rows))
                connection.executemany("INSERT INTO words VALUES (?, ?, ?, ?, ?, ?, ?)", sorted(words))
                connection.executemany("INSERT INTO page_fonts VALUES (?, ?, ?, ?, ?)", sorted(page_fonts))
                connection.executemany("INSERT INTO lines VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                       sorted(lines))
                connection.executemany("INSERT INTO ayah_pages VALUES (?, ?, ?, ?)",
                                       derive_ayah_pages(words, lines))
                meta = {
                    "schema_version": str(SCHEMA_VERSION),
                    "sources": json.dumps(sorted(
                        (label, path.relative_to(raw).as_posix(), sha256(path))
                        for label, path in sources.items()), separators=(",", ":")),
                    "content_sha256": content_digest(connection),
                }
                connection.executemany("INSERT INTO meta VALUES (?, ?)", sorted(meta.items()))
            connection.execute("VACUUM")
        finally:
            connection.close()
        errors = verify(temporary)
        if errors:
            return errors
        temporary.chmod(0o644)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return []


def verify_layout(connection: sqlite3.Connection, layout: str, page_count: int,
                  lines_per_page: int, bismillah_surahs: set, paged: bool) -> list:
    errors = []

    def fail(message):
        errors.append(f"{layout}: {message}")

    fonts = [row[0] for row in connection.execute(
        "SELECT page FROM page_fonts WHERE layout = ? ORDER BY page", (layout,))]
    glyphless = connection.execute(
        "SELECT COUNT(*) FROM words WHERE layout = ? AND (glyph IS NULL OR glyph = '')", (layout,)).fetchone()[0]
    glyphs = connection.execute(
        "SELECT COUNT(*) FROM words WHERE layout = ? AND glyph IS NOT NULL", (layout,)).fetchone()[0]
    if paged:
        if fonts != list(range(1, page_count + 1)):
            fail(f"page fonts are not exactly 1..{page_count} (found {len(fonts)})")
        if glyphless:
            fail(f"{glyphless} words have no glyph codes for the page fonts")
    elif fonts or glyphs:
        fail("has glyph codes or page fonts but no page font settings")

    words = connection.execute(
        "SELECT word, surah, ayah, position FROM words WHERE layout = ? ORDER BY word",
        (layout,)).fetchall()
    if not words:
        return [f"{layout}: no words"]
    word_ayah = {}
    previous = None
    for expected, (word, surah, ayah, position) in enumerate(words, start=1):
        if word != expected:
            fail(f"word indices not contiguous at {expected} (found {word})")
            break
        key = (surah, ayah)
        if previous is not None and key < previous[0]:
            fail(f"word {word} ({surah}:{ayah}) is out of ayah order")
        expected_position = previous[1] + 1 if previous is not None and key == previous[0] else 1
        if position != expected_position:
            fail(f"word {word} ({surah}:{ayah}) has position {position}, "
                 f"expected {expected_position}")
        previous = (key, position)
        word_ayah[word] = key
    missing = connection.execute(
        "SELECT surah, ayah FROM ayahs EXCEPT SELECT surah, ayah FROM words WHERE layout = ?",
        (layout,)).fetchall()
    if missing:
        fail(f"{len(missing)} ayahs have no words, first {missing[0][0]}:{missing[0][1]}")
    unknown = connection.execute(
        "SELECT surah, ayah FROM words WHERE layout = ? EXCEPT SELECT surah, ayah FROM ayahs",
        (layout,)).fetchall()
    if unknown:
        fail(f"words reference {len(unknown)} unknown ayahs, first {unknown[0][0]}:{unknown[0][1]}")

    lines = connection.execute(
        "SELECT page, line, type, first_word, last_word, surah FROM lines "
        "WHERE layout = ? ORDER BY page, line", (layout,)).fetchall()
    pages = sorted({row[0] for row in lines})
    if pages != list(range(1, page_count + 1)):
        fail(f"pages are not exactly 1..{page_count} (found {len(pages)} pages)")
    by_page = {}
    for page, line, *_ in lines:
        by_page.setdefault(page, []).append(line)
    for page, numbers in by_page.items():
        if numbers != list(range(1, len(numbers) + 1)) or len(numbers) > lines_per_page:
            fail(f"page {page} line numbers {numbers} are not 1..n with n <= {lines_per_page}")

    next_word = 1
    surah_names = {}
    basmallahs = set()
    pending_surah = None
    for page, line, kind, first, last, surah in lines:
        where = f"page {page} line {line}"
        if kind not in LINE_TYPES:
            fail(f"{where} has unknown type {kind!r}")
            continue
        if kind == "ayah":
            if first is None or last is None or first > last:
                fail(f"{where} has invalid word range {first}..{last}")
                continue
            if first != next_word:
                fail(f"{where} starts at word {first}, expected {next_word}")
            if pending_surah is not None and word_ayah.get(first) != (pending_surah, 1):
                fail(f"{where}: surah {pending_surah} header is not followed by its first ayah")
            pending_surah = None
            next_word = last + 1
            continue
        if first is not None or last is not None:
            fail(f"{where} ({kind}) unexpectedly has words {first}..{last}")
        if kind == "surah_name":
            if surah is None or not 1 <= surah <= SURAH_COUNT:
                fail(f"{where} has invalid surah {surah}")
                continue
            if surah in surah_names:
                fail(f"surah {surah} has more than one header ({surah_names[surah]} and {where})")
            surah_names[surah] = where
            pending_surah = surah
        else:
            owner = surah if surah is not None else pending_surah
            if owner is None or owner != pending_surah:
                fail(f"{where} basmallah does not follow its surah header")
            elif owner not in bismillah_surahs:
                fail(f"{where} basmallah for surah {owner}, which has none")
            else:
                basmallahs.add(owner)
    if next_word != len(words) + 1:
        fail(f"lines cover words 1..{next_word - 1} of {len(words)}")
    if set(surah_names) != set(range(1, SURAH_COUNT + 1)):
        absent = sorted(set(range(1, SURAH_COUNT + 1)) - set(surah_names))
        fail(f"{len(absent)} surahs have no header line, first {absent[:5]}")
    if basmallahs != bismillah_surahs:
        absent = sorted(bismillah_surahs - basmallahs)
        fail(f"{len(absent)} surahs are missing a basmallah line, first {absent[:5]}")

    spans = connection.execute(
        "SELECT surah, ayah, MIN(page), MAX(page), COUNT(*) FROM ayah_pages "
        "WHERE layout = ? GROUP BY surah, ayah", (layout,)).fetchall()
    for surah, ayah, low, high, count in spans:
        if high - low + 1 != count:
            fail(f"{surah}:{ayah} pages {low}..{high} are not contiguous")
            break
    if len(spans) != AYAH_COUNT:
        fail(f"ayah_pages covers {len(spans)} ayahs, expected {AYAH_COUNT}")
    return errors


def verify(path: Path) -> list:
    """Check an existing database; return a list of problems (empty when valid)."""
    if not path.is_file():
        return [f"database not found: {path}"]
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        connection.execute("PRAGMA query_only = ON")
        errors = []
        meta = dict(connection.execute("SELECT key, value FROM meta"))
        if meta.get("schema_version") != str(SCHEMA_VERSION):
            errors.append(f"schema_version {meta.get('schema_version')} != {SCHEMA_VERSION}")
        if meta.get("content_sha256") != content_digest(connection):
            errors.append("content_sha256 does not match the database content")
        problems = connection.execute("PRAGMA foreign_key_check").fetchall()
        if problems:
            errors.append(f"{len(problems)} foreign key violations, first {problems[0]}")

        surahs = connection.execute(
            "SELECT number, ayah_count, bismillah_pre FROM surahs ORDER BY number").fetchall()
        if [row[0] for row in surahs] != list(range(1, SURAH_COUNT + 1)):
            errors.append(f"surahs are not exactly 1..{SURAH_COUNT} (found {len(surahs)})")
        if sum(row[1] for row in surahs) != AYAH_COUNT:
            errors.append(f"surah ayah counts sum to {sum(row[1] for row in surahs)}, "
                          f"expected {AYAH_COUNT}")
        for number, count, _ in surahs:
            ayahs = [row[0] for row in connection.execute(
                "SELECT ayah FROM ayahs WHERE surah = ? ORDER BY ayah", (number,))]
            if ayahs != list(range(1, count + 1)):
                errors.append(f"surah {number} ayahs are not exactly 1..{count}")
        for name, _, count in DIVISIONS:
            values = [row[0] for row in connection.execute(f"SELECT {name} FROM ayahs ORDER BY surah, ayah")]
            if values and (values[0] != 1 or values[-1] != count or
                           any(b - a not in (0, 1) for a, b in zip(values, values[1:]))):
                errors.append(f"{name} numbers do not run 1..{count} in ayah order without gaps")
        bismillah_surahs = {number for number, _, flag in surahs if flag}
        if 1 in bismillah_surahs or 9 in bismillah_surahs:
            errors.append("surahs 1 and 9 must not have a separate basmallah")

        layouts = connection.execute(
            "SELECT id, page_count, lines_per_page, page_font_url IS NOT NULL FROM layouts ORDER BY id").fetchall()
        if not layouts:
            errors.append("no layouts")
        for layout, page_count, lines_per_page, paged in layouts:
            errors += verify_layout(connection, layout, page_count, lines_per_page,
                                    bismillah_surahs, bool(paged))
        return errors
    except sqlite3.Error as error:
        return [f"database error: {error}"]
    finally:
        connection.close()


def report(errors: list, success: str) -> int:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        return 1
    print(success)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    build_command = commands.add_parser("build", help="import sources and verify the result")
    build_command.add_argument("--manifest", type=Path, default=TOOLS / "quran_sources.json")
    build_command.add_argument("--raw", type=Path, default=TOOLS / "data" / "raw")
    build_command.add_argument("--output", type=Path, required=True)
    build_command.add_argument("--layout", action="append", dest="layouts", required=True,
                               help="layout id to include; repeat for several")
    build_command.add_argument("--allow-unverified", action="store_true",
                               help="include layouts not yet verified (inspection builds only)")
    verify_command = commands.add_parser("verify", help="check an existing database")
    verify_command.add_argument("database", type=Path)
    args = parser.parse_args()

    if args.command == "verify":
        return report(verify(args.database), f"verified {args.database}")
    layouts = sorted(set(args.layouts))
    errors = build(args.manifest, args.raw.resolve(), args.output, layouts, args.allow_unverified)
    return report(errors, f"built and verified {args.output} ({', '.join(layouts)})")


if __name__ == "__main__":
    sys.exit(main())
