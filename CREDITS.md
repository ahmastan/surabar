# Credits and third-party assets

Surabar's application code and tooling use the MIT license. This does not apply automatically to third-party assets.

No Quran database, font, translation, or audio recording is committed or published. Local development builds bundle them from `tools/prepare_app_resources.py`. The following sources are under evaluation; listing them is not a declaration that redistribution has been approved.

| Source | Intended use | Status |
| --- | --- | --- |
| [Quranic Universal Library (QUL), by Tarteel](https://qul.tarteel.ai/) | Quran scripts, layouts, and metadata | Exact exports, compatibility, and resource-specific terms pending review |
| [QPC V2 Font](https://qul.tarteel.ai/resources/font/249), KFGQPC QCF V2, one font per page (604 files) | Uthmani page rendering, downloaded once by the app from QUL's CDN | The files carry no license text. Not bundled; terms must be confirmed with QUL or the King Fahd Glorious Quran Printing Complex before release |
| [QPC Hafs font](https://qul.tarteel.ai/resources/font/245), KFGQPC HAFS Uthmanic Script version 2.2 | Uthmani fallback until the page fonts are downloaded | Embedded King Fahd Glorious Quran Printing Complex license permits free use, copying, and distribution, and forbids sale or modification. Not yet bundled |
| [Indopak Nastaleeq font](https://qul.tarteel.ai/resources/font/242), AlQuran IndoPak by QuranWBW version 2.100, by Ayman Siddiqui | IndoPak rendering | Embedded notice prohibits distribution without written notice from QuranWBW.com. Not bundled; permission required |
| [Saheeh International](https://qul.tarteel.ai/resources/translation/193) | Proposed bundled English translation | Redistribution permission not yet established; used in local builds only |
| [mp3quran.net](https://mp3quran.net/) API v3 | Original continuous surah recitations and ayah timings (19 reciters) | Streamed, not bundled; terms to be confirmed before release |
| [GRDB.swift](https://github.com/groue/GRDB.swift) by Gwendal Roué | Read-only SQLite access | MIT License; fetched by Swift Package Manager |

Before bundling an asset, record its exact source, version or checksum, copyright attribution, license text, and required notices. Update this file as assets and libraries are actually added.
