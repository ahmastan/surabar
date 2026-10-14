# Surabar

An open-source macOS menu bar Quran reader, being built around authentic mushaf pages and recitation.

## Development status

Surabar is in its initial data and rendering research phase. There is no runnable macOS app or published installer yet. The repository currently contains source-inspection tooling and project documentation.

Planned features include Uthmani and IndoPak pages, ayah-level recitation highlighting, offline reading and audio downloads, translations, bookmarks, highlights, and notes. The target is macOS 14 or later on Apple Silicon and Intel. Homebrew and direct DMG installation are planned for the first release.

## Working with source data

Source exports belong in `tools/data/raw/`, which is ignored by Git. Preserve their original contents and accompanying license notices. To inspect local downloads using Python 3 and its standard library:

```sh
python3 tools/inspect_quran_sources.py tools/data/raw
```

The tool reports SHA-256 hashes and JSON/SQLite structure without rewriting the inputs. It exits unsuccessfully for missing or empty input, or an inspection error. It does not validate Quran completeness, layout accuracy, or redistribution permission. The full data pipeline and native rendering harness are not implemented yet.

## Contributing

Run the source-inspection regression tests without downloading any Quran assets:

```sh
python3 -m unittest discover -s tools/tests -v
```

GitHub Actions runs these tests on pushes to `main` and pull requests. Native app build checks and release automation will be added as those parts of the project are implemented.

See [CONTRIBUTING.md](CONTRIBUTING.md). Please discuss substantial changes in an issue before implementing them. Quranic text must remain identical to its approved source; font and layout defects must be fixed without editing the text.

## License

Application code and project-authored tooling are available under the [MIT License](LICENSE). Third-party Quran data, translations, fonts, and recordings retain their own terms; the code license does not relicense those assets. See [CREDITS.md](CREDITS.md) for source-review status.
