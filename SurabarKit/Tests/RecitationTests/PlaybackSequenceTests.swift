import Foundation
import MushafRendering
import Recitation
import Testing

private let counts = [7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128, 111, 110, 98, 135,
    112, 78, 118, 64, 77, 227, 93, 88, 69, 60, 34, 30, 73, 54, 45, 83, 182, 88, 75, 85, 54, 53, 89, 59, 37, 35, 38, 29,
    18, 45, 60, 49, 62, 55, 78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30, 52, 52, 44, 28, 28, 20, 56, 40, 31, 50,
    40, 46, 42, 29, 19, 36, 25, 22, 17, 19, 26, 30, 20, 15, 21, 11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3, 6,
    3, 5, 4, 5, 6]

private func key(_ surah: Int, _ ayah: Int) -> AyahKey { AyahKey(surah: surah, ayah: ayah) }

/// Plays a sequence from an ayah, returning up to `limit` steps as compact strings like "b2:1" or "2:1#2".
private func run(_ sequence: PlaybackSequence, from ayah: AyahKey, limit: Int = 50) -> [String] {
    var step = sequence.start(at: ayah)
    var pass = 1
    var out: [String] = []
    while out.count < limit {
        out.append(step.kind == .basmalah ? "b\(step.ayah)" : step.repetition > 1 ? "\(step.ayah)#\(step.repetition)" : "\(step.ayah)")
        guard let next = sequence.step(after: step, rangePass: pass) else { break }
        (step, pass) = next
    }
    return out
}

@Test func numbersAyahsAcrossTheQuranLikeTheAudioCDN() {
    let sequence = PlaybackSequence(ayahCounts: counts, boundaryEnd: key(114, 6))
    #expect(counts.reduce(0, +) == 6236)
    #expect(sequence.globalNumber(of: key(1, 1)) == 1)
    #expect(sequence.globalNumber(of: key(2, 1)) == 8)
    #expect(sequence.globalNumber(of: key(2, 255)) == 262)
    #expect(sequence.globalNumber(of: key(114, 6)) == 6236)
}

@Test func basmalahPrecedesSurahStartsExceptAlFatihahAndAtTawbah() {
    var sequence = PlaybackSequence(ayahCounts: counts, boundaryEnd: key(114, 6))
    #expect(run(sequence, from: key(1, 6), limit: 4) == ["1:6", "1:7", "b2:1", "2:1"])
    #expect(run(sequence, from: key(8, 75), limit: 2) == ["8:75", "9:1"])
    #expect(run(sequence, from: key(1, 1), limit: 1) == ["1:1"])
    sequence.playsBasmalah = false
    #expect(run(sequence, from: key(1, 7), limit: 2) == ["1:7", "2:1"])
}

@Test func stopsAtTheBoundary() {
    let sequence = PlaybackSequence(ayahCounts: counts, boundaryEnd: key(1, 7))
    #expect(run(sequence, from: key(1, 5)) == ["1:5", "1:6", "1:7"])
    let end = PlaybackSequence(ayahCounts: counts, boundaryEnd: key(114, 6))
    #expect(run(end, from: key(114, 5)) == ["114:5", "114:6"])
}

@Test func repeatsEachAyahWithPausesBetweenRepeats() {
    var sequence = PlaybackSequence(ayahCounts: counts, boundaryEnd: key(1, 3))
    sequence.ayahRepeats = .times(3)
    #expect(run(sequence, from: key(1, 2)) == ["1:2", "1:2#2", "1:2#3", "1:3", "1:3#2", "1:3#3"])
    var step = sequence.start(at: key(1, 2))
    #expect(!step.pausesBefore)
    step = sequence.step(after: step)!.step
    #expect(step.pausesBefore)
    step = sequence.step(after: sequence.step(after: step)!.step)!.step
    #expect(!step.pausesBefore, "moving on to the next ayah does not pause")
}

@Test func rangeLoopsAcrossSurahsAndOverridesTheBoundary() {
    var sequence = PlaybackSequence(ayahCounts: counts, boundaryEnd: key(1, 7))
    sequence.range = key(1, 7) ... key(2, 1)
    sequence.rangeRepeats = .times(2)
    #expect(run(sequence, from: key(1, 7)) == ["1:7", "b2:1", "2:1", "1:7", "b2:1", "2:1"])
    sequence.rangeRepeats = .forever
    #expect(run(sequence, from: key(1, 7), limit: 9).count == 9)
    // Repeats and range loops combine.
    sequence.range = key(1, 1) ... key(1, 2)
    sequence.ayahRepeats = .times(2)
    sequence.rangeRepeats = .times(2)
    #expect(run(sequence, from: key(1, 1)) == ["1:1", "1:1#2", "1:2", "1:2#2", "1:1", "1:1#2", "1:2", "1:2#2"])
}

