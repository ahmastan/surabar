import SwiftUI

/// Settings › General › Acknowledgements: the sources of the Quran text, fonts, translations,
/// recitations, and libraries, with their credits and the licence texts that come with them.
struct AcknowledgementsView: View {
    let state: AppState
    let palette: ReaderPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { state.showsAcknowledgements = false } label: {
                Label("General", systemImage: "chevron.left").font(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            Text("Surabar is built on the work of these people and projects.")
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Acknowledgement.groups, id: \.title) { group in
                SettingsGroup(title: group.title, palette: palette) {
                    ForEach(Array(group.entries.enumerated()), id: \.element.name) { index, entry in
                        if index > 0 { Divider() }
                        AcknowledgementRow(entry: entry, palette: palette)
                    }
                }
            }
        }
    }
}

private struct AcknowledgementRow: View {
    let entry: Acknowledgement
    let palette: ReaderPalette
    @State private var showsLicense = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name)
                Spacer(minLength: 8)
                if let url = entry.url { Link("Website", destination: url).font(.caption) }
            }
            Text(entry.credit)
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let text = entry.licenseText {
                Button(showsLicense ? "Hide licence" : "Show licence") { showsLicense.toggle() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(palette.accent)
                if showsLicense {
                    Text(text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct Acknowledgement {
    let name: String
    let credit: String
    var url: URL?
    /// A text file in the app's resources (Resources/Licenses).
    var license: String?

    var licenseText: String? {
        guard let license, let url = Bundle.main.url(forResource: license, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static let groups: [(title: String, entries: [Acknowledgement])] = [
        ("Quran text and mushaf layouts", [
            Acknowledgement(name: "Quranic Universal Library (QUL), by Tarteel",
                            credit: "Quran text and word data (KFGQPC Hafs and IndoPak Nastaleeq), the 15-line mushaf layouts "
                                + "(KFGQPC Madani and Qudratullah IndoPak), and the surah, juz, hizb, and rub metadata.",
                            url: URL(string: "https://qul.tarteel.ai")),
        ]),
        ("Fonts", [
            Acknowledgement(name: "QCF V2 page fonts",
                            credit: "By the King Fahd Glorious Quran Printing Complex, Madinah, from the calligraphy of "
                                + "Uthman Taha. Downloaded once from QUL to draw the Uthmani pages.",
                            url: URL(string: "https://qul.tarteel.ai/resources/font/249")),
            Acknowledgement(name: "KFGQPC HAFS Uthmanic Script, version 2.2",
                            credit: "By the King Fahd Glorious Quran Printing Complex. Shows the Uthmani text until the page fonts are downloaded.",
                            url: URL(string: "https://qul.tarteel.ai/resources/font/245"), license: "License-KFGQPC-Hafs"),
            Acknowledgement(name: "AlQuran IndoPak by QuranWBW, version 2.100",
                            credit: "By Ayman Siddiqui for QuranWBW.com, based on the Al Qalam Quran Majeed fonts, with ayah "
                                + "numbers from the KFGQPC Nastaleeq font. Draws the IndoPak pages.",
                            url: URL(string: "https://quranwbw.com"), license: "Notice-IndoPak"),
        ]),
        ("Translations and recitations", [
            Acknowledgement(name: "QuranEnc.com",
                            credit: "Translations of the meanings of the Quran, shown unmodified with each publisher's credit and version. "
                                + "The included English translation is Saheeh International, published by Noor International Center.",
                            url: URL(string: "https://quranenc.com")),
            Acknowledgement(name: "mp3quran.net",
                            credit: "The recitations, streamed from their recordings by each reciter named in the player, and the ayah timings.",
                            url: URL(string: "https://mp3quran.net")),
        ]),
        ("Software", [
            Acknowledgement(name: "GRDB.swift", credit: "By Gwendal Roué. MIT License.",
                            url: URL(string: "https://github.com/groue/GRDB.swift"), license: "License-GRDB"),
            Acknowledgement(name: "KeyboardShortcuts", credit: "By Sindre Sorhus. MIT License.",
                            url: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts"), license: "License-KeyboardShortcuts"),
            Acknowledgement(name: "Sparkle", credit: "By the Sparkle Project. MIT License, with the notices of its components.",
                            url: URL(string: "https://sparkle-project.org"), license: "License-Sparkle"),
            Acknowledgement(name: "Surabar", credit: "Open source under the MIT License. The licence covers Surabar's own code, not the assets above.",
                            url: URL(string: "https://github.com/ahmastan/surabar"), license: "License-Surabar"),
        ]),
    ]
}
