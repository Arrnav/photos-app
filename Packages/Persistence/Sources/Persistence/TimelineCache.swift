import Foundation

/// The Library's last list of items in a compact file, read at launch so the grid shows at
/// once; the database's own (slower) query replaces it a moment later. Not a source of
/// truth: an unreadable or old-format file is simply ignored.
public enum TimelineCache {
    private static let magic: UInt32 = 0x544C_4331 // "TLC1"

    public static func encode(_ items: [TimelineItem]) -> Data {
        var writer = Writer()
        writer.reserve(items.count * 120)
        writer.u32(magic)
        writer.u32(UInt32(items.count))
        for item in items {
            writer.string(item.id)
            writer.double(item.date.timeIntervalSinceReferenceDate)
            var flags: UInt8 = 0
            if item.isVideo { flags |= 1 }
            if item.isFavorite { flags |= 2 }
            if item.isLivePhoto { flags |= 4 }
            if item.isEdited { flags |= 8 }
            if item.hasCamera { flags |= 16 }
            if item.isScreenshot { flags |= 32 }
            if item.isRemote { flags |= 64 }
            writer.u8(flags)
            writer.u32(item.durationMs.map { UInt32(clamping: $0) } ?? .max)
            writer.optionalString(item.thumbhash)
            writer.double(item.aspectRatio)
            writer.double(item.uploadedAt?.timeIntervalSinceReferenceDate ?? .nan)
            writer.string(item.ownerID)
            writer.optionalString(item.localID)
        }
        return writer.data
    }

    public static func decode(_ data: Data) -> [TimelineItem]? {
        var reader = Reader(data: data)
        guard reader.u32() == magic, let count = reader.u32(), count < 2_000_000 else { return nil }
        var items: [TimelineItem] = []
        items.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let id = reader.string(), let date = reader.double(), let flags = reader.u8(), let duration = reader.u32(),
                  let thumbhash = reader.optionalString(), let ratio = reader.double(), let uploaded = reader.double(),
                  let owner = reader.string(), let localID = reader.optionalString() else { return nil }
            items.append(TimelineItem(
                id: id, date: Date(timeIntervalSinceReferenceDate: date), isVideo: flags & 1 != 0,
                durationMs: duration == .max ? nil : Int(duration), isFavorite: flags & 2 != 0, isLivePhoto: flags & 4 != 0,
                thumbhash: thumbhash, aspectRatio: ratio, uploadedAt: uploaded.isNaN ? nil : Date(timeIntervalSinceReferenceDate: uploaded),
                isEdited: flags & 8 != 0, hasCamera: flags & 16 != 0, isScreenshot: flags & 32 != 0, ownerID: owner,
                localID: localID, isRemote: flags & 64 != 0
            ))
        }
        return reader.isAtEnd ? items : nil
    }

    public static func read(from url: URL) -> [TimelineItem]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return decode(data)
    }

    public static func write(_ items: [TimelineItem], to url: URL) {
        try? encode(items).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private struct Writer {
        var data = Data()
        mutating func reserve(_ n: Int) { data.reserveCapacity(n) }
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func double(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        mutating func string(_ s: String) {
            let bytes = Array(s.utf8.prefix(Int(UInt16.max) - 1))
            u16(UInt16(bytes.count))
            data.append(contentsOf: bytes)
        }
        mutating func optionalString(_ s: String?) {
            if let s { string(s) } else { u16(.max) }
        }
    }

    private struct Reader {
        let data: Data
        var offset: Int

        init(data: Data) {
            self.data = data
            offset = data.startIndex
        }

        var isAtEnd: Bool { offset == data.endIndex }


        private mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.endIndex else { return nil }
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { buffer in
                data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: offset..<(offset + size))
            }
            offset += size
            return T(littleEndian: value)
        }

        mutating func u8() -> UInt8? { read(UInt8.self) }
        mutating func u16() -> UInt16? { read(UInt16.self) }
        mutating func u32() -> UInt32? { read(UInt32.self) }
        mutating func double() -> Double? { read(UInt64.self).map(Double.init(bitPattern:)) }

        mutating func string() -> String? {
            guard let length = u16(), length != .max else { return nil }
            return rawString(Int(length))
        }

        /// .some(nil) for a stored nil, nil when the data is cut short.
        mutating func optionalString() -> String?? {
            guard let length = u16() else { return nil }
            if length == .max { return .some(nil) }
            guard let text = rawString(Int(length)) else { return nil }
            return .some(text)
        }

        private mutating func rawString(_ length: Int) -> String? {
            guard offset + length <= data.endIndex else { return nil }
            let text = String(decoding: data[offset..<(offset + length)], as: UTF8.self)
            offset += length
            return text
        }
    }
}
