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
        #expect(state.volume == 1)
        #expect(state.lastPlayedAyah == nil)
        state.reciterID = 118
        state.speed = 1.25
        state.volume = 0.4
        state.lastPlayedAyah = .init(surah: 2, ayah: 255)
        let relaunched = AppState(defaults: defaults)
        #expect(relaunched.reciterID == 118)
        #expect(relaunched.speed == 1.25)
        #expect(relaunched.volume == 0.4)
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

struct ManzilRoutineTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func readTodayResetsAtLocalMidnight() {
        var routine = ManzilRoutine()
        routine.setRead(true, on: date(17, 23, 59), calendar: calendar)
        #expect(routine.isRead(on: date(17, 6), calendar: calendar))
        #expect(!routine.isRead(on: date(18, 0, 1), calendar: calendar), "a new day after midnight")
        routine.setRead(false, on: date(17, 12), calendar: calendar)
        #expect(!routine.isRead(on: date(17, 12), calendar: calendar), "can be unmarked")
    }

    @Test func streaksCountDaysInARowAndSurviveUntilTheDayEnds() {
        var routine = ManzilRoutine()
        for day in [13, 14, 15, 16] { routine.setRead(true, on: date(day, 7), calendar: calendar) }
        #expect(routine.streak(on: date(16, 20), calendar: calendar) == 4)
        #expect(routine.streak(on: date(17, 8), calendar: calendar) == 4, "today not yet read keeps yesterday's streak")
        #expect(routine.streak(on: date(18, 8), calendar: calendar) == 0, "a missed day ends it")
        routine.setRead(true, on: date(17, 21), calendar: calendar)
        #expect(routine.streak(on: date(17, 22), calendar: calendar) == 5)
        routine.setRead(false, on: date(15, 9), calendar: calendar)
        #expect(routine.streak(on: date(17, 22), calendar: calendar) == 2, "a gap breaks the count")
    }
}

@MainActor
struct ManzilPlaybackTests {
    private func makePlayer() -> (AppState, RecitationPlayer) {
        let name = "SurabarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let state = AppState(defaults: defaults)
        let counts = [7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128, 111, 110, 98, 135,
                      112, 78, 118, 64, 77, 227, 93, 88, 69, 60, 34, 30, 73, 54, 45, 83, 182, 88, 75, 85, 54, 53, 89, 59, 37,
                      35, 38, 29, 18, 45, 60, 49, 62, 55, 78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30, 52, 52, 44, 28,
                      28, 20, 56, 40, 31, 50, 40, 46, 42, 29, 19, 36, 25, 22, 17, 19, 26, 30, 20, 15, 21, 11, 8, 8, 19, 5, 8,
                      8, 11, 11, 8, 3, 9, 5, 4, 7, 3, 6, 3, 5, 4, 5, 6]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("surabar-audio-\(UUID().uuidString)")
        return (state, RecitationPlayer(state: state, ayahCounts: counts, reciters: ReciterCatalogLoader.bundled(),
                                        timings: TimingsStore(ayahCounts: counts), audio: AudioCache(root: root)))
    }

    @Test func manzilModePlaysThePassagesWithItsRepeatCount() {
        let (state, player) = makePlayer()
        state.manzilRepeats = 3
        state.loopMode = .manzil
        let sequence = player.sequence(at: AyahKey(surah: 2, ayah: 255))
        #expect(sequence.playlist == Manzil.passages)
        #expect(sequence.rangeRepeats == .times(3))
        player.cycleLoop()
        #expect(state.loopMode == .manzil && state.manzilRepeats == 7, "the Loop changes how often, not whether")
        state.loopMode = .off
        player.setLoop(.manzil)
        #expect(state.loopMode == .off, "the Manzil is started by playing it, not from the Loop")
    }

    @Test func inTheManzilTheLoopSetsHowManyTimesItIsRecited() {
        let (state, player) = makePlayer()
        player.readsManzil = { true }
        #expect(player.inManzil && state.manzilRepeats == 1)
        player.cycleLoop()
        #expect(state.manzilRepeats == 3)
        player.cycleLoop()
        player.cycleLoop()
        #expect(state.manzilRepeats == 0, "until stopped")
        player.cycleLoop()
        #expect(state.manzilRepeats == 1)
        #expect(state.loopMode == .off, "the ordinary loop is untouched")
    }

