import Foundation
import MushafRendering
import Recitation
import Testing
@testable import Surabar

struct BundledReciterTests {
    @Test func bundledReciterListIsComplete() {
        let reciters = ReciterCatalogLoader.bundled()
        #expect(reciters.count == 19)
        #expect(reciters.first?.id == Reciter.defaultID)
        #expect(Set(reciters.map(\.id)).count == reciters.count)
        #expect(Set(reciters.map(\.displayName)).count == reciters.count, "styles tell same-name reciters apart")
    }
}

@MainActor
struct PlaybackPreferenceTests {
    @Test func playbackPreferencesPersistAndRejectBadValues() {
        let name = "SurabarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let state = AppState(defaults: defaults)
        #expect(state.reciterID == 123)
        #expect(state.speed == 1)
        #expect(state.lastPlayedAyah == nil)
        state.reciterID = 118
        state.speed = 1.25
        state.lastPlayedAyah = .init(surah: 2, ayah: 255)
        let relaunched = AppState(defaults: defaults)
        #expect(relaunched.reciterID == 118)
        #expect(relaunched.speed == 1.25)
        #expect(relaunched.lastPlayedAyah == .init(surah: 2, ayah: 255))
        defaults.set(3.0, forKey: "playbackSpeed")
        #expect(AppState(defaults: defaults).speed == 1)
    }
}

@MainActor
struct LoopTests {
    private func makePlayer() -> (AppState, RecitationPlayer) {
        let name = "SurabarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let state = AppState(defaults: defaults)
        let counts = [7, 286, 200]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("surabar-audio-\(UUID().uuidString)")
        return (state, RecitationPlayer(state: state, ayahCounts: counts, reciters: ReciterCatalogLoader.bundled(),
                                        timings: TimingsStore(ayahCounts: counts), audio: AudioCache(root: root)))
    }

    @Test func loopCyclesAndPersists() {
        let (state, player) = makePlayer()
        #expect(state.loopMode == .off)
        player.cycleLoop()
        #expect(state.loopMode == .ayah)
        player.cycleLoop()
        #expect(state.loopMode == .unit)
        player.cycleLoop()
        #expect(state.loopMode == .off)
    }

    @Test func loopModesShapeThePlaybackSequence() {
        let (state, player) = makePlayer()
        let ayah = AyahKey(surah: 2, ayah: 255)
        var sequence = player.sequence(at: ayah)
        #expect(sequence.ayahRepeats == .times(1) && sequence.range == nil)
        #expect(sequence.boundaryEnd == AyahKey(surah: 2, ayah: 286), "without a loop, playback stops at the surah end")

        state.repeatCount = 3
        player.setLoop(.ayah)
        sequence = player.sequence(at: ayah)
        #expect(sequence.ayahRepeats == .times(3) && sequence.range == nil)

        state.repeatCount = 0
        player.setLoop(.unit)
        sequence = player.sequence(at: ayah)
        #expect(sequence.range == AyahKey(surah: 2, ayah: 1) ... AyahKey(surah: 2, ayah: 286))
        #expect(sequence.rangeRepeats == .forever && sequence.ayahRepeats == .times(1))
    }

    @Test func surahLoopStartedMidSurahCountsFullPasses() {
        let (state, player) = makePlayer()
        state.repeatCount = 2
        player.setLoop(.unit)
        player.skip(to: AyahKey(surah: 1, ayah: 6))
        let sequence = player.sequence(at: AyahKey(surah: 1, ayah: 7))
        // The end of the partial pass loops back for two full passes.
        #expect(sequence.step(after: PlaybackStep(kind: .ayah, ayah: AyahKey(surah: 1, ayah: 7), repetition: 1), rangePass: 0)?.rangePass == 1)
        #expect(sequence.step(after: PlaybackStep(kind: .ayah, ayah: AyahKey(surah: 1, ayah: 7), repetition: 1), rangePass: 2) == nil)
    }

