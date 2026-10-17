# Surabar

An open-source macOS menu bar Quran reader, being built around authentic mushaf pages and recitation.

## Development status

Surabar is in early development. The menu bar app has an offline mushaf reader (Uthmani and IndoPak pages), recitation from continuous surah recordings that follows along ayah by ayah, loops (ayah, surah, page, or a range of ayahs), recitations saved for offline listening and downloadable by surah or juz, media-key and Now Playing support, and bookmarks, highlights, and notes with JSON backup. The repository also contains source tooling, a Quran database builder and verifier, a Core Text page-rendering harness, and project documentation. There is no published installer yet.

Still planned: downloadable translations, a global shortcut and launch at login, accessibility and performance work, and a visual refresh. The target is macOS 14 or later on Apple Silicon and Intel. Homebrew and direct DMG installation are planned for the first release.

## Working with source data

Repository layout: `Surabar/` is the app, `SurabarTests/` its tests, `SurabarKit/` the rendering and data package shared with command-line tools, and `tools/` the Python data pipeline.

Source exports belong in `tools/data/raw/`, which is ignored by Git. Preserve their original contents and accompanying license notices. To inspect local downloads using Python 3 and its standard library:

```sh
python3 tools/inspect_quran_sources.py tools/data/raw
```

The tool reports SHA-256 hashes and JSON/SQLite structure without rewriting the inputs. It exits unsuccessfully for missing or empty input, or an inspection error. It does not validate Quran completeness, layout accuracy, or redistribution permission.

### Building and running the app

Requirements: macOS 14 or later, Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is generated from `project.yml` and is not committed. Generate it once after cloning, and again only when `project.yml` changes; Xcode picks up added and removed source files by itself.

```sh
python3 tools/prepare_app_resources.py   # builds the Quran database and gathers fonts and translation
xcodegen generate
open Surabar.xcodeproj
```

`prepare_app_resources.py` needs the source downloads described below and writes to `Surabar/Resources/Bundled/`, which is not committed while redistribution terms are reviewed. Without it the app still builds and explains that the Quran data is missing.

Choose the **Surabar** scheme and **My Mac**, then press Run (⌘R). Builds are signed to run locally, so no Apple Developer account is needed. From the command line: `xcodebuild -project Surabar.xcodeproj -scheme Surabar -destination 'platform=macOS' test`.

### Building the Quran database

`tools/quran_sources.json` records each source's URL, local path, and SHA-256 hash. After the sources are downloaded and recorded there, build and verify the database:

```sh
python3 tools/build_quran_db.py build --output build/quran.sqlite --layout uthmani --layout indopak
python3 tools/build_quran_db.py verify build/quran.sqlite
```

Uthmani pages use QUL's QCF V2 layout with one glyph font per page, as printed mushaf apps do, so every line fills the width without stretched gaps. Each word keeps its Unicode text for copying and accessibility, and has glyph codes for its page font. The page fonts are not bundled: the database lists each file with its size and SHA-256, and the app downloads them once, showing the Unicode text with the QPC Hafs font until they are present.

The builder refuses files whose hashes differ from the manifest, and layouts not yet verified as matching their word data. It copies source text unchanged. Verification checks surah and ayah counts, word order and positions, page and line numbering, complete non-overlapping line coverage of every word, surah headers, basmallah lines, and a content digest. It needs only the generated database.

### Rendering harness

`SurabarKit/` is a Swift package with the Core Text page renderer, the database reader, and a command-line harness (macOS 14 or later, Swift 6):

```sh
swift run --package-path SurabarKit surabar-render sample --font GeezaPro --out build/sample
swift run --package-path SurabarKit surabar-render render --db build/quran.sqlite --layout indopak --font FONT.ttf --pages 1,2 --out build/pages
swift run --package-path SurabarKit surabar-render check --db build/quran.sqlite --layout indopak --font FONT.ttf
swift run --package-path SurabarKit surabar-render check --db build/quran.sqlite --layout uthmani --font FALLBACK.ttf --page-fonts FONT_DIR
```

`render` writes PNG snapshots at the S, M, and L reader widths (340, 440, and 560 points). `check` lays out every page and reports overflowing lines, missing glyphs, ink clipped at the page edge, and overlapping words. `sample` uses synthetic, non-Quranic Arabic text.

## Contributing

Run the regression tests without downloading any Quran assets:

```sh
python3 -m unittest discover -s tools/tests -v
swift test --package-path SurabarKit
xcodegen generate && xcodebuild -project Surabar.xcodeproj -scheme Surabar -destination 'platform=macOS' test
```

GitHub Actions runs these on pushes to `main` and pull requests, using synthetic inputs and system fonts. App build checks and release automation will be added as those parts of the project are implemented.

See [CONTRIBUTING.md](CONTRIBUTING.md). Please discuss substantial changes in an issue before implementing them. Quranic text must remain identical to its approved source; font and layout defects must be fixed without editing the text.

## License

Application code and project-authored tooling are available under the [MIT License](LICENSE). Third-party Quran data, translations, fonts, and recordings retain their own terms; the code license does not relicense those assets. See [CREDITS.md](CREDITS.md) for source-review status.