@Test func aPassStartedPartWayThroughIsPassZero() {
    var sequence = PlaybackSequence(ayahCounts: counts, boundaryEnd: key(1, 7))
    sequence.range = key(1, 1) ... key(1, 3)
    sequence.rangeRepeats = .times(2)
    var step = sequence.start(at: key(1, 2))
    var pass = 0
    var out: [String] = []
    while out.count < 20 {
        out.append("\(step.ayah)")
        guard let next = sequence.step(after: step, rangePass: pass) else { break }
        (step, pass) = next
    }
    #expect(out == ["1:2", "1:3", "1:1", "1:2", "1:3", "1:1", "1:2", "1:3"])
}

@Test func startingOutsideTheRangeJumpsIntoIt() {
    var sequence = PlaybackSequence(ayahCounts: counts, boundaryEnd: key(114, 6))
    sequence.range = key(2, 1) ... key(2, 2)
    sequence.rangeRepeats = .times(1)
    #expect(run(sequence, from: key(1, 7)) == ["1:7"])
    sequence.rangeRepeats = .times(2)
    #expect(run(sequence, from: key(1, 7)) == ["1:7", "b2:1", "2:1", "2:2"])
}

@Test func decodesSurahTimingsWithTheRecordedOpening() throws {
    let url = URL(string: "https://cdn.mp3quran.net/audio/mishary-alafasy/r1/112.mp3")!
    let json = """
        [{"ayah":1,"polygon":null,"start_time":7539,"end_time":10400,"x":null,"y":null,"page":null},
         {"ayah":2,"start_time":10400,"end_time":13060},{"ayah":3,"start_time":13060,"end_time":16130},
         {"ayah":4,"start_time":16130,"end_time":21000}]
        """
    let audio = try RecitationAPI.decodeTimings(Data(json.utf8), ayahCount: 4, surah: 112, audioURL: url)
    #expect(audio.span(of: key(112, 2)) == SurahAudio.Span(from: 10400, to: 13060))
    #expect(audio.opening == SurahAudio.Span(from: 0, to: 7539))
    #expect(throws: RecitationAPI.TimingsError.self) {
        try RecitationAPI.decodeTimings(Data(json.utf8), ayahCount: 5, surah: 112, audioURL: url)
    }
    // A file that starts straight at ayah 1 has no recorded basmalah.
    let direct = #"[{"ayah":1,"start_time":63,"end_time":2000},{"ayah":2,"start_time":2000,"end_time":4000}]"#
    #expect(try RecitationAPI.decodeTimings(Data(direct.utf8), ayahCount: 2, surah: 108, audioURL: url).opening == nil)
    // Al-Fatihah's entry 0 is the isti'adhah; 1:1 itself is the basmalah.
    let fatihah = #"[{"ayah":0,"start_time":0,"end_time":2731},{"ayah":1,"start_time":2731,"end_time":5720}]"#
    let opening = try RecitationAPI.decodeTimings(Data(fatihah.utf8), ayahCount: 1, surah: 1, audioURL: url)
    #expect(opening.span(of: key(1, 1)) == SurahAudio.Span(from: 2731, to: 5720))
    #expect(RecitationAPI.timingsURL(reciter: 123, surah: 2).absoluteString == "https://mp3quran.net/api/v3/ayat_timing?surah=2&read=123")
}

@Test func reciterNamesAndAudioURLs() {
    let reciter = Reciter(id: 51, name: "Abdul Basit Abdus-Samad", style: "Mujawwad",
                          server: URL(string: "https://cdn.mp3quran.net/audio/abdulbasit-abdulsamad/r1/")!)
    #expect(reciter.displayName == "Abdul Basit Abdus-Samad (Mujawwad)")
    #expect(reciter.audioURL(surah: 2).absoluteString == "https://cdn.mp3quran.net/audio/abdulbasit-abdulsamad/r1/002.mp3")
}