    @Test func leavingTheManzilWhileItIsNotPlayingReturnsTheLoopToNormal() {
        let (state, player) = makePlayer()
        state.loopMode = .manzil
        #expect(player.inManzil)
        player.leftManzil()
        #expect(state.loopMode == .off && !player.inManzil)
        let sequence = player.sequence(at: AyahKey(surah: 27, ayah: 1))
        #expect(sequence.playlist == nil, "An-Naml plays as An-Naml")
        #expect(sequence.step(after: PlaybackStep(kind: .ayah, ayah: AyahKey(surah: 27, ayah: 1), repetition: 1))?.step.ayah
                == AyahKey(surah: 27, ayah: 2))
    }

    @Test func readingTheManzilMakesPreviousAndNextFollowIt() {
        let (_, player) = makePlayer()
        player.readsManzil = { true }
        player.skip(to: AyahKey(surah: 3, ayah: 18))
        player.stepAyah(1, from: AyahKey(surah: 3, ayah: 18))
        #expect(player.ayah == AyahKey(surah: 3, ayah: 26), "the next Manzil ayah, not 3:19")
    }

    @Test func previousAndNextMoveThroughTheManzil() {
        let (state, player) = makePlayer()
        state.loopMode = .manzil
        player.skip(to: AyahKey(surah: 2, ayah: 5))
        player.stepAyah(1, from: AyahKey(surah: 1, ayah: 1))
        #expect(player.ayah == AyahKey(surah: 2, ayah: 163))
        player.stepAyah(-1, from: AyahKey(surah: 1, ayah: 1))
        #expect(player.ayah == AyahKey(surah: 2, ayah: 5))
    }
}

@MainActor
struct SleepTimerTests {
    private func makePlayer(lastPlayed: AyahKey? = nil) -> (AppState, RecitationPlayer) {
        let name = "SurabarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let state = AppState(defaults: defaults)
        state.lastPlayedAyah = lastPlayed
        let counts = [7, 286, 200]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("surabar-audio-\(UUID().uuidString)")
        return (state, RecitationPlayer(state: state, ayahCounts: counts, reciters: ReciterCatalogLoader.bundled(),
                                        timings: TimingsStore(ayahCounts: counts), audio: AudioCache(root: root)))
    }

    @Test func aTimedSleepTimerHasADeadlineAndPausingCancelsIt() {
        let (_, player) = makePlayer()
        player.setSleepTimer(.after(15 * 60))
        #expect(player.sleepTimer == .after(15 * 60))
        let left = player.sleepDeadline.map { $0.timeIntervalSinceNow } ?? 0
        #expect(left > 15 * 60 - 5 && left <= 15 * 60)
        player.pause()
        #expect(player.sleepTimer == nil && player.sleepDeadline == nil, "pausing by hand cancels the sleep timer")
    }

    @Test func choosingOffOrAnotherTimerReplacesIt() {
        let (_, player) = makePlayer()
        player.setSleepTimer(.after(30 * 60))
        player.setSleepTimer(.endOf(.surah))
        #expect(player.sleepTimer == .endOf(.surah) && player.sleepDeadline == nil)
        player.setSleepTimer(nil)
        #expect(player.sleepTimer == nil)
    }

    @Test func aTimerThatRunsOutWhileNothingPlaysJustClears() async throws {
        let (_, player) = makePlayer()
        player.setSleepTimer(.after(0))
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.sleepTimer == nil && player.status == .idle)
    }

    @Test func theEndOfAUnitIsItsLastAyah() {
        let (_, player) = makePlayer()
        #expect(player.lastAyah(of: AyahKey(surah: 2, ayah: 255), in: .surah) == AyahKey(surah: 2, ayah: 286))
        #expect(player.lastAyah(of: AyahKey(surah: 2, ayah: 255), in: .quran) == AyahKey(surah: 3, ayah: 200))
        player.unitEnd = { _, unit in unit == .page ? AyahKey(surah: 2, ayah: 257) : AyahKey(surah: 2, ayah: 286) }
        #expect(player.lastAyah(of: AyahKey(surah: 2, ayah: 255), in: .page) == AyahKey(surah: 2, ayah: 257))
    }

    @Test func theLastSessionsPositionCanBeContinued() {
        let (_, fresh) = makePlayer()
        #expect(fresh.resumableAyah == nil)
        let (_, relaunched) = makePlayer(lastPlayed: AyahKey(surah: 2, ayah: 255))
        #expect(relaunched.resumableAyah == AyahKey(surah: 2, ayah: 255), "relaunch keeps the last ayah, paused")
    }
}
