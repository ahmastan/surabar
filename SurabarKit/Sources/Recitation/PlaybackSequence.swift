import Foundation
import MushafRendering

/// One thing to play: an ayah, or the basmalah recited before a surah's first ayah.
public struct PlaybackStep: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case basmalah
        case ayah
    }

    public let kind: Kind
    /// The ayah played, or for a basmalah the ayah it precedes.
    public let ayah: AyahKey
    /// Which play of the ayah this is, starting at 1; 0 for a basmalah.
    public let repetition: Int
    /// Whether the configured pause between repeats comes before this step.
    public let pausesBefore: Bool

    public init(kind: Kind, ayah: AyahKey, repetition: Int, pausesBefore: Bool = false) {
        self.kind = kind
        self.ayah = ayah
        self.repetition = repetition
        self.pausesBefore = pausesBefore
    }
}

/// Repeat counts offered for each ayah and for a range; nil repeats until stopped.
public enum RepeatCount: Hashable, Sendable, CaseIterable {
    case times(Int)
    case forever

    public static let allCases: [RepeatCount] = [.times(1), .times(2), .times(3), .times(5), .times(10), .forever]

    func allows(_ play: Int) -> Bool {
        switch self {
        case .times(let count): play <= count
        case .forever: true
        }
    }
}

/// Builds the playback order lazily, one step at a time: basmalah steps, ayah repeats, an optional
/// looping range, and the boundary where playback stops. Navigation by the user moves by ayah,
/// not by repetition.
public struct PlaybackSequence: Sendable {
    /// Ayahs per surah, index 0 for surah 1.
    public let ayahCounts: [Int]
    public var ayahRepeats: RepeatCount = .times(1)
    /// A range that loops in place of the boundary.
    public var range: ClosedRange<AyahKey>?
    public var rangeRepeats: RepeatCount = .forever
    /// The last ayah before stopping, when no range is set.
    public var boundaryEnd: AyahKey
    /// Whether a basmalah step precedes ayah 1 of surahs other than 1 and 9. A reciter whose
    /// ayah-1 recordings already begin with the basmalah sets this to false to avoid repeating it.
    public var playsBasmalah = true

    public init(ayahCounts: [Int], boundaryEnd: AyahKey) {
        self.ayahCounts = ayahCounts
        self.boundaryEnd = boundaryEnd
    }

    /// The ayah's position in the whole Quran, 1–6236, as the audio CDN numbers recordings.
    public func globalNumber(of ayah: AyahKey) -> Int {
        ayahCounts.prefix(ayah.surah - 1).reduce(0, +) + ayah.ayah
    }

    public func ayah(after ayah: AyahKey) -> AyahKey? {
        if ayah.ayah < ayahCounts[ayah.surah - 1] { return AyahKey(surah: ayah.surah, ayah: ayah.ayah + 1) }
        return ayah.surah < ayahCounts.count ? AyahKey(surah: ayah.surah + 1, ayah: 1) : nil
    }

    public func ayah(before ayah: AyahKey) -> AyahKey? {
        if ayah.ayah > 1 { return AyahKey(surah: ayah.surah, ayah: ayah.ayah - 1) }
        return ayah.surah > 1 ? AyahKey(surah: ayah.surah - 1, ayah: ayahCounts[ayah.surah - 2]) : nil
    }

    private func needsBasmalah(_ ayah: AyahKey) -> Bool {
        playsBasmalah && ayah.ayah == 1 && ayah.surah != 1 && ayah.surah != 9
    }

    /// The first step when starting at an ayah, with its basmalah when it opens a surah.
    public func start(at ayah: AyahKey, pausesBefore: Bool = false) -> PlaybackStep {
        needsBasmalah(ayah)
            ? PlaybackStep(kind: .basmalah, ayah: ayah, repetition: 0, pausesBefore: pausesBefore)
            : PlaybackStep(kind: .ayah, ayah: ayah, repetition: 1, pausesBefore: pausesBefore)
    }

    /// The step after `step`, or nil when playback should stop. `rangePass` counts completed passes of the range.
    public func step(after step: PlaybackStep, rangePass: Int = 1) -> (step: PlaybackStep, rangePass: Int)? {
        if step.kind == .basmalah {
            return (PlaybackStep(kind: .ayah, ayah: step.ayah, repetition: 1), rangePass)
        }
        if ayahRepeats.allows(step.repetition + 1) {
            return (PlaybackStep(kind: .ayah, ayah: step.ayah, repetition: step.repetition + 1, pausesBefore: true), rangePass)
        }
        if let range {
            if step.ayah >= range.upperBound || step.ayah < range.lowerBound {
                guard rangeRepeats.allows(rangePass + 1) else { return nil }
                return (start(at: range.lowerBound, pausesBefore: true), rangePass + 1)
            }
            guard let next = ayah(after: step.ayah) else { return nil }
            return (start(at: next), rangePass)
        }
        guard step.ayah < boundaryEnd, let next = ayah(after: step.ayah) else { return nil }
        return (start(at: next), rangePass)
    }
}
