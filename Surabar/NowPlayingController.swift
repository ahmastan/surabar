import AppKit
import CoreAudio
import MediaPlayer
import MushafRendering

/// Control Center's Now Playing, the keyboard's media keys, and headphone controls, which work with the
/// reader closed. Previous and next move by ayah, like the player's inner buttons.
@MainActor
final class NowPlayingController {
    private let player: RecitationPlayer
    private let state: AppState
    private let surahName: (Int) -> String
    /// Set once recitation has played, so Surabar does not claim the media keys before it is used.
    private var hasPlayed = false
    /// The app icon, shown as the artwork.
    private let artwork: MPMediaItemArtwork = {
        let icon = NSApp.applicationIconImage ?? NSImage()
        return MPMediaItemArtwork(boundsSize: NSSize(width: 512, height: 512)) { _ in icon }
    }()

    init(player: RecitationPlayer, state: AppState, surahName: @escaping (Int) -> String) {
        self.player = player
        self.state = state
        self.surahName = surahName
        registerCommands()
        player.onSeek = { [weak self] in self?.update() }
        observe()
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.run { $0.resume() } ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.run { $0.player.pause() } ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.run { $0.player.togglePlayPause(startingAt: $0.player.ayah ?? $0.state.selectedAyah) } ?? .commandFailed
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.run { $0.player.stepAyah(1, from: $0.state.selectedAyah) } ?? .commandFailed
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.run { $0.player.stepAyah(-1, from: $0.state.selectedAyah) } ?? .commandFailed
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return self?.run { controller in
                let duration = controller.player.duration
                if duration > 0 { controller.player.seek(toFraction: position / duration) }
            } ?? .commandFailed
        }
        for command in [center.skipForwardCommand, center.skipBackwardCommand, center.seekForwardCommand,
                        center.seekBackwardCommand, center.changePlaybackRateCommand] {
            command.isEnabled = false
        }
    }

    /// Remote commands arrive on the main thread.
    nonisolated private func run(_ action: @escaping @MainActor (NowPlayingController) -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak self] in
            guard let self else { return }
            action(self)
        }
        return .success
    }

    private func resume() {
        guard !player.isActive else { return }
        player.togglePlayPause(startingAt: player.ayah ?? state.selectedAyah)
    }

    private func observe() {
        withObservationTracking {
            _ = (player.status, player.step, player.duration, player.reciter.id, state.speed)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        let center = MPNowPlayingInfoCenter.default()
        if player.isActive { hasPlayed = true }
        guard hasPlayed, let step = player.step else { return }
        let ayah = step.ayah
        let title = step.kind == .basmalah ? "\(surahName(ayah.surah)) · Basmalah" : "\(surahName(ayah.surah)) · Ayah \(ayah.ayah)"
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: player.reciter.displayName,
            MPMediaItemPropertyAlbumTitle: "Surah \(ayah.surah) · \(surahName(ayah.surah))",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.status == .playing ? state.speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: state.speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyArtwork: artwork,
        ]
        center.playbackState = player.isActive ? .playing : .paused
    }
}

/// Pauses recitation when headphones are disconnected (sound would otherwise move to the speakers, as
/// Music avoids) and when the Mac goes to sleep.
@MainActor
final class PlaybackInterruptions {
    private let pause: () -> Void
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var wasSpeakers = true
    private var sleepObserver: NSObjectProtocol?

    init(pause: @escaping () -> Void) {
        self.pause = pause
        device = Self.defaultOutputDevice()
        wasSpeakers = Self.isBuiltInSpeakers(device)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        watchDataSource(of: device)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    /// The output moved from headphones (wired, Bluetooth, USB) to the built-in speakers.
    private func outputChanged() {
        let current = Self.defaultOutputDevice()
        if current != device {
            device = current
            watchDataSource(of: current)
        }
        let speakers = Self.isBuiltInSpeakers(current)
        if speakers && !wasSpeakers { pause() }
        wasSpeakers = speakers
    }

    /// Wired headphones change the built-in device's data source rather than the device.
    private func watchDataSource(of device: AudioObjectID) {
        var address = Self.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return }
        AudioObjectAddPropertyListenerBlock(device, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func isBuiltInSpeakers(_ device: AudioObjectID) -> Bool {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyTransportType)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        var source: UInt32 = 0
        var sourceAddress = Self.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectGetPropertyData(device, &sourceAddress, 0, nil, &size, &source) == noErr else { return true }
        return source != 0x6864_706E  // 'hdpn', wired headphones
    }
}
