# Contributing to Surabar

Surabar is early in development. Start with a focused issue describing the problem or proposed improvement. Discuss architecture changes, new dependencies, and additional features with the maintainer before writing a large pull request.

## Local development

1. Fork the repository and clone your fork.
2. Create a branch for your change.
3. Follow the available setup instructions in [README.md](README.md). There is not yet an app build.
4. Make a focused change and run `python3 -m unittest discover -s tools/tests -v` for source tooling, plus any other checks appropriate to it.
5. Open a pull request describing the behavior changed and the validation performed. Include screenshots for rendering or UI changes.

## Quran data and rendering

- Never change Quranic text to compensate for a font or shaping bug.
- Include source URLs, versions, checksums, and redistribution terms when proposing assets.
- Keep unreviewed downloads in `tools/data/raw/`; do not add them to Git.
- Persist ayah identity as `surah:ayah`, independently of layout page numbers.
- For a text or layout issue, include the script, layout, page, ayah reference, and a reference preview where possible.
- Do not add a dependency without maintainer agreement. Planned dependencies are GRDB.swift, KeyboardShortcuts, and Sparkle 2.

## Pull requests

Use clear commit messages, keep unrelated changes separate, and state any checks you could not run. Do not include personal plans, credentials, local build artifacts, or third-party content without reviewed redistribution terms.

Project-authored code contributions use the repository's MIT license. Third-party materials must retain their original licenses and notices.

Keep discussions respectful and focused on the project. The maintainer may close abusive or off-topic contributions.
