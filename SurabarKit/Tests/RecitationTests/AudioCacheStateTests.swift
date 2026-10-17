import Foundation
import Recitation
import Testing

private let chunk = CachedAudioState.chunkSize

@Test func chunksCoverTheFileWithAShortLastChunk() {
    var state = CachedAudioState(length: chunk * 2 + 100, etag: "a")
    #expect(state.chunkCount == 3)
    #expect(state.byteRange(ofChunk: 2) == chunk * 2 ..< chunk * 2 + 100)
    #expect(CachedAudioState.chunk(containing: chunk) == 1)
    state.chunks.insert(2)
    #expect(state.storedBytes == 100)
    #expect(!state.isComplete)
    state.chunks.insert(integersIn: 0 ..< 2)
    #expect(state.isComplete)
    #expect(state.fractionStored == 1)
}

@Test func missingRunsSkipStoredChunksAndRespectTheRunLimit() {
    var state = CachedAudioState(length: chunk * 10, etag: nil)
    state.chunks.insert(integersIn: 2 ..< 4)
    state.chunks.insert(7)
    #expect(state.missingRuns(in: 0 ..< 10, maxRun: 16) == [0 ..< 2, 4 ..< 7, 8 ..< 10])
    #expect(state.missingRuns(in: 0 ..< 10, maxRun: 2) == [0 ..< 2, 4 ..< 6, 6 ..< 7, 8 ..< 10])
    #expect(state.missingRuns(in: 5 ..< 40, maxRun: 16) == [5 ..< 7, 8 ..< 10], "clamped to the file")
    state.chunks.insert(integersIn: 0 ..< 10)
    #expect(state.missingRuns(in: 0 ..< 10, maxRun: 4).isEmpty)
}

@Test func stateRoundTripsThroughJSON() throws {
    var state = CachedAudioState(length: 12_345_678, etag: "\"abc\"", lastUsed: Date(timeIntervalSince1970: 1000))
    state.chunks.insert(integersIn: 3 ..< 9)
    state.pinned = true
    let decoded = try JSONDecoder().decode(CachedAudioState.self, from: JSONEncoder().encode(state))
    #expect(decoded == state)
}

@Test func parsesContentRange() {
    #expect(ContentRange("bytes 0-524287/112345678") == ContentRange("bytes 0-524287/112345678"))
    let range = ContentRange("bytes 524288-1048575/2000000")
    #expect(range?.first == 524_288 && range?.last == 1_048_575 && range?.total == 2_000_000)
    #expect(ContentRange("bytes */2000") == nil)
    #expect(ContentRange("bytes 10-5/20") == nil)
    #expect(ContentRange("items 0-1/2") == nil)
}

@Test func evictsLeastRecentlyUsedRecordingsButNeverDownloadsOrOnesInUse() {
    func file(_ chunks: Int, used: Double, pinned: Bool = false) -> CachedAudioState {
        var state = CachedAudioState(length: chunk * chunks, etag: nil, lastUsed: Date(timeIntervalSince1970: used))
        state.chunks.insert(integersIn: 0 ..< chunks)
        state.pinned = pinned
        return state
    }
    let files = ["old": file(4, used: 1), "pinned": file(50, used: 0, pinned: true), "playing": file(4, used: 2),
                 "middle": file(4, used: 3), "new": file(4, used: 4)]
    #expect(AudioCachePolicy.evictions(files, budget: chunk * 8, inUse: ["playing"]) == ["old", "middle"])
    #expect(AudioCachePolicy.evictions(files, budget: chunk * 16, inUse: []).isEmpty)
}
