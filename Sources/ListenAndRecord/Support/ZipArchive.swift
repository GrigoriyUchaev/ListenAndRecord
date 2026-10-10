import Foundation

/// Tiny ZIP writer (stored entries, no compression) — enough to build .docx files
/// without third-party dependencies.
struct ZipArchive {
    private struct Entry {
        let name: Data
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    private var entries: [Entry] = []
    private var body = Data()
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980)
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dateBits: Int = (year << 9) | (month << 5) | day
        dosTime = UInt16(truncatingIfNeeded: time)
        dosDate = UInt16(truncatingIfNeeded: dateBits)
    }

    mutating func add(_ path: String, _ data: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let entry = Entry(name: name, data: data, crc: crc, offset: UInt32(body.count))
        body.appendLE(UInt32(0x04034b50))
        body.appendLE(UInt16(20))        // version needed
        body.appendLE(UInt16(0x0800))    // UTF-8 names
        body.appendLE(UInt16(0))         // stored
        body.appendLE(dosTime)
        body.appendLE(dosDate)
        body.appendLE(crc)
        body.appendLE(UInt32(data.count))
        body.appendLE(UInt32(data.count))
        body.appendLE(UInt16(name.count))
        body.appendLE(UInt16(0))
        body.append(name)
        body.append(data)
        entries.append(entry)
    }

    mutating func add(_ path: String, _ text: String) {
        add(path, Data(text.utf8))
    }

    func archive() -> Data {
        var out = body
        let directoryOffset = UInt32(out.count)
        var directory = Data()
        for e in entries {
            directory.appendLE(UInt32(0x02014b50))
            directory.appendLE(UInt16(20))   // made by
            directory.appendLE(UInt16(20))   // needed
            directory.appendLE(UInt16(0x0800))
            directory.appendLE(UInt16(0))
            directory.appendLE(dosTime)
            directory.appendLE(dosDate)
            directory.appendLE(e.crc)
            directory.appendLE(UInt32(e.data.count))
            directory.appendLE(UInt32(e.data.count))
            directory.appendLE(UInt16(e.name.count))
            directory.appendLE(UInt16(0))    // extra
            directory.appendLE(UInt16(0))    // comment
            directory.appendLE(UInt16(0))    // disk
            directory.appendLE(UInt16(0))    // internal attrs
            directory.appendLE(UInt32(0))    // external attrs
            directory.appendLE(e.offset)
            directory.append(e.name)
        }
        out.append(directory)
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(directory.count))
        out.appendLE(directoryOffset)
        out.appendLE(UInt16(0))
        return out
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
