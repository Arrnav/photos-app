import Foundation

/// Splits a stream of byte chunks into newline-terminated lines. Chunks may
/// end anywhere, including inside a multi-byte UTF-8 sequence. Empty lines are
/// dropped; a final line without a trailing newline is still emitted.
public struct JSONLines<Base: AsyncSequence>: AsyncSequence where Base.Element == ArraySlice<UInt8> {
    public typealias Element = Data

    let base: Base

    public init(_ base: Base) {
        self.base = base
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var upstream: Base.AsyncIterator
        var buffer: [UInt8] = []
        /// Start of the unread part of `buffer`.
        var lineStart = 0
        /// Where to resume looking for a newline (bytes before it have none).
        var scanFrom = 0
        var finished = false

        public mutating func next() async throws -> Data? {
            while true {
                if let newline = buffer[scanFrom...].firstIndex(of: UInt8(ascii: "\n")) {
                    var end = newline
                    if end > lineStart, buffer[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                    let line = Data(buffer[lineStart..<end])
                    lineStart = newline + 1
                    scanFrom = lineStart
                    if line.isEmpty { continue }
                    return line
                }
                scanFrom = buffer.count

                if finished {
                    guard lineStart < buffer.count else { return nil }
                    let line = Data(buffer[lineStart...])
                    lineStart = buffer.count
                    return line
                }

                // Drop consumed bytes before growing the buffer.
                if lineStart > 0 {
                    buffer.removeSubrange(..<lineStart)
                    scanFrom -= lineStart
                    lineStart = 0
                }
                if let chunk = try await upstream.next() {
                    buffer.append(contentsOf: chunk)
                } else {
                    finished = true
                }
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(upstream: base.makeAsyncIterator())
    }
}
