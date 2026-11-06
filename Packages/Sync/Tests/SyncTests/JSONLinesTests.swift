import Foundation
import Testing
@testable import Sync

/// Feeds fixed chunks to `JSONLines`.
struct Chunks: AsyncSequence {
    typealias Element = ArraySlice<UInt8>
    let chunks: [[UInt8]]

    struct AsyncIterator: AsyncIteratorProtocol {
        var remaining: [[UInt8]]
        mutating func next() async -> ArraySlice<UInt8>? {
            remaining.isEmpty ? nil : ArraySlice(remaining.removeFirst())
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(remaining: chunks) }
}

private func lines(_ chunks: [String]) async throws -> [String] {
    var result: [String] = []
    for try await line in JSONLines(Chunks(chunks: chunks.map { Array($0.utf8) })) {
        result.append(String(decoding: line, as: UTF8.self))
    }
    return result
}

@Suite struct JSONLinesTests {
    @Test func splitsWholeLines() async throws {
        #expect(try await lines(["a\nb\n"]) == ["a", "b"])
    }

    @Test func joinsLinesSplitAcrossChunks() async throws {
        #expect(try await lines(["{\"type\":", "\"x\"}\n{\"t", "ype\":2}\n"]) == ["{\"type\":\"x\"}", "{\"type\":2}"])
    }

    @Test func emitsFinalLineWithoutNewline() async throws {
        #expect(try await lines(["a\nb"]) == ["a", "b"])
    }

    @Test func dropsEmptyLinesAndCarriageReturns() async throws {
        #expect(try await lines(["a\r\n\n\nb\r\n"]) == ["a", "b"])
    }

    @Test func handlesMultibyteCharacterSplitAcrossChunks() async throws {
        let bytes = Array("Zürich\n".utf8)
        let split = [Array(bytes[..<2]), Array(bytes[2...])] // splits inside "ü"
        var result: [String] = []
        for try await line in JSONLines(Chunks(chunks: split)) {
            result.append(String(decoding: line, as: UTF8.self))
        }
        #expect(result == ["Zürich"])
    }

    @Test func emptyStream() async throws {
        #expect(try await lines([]) == [])
        #expect(try await lines(["", "\n"]) == [])
    }

    @Test func manyLinesInOneChunk() async throws {
        let input = (0..<5000).map { "line\($0)" }
        #expect(try await lines([input.joined(separator: "\n") + "\n"]) == input)
    }
}
