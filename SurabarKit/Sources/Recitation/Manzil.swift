import MushafRendering

/// The Manzil: passages recited for protection, as in the widely circulated South Asian Manzil booklet.
/// Printings vary slightly, so this is the one place to adjust the list.
public enum Manzil {
    public static let passages: [ClosedRange<AyahKey>] = [
        (1, 1, 7), (2, 1, 5), (2, 163, 164), (2, 255, 257), (2, 284, 286), (3, 18, 18), (3, 26, 27), (7, 54, 56),
        (17, 110, 111), (23, 115, 118), (37, 1, 11), (55, 33, 40), (59, 21, 24), (72, 1, 4), (109, 1, 6), (112, 1, 4),
        (113, 1, 5), (114, 1, 6),
    ].map { AyahKey(surah: $0.0, ayah: $0.1) ... AyahKey(surah: $0.0, ayah: $0.2) }

    /// Every ayah of the Manzil, in reading order.
    public static var ayahs: [AyahKey] {
        passages.flatMap { range in (range.lowerBound.ayah ... range.upperBound.ayah).map { AyahKey(surah: range.lowerBound.surah, ayah: $0) } }
    }

    /// The passage an ayah is in, if any.
    public static func passage(containing ayah: AyahKey) -> Int? {
        passages.firstIndex { $0.contains(ayah) }
    }

    /// The Manzil ayah after (+1) or before (−1) `ayah`, crossing from one passage to the next.
    public static func ayah(_ direction: Int, from ayah: AyahKey) -> AyahKey? {
        let all = ayahs
        guard let index = all.firstIndex(of: ayah) else { return direction > 0 ? all.first : nil }
        let next = index + direction
        return all.indices.contains(next) ? all[next] : nil
    }
}