    @Test func rangeLoopsRepeatTheChosenAyahs() {
        let (state, player) = makePlayer()
        state.repeatCount = 3
        player.loop(AyahKey(surah: 2, ayah: 286) ... AyahKey(surah: 3, ayah: 2))
        #expect(state.loopMode == .range)
        let sequence = player.sequence(at: AyahKey(surah: 2, ayah: 286))
        #expect(sequence.range == AyahKey(surah: 2, ayah: 286) ... AyahKey(surah: 3, ayah: 2))
        #expect(sequence.rangeRepeats == .times(3))
        // Across the surah boundary, with the basmalah before 3:1.
        let next = sequence.step(after: PlaybackStep(kind: .ayah, ayah: AyahKey(surah: 2, ayah: 286), repetition: 1), rangePass: 1)
        #expect(next?.step.kind == .basmalah && next?.step.ayah == AyahKey(surah: 3, ayah: 1))
        let loopBack = sequence.step(after: PlaybackStep(kind: .ayah, ayah: AyahKey(surah: 3, ayah: 2), repetition: 1), rangePass: 1)
        #expect(loopBack?.step.ayah == AyahKey(surah: 2, ayah: 286) && loopBack?.rangePass == 2)
        // The range is remembered; cycling turns the loop off.
        #expect(AppState(defaults: state.debugDefaults).loopRange == AyahKey(surah: 2, ayah: 286) ... AyahKey(surah: 3, ayah: 2))
        player.cycleLoop()
        #expect(state.loopMode == .off)
        player.setLoop(.range)
        #expect(state.loopMode == .range, "the remembered range can be chosen again from the Loop menu")
    }

    @Test func playbackStopsAtTheChosenUnit() {
        let (state, player) = makePlayer()
        let ayah = AyahKey(surah: 2, ayah: 255)
        player.unitEnd = { _, stop in stop == .page ? AyahKey(surah: 2, ayah: 256) : AyahKey(surah: 3, ayah: 92) }
        #expect(state.playbackStop == .surah)
        #expect(player.sequence(at: ayah).boundaryEnd == AyahKey(surah: 2, ayah: 286))
        state.playbackStop = .page
        #expect(player.sequence(at: ayah).boundaryEnd == AyahKey(surah: 2, ayah: 256))
        state.playbackStop = .juz
        #expect(player.sequence(at: ayah).boundaryEnd == AyahKey(surah: 3, ayah: 92))
        state.playbackStop = .quran
        #expect(player.sequence(at: ayah).boundaryEnd == AyahKey(surah: 3, ayah: 200), "the last ayah of the (test) Quran")
        // A loop takes precedence.
        player.setLoop(.unit)
        #expect(player.sequence(at: ayah).range != nil)
    }

    @Test func pageLoopStaysOnThePageWhereItStarted() {
        let (state, player) = makePlayer()
        let page = AyahKey(surah: 2, ayah: 253) ... AyahKey(surah: 2, ayah: 256)
        player.pageRange = { $0.surah == 2 && $0.ayah >= 253 && $0.ayah <= 256 ? page : nil }
        state.skipUnit = .page
        player.setLoop(.unit)
        player.skip(to: AyahKey(surah: 2, ayah: 255))
        #expect(player.ayah == AyahKey(surah: 2, ayah: 255))
        #expect(player.sequence(at: AyahKey(surah: 2, ayah: 256)).range == page)
        // Moving off the page loops the new one instead.
        player.pageRange = { _ in AyahKey(surah: 3, ayah: 1) ... AyahKey(surah: 3, ayah: 9) }
        player.skip(to: AyahKey(surah: 3, ayah: 2))
        #expect(player.sequence(at: AyahKey(surah: 3, ayah: 2)).range == AyahKey(surah: 3, ayah: 1) ... AyahKey(surah: 3, ayah: 9))
    }
}
