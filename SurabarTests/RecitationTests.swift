import Foundation
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
