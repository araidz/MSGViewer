import Foundation

/// Minimal CFB v3 writer for test fixtures. Every stream is stored in regular sectors,
/// so each stream must be at least 4096 bytes (the mini-stream cutoff).
struct CFBEntry {
    static let none = UInt32.max
    var name: String
    var type: UInt8 // 1 storage, 2 stream, 5 root
    var left = none
    var right = none
    var child = none
    var stream = Data()
}

indirect enum CFBNode {
    case storage(String, [CFBNode])
    case stream(String, Data)

    static func utf16(_ name: String, _ text: String) -> CFBNode {
        .stream(name, text.data(using: .utf16LittleEndian)!)
    }

    static func message(subject: String, body: String, extra: [CFBNode] = []) -> [CFBNode] {
        let pad = String(repeating: " ", count: 2100)
        return [utf16("__substg1.0_0037001F", subject + pad), utf16("__substg1.0_1000001F", body + pad)] + extra
    }

    static func attachedMessage(index: Int, _ children: [CFBNode]) -> CFBNode {
        .storage(String(format: "__attach_version1.0_#%08X", index), [.storage("__substg1.0_3701000D", children)])
    }
}

/// Flattens a tree into directory entries (siblings chained through `right`, so in-order = declared order).
func cfbEntries(root: [CFBNode]) -> [CFBEntry] {
    var entries: [CFBEntry] = [CFBEntry(name: "Root Entry", type: 5)]
    func add(_ nodes: [CFBNode]) -> UInt32 {
        var indices: [Int] = []
        for node in nodes {
            switch node {
            case .stream(let name, let data):
                entries.append(CFBEntry(name: name, type: 2, stream: data))
                indices.append(entries.count - 1)
            case .storage(let name, let children):
                entries.append(CFBEntry(name: name, type: 1))
                let index = entries.count - 1
                indices.append(index)
                entries[index].child = add(children)
            }
        }
        for (position, index) in indices.enumerated() where position + 1 < indices.count {
            entries[index].right = UInt32(indices[position + 1])
        }
        return indices.first.map(UInt32.init) ?? CFBEntry.none
    }
    entries[0].child = add(root)
    return entries
}

func buildCFB(_ entries: [CFBEntry]) -> Data {
    let sector = 512
    let endOfChain: UInt32 = 0xFFFFFFFE
    let fatSect: UInt32 = 0xFFFFFFFD
    let directorySectors = max(1, (entries.count * 128 + sector - 1) / sector)
    let streamSectors = entries.map { ($0.stream.count + sector - 1) / sector }
    let dataSectors = directorySectors + streamSectors.reduce(0, +)
    var fatSectors = 1
    while (fatSectors + dataSectors + 127) / 128 > fatSectors { fatSectors += 1 }

    var fat = [UInt32](repeating: fatSect, count: fatSectors)
    func chain(_ count: Int) -> UInt32 {
        let start = UInt32(fat.count)
        for index in 0..<count { fat.append(index == count - 1 ? endOfChain : UInt32(fat.count + 1)) }
        return start
    }
    let directoryStart = chain(directorySectors)
    let starts = streamSectors.map { $0 == 0 ? endOfChain : chain($0) }
    while fat.count % 128 != 0 { fat.append(CFBEntry.none) }

    var out = Data(count: sector)
    func put16(_ offset: Int, _ value: UInt16) { out[offset] = UInt8(value & 0xFF); out[offset + 1] = UInt8(value >> 8) }
    func put32(_ offset: Int, _ value: UInt32) { put16(offset, UInt16(value & 0xFFFF)); put16(offset + 2, UInt16(value >> 16)) }
    out.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    put16(24, 0x3E); put16(26, 3); put16(28, 0xFFFE); put16(30, 9); put16(32, 6)
    put32(44, UInt32(fatSectors)); put32(48, directoryStart); put32(56, 4096)
    put32(60, endOfChain); put32(64, 0); put32(68, endOfChain); put32(72, 0)
    for index in 0..<109 { put32(76 + index * 4, index < fatSectors ? UInt32(index) : CFBEntry.none) }

    for value in fat { out.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init)) }
    var directory = Data()
    for (index, entry) in entries.enumerated() {
        var record = Data(count: 128)
        let name = entry.name.data(using: .utf16LittleEndian)!
        record.replaceSubrange(0..<name.count, with: name)
        let fields: [(Int, UInt32)] = [(68, entry.left), (72, entry.right), (76, entry.child), (116, starts[index]), (120, UInt32(entry.stream.count))]
        for (offset, value) in fields { record.replaceSubrange(offset..<(offset + 4), with: withUnsafeBytes(of: value.littleEndian, Array.init)) }
        record[64] = UInt8(name.count + 2); record[66] = entry.type; record[67] = 1
        directory.append(record)
    }
    directory.count = directorySectors * sector
    out.append(directory)
    for entry in entries where !entry.stream.isEmpty {
        var padded = entry.stream
        padded.count = ((padded.count + sector - 1) / sector) * sector
        out.append(padded)
    }
    return out
}

/// Uncompressed ("MELA") RTF container, which the decompressor accepts without a CRC.
func melaRTF(_ rtf: String) -> Data {
    var data = Data()
    for value in [UInt32(rtf.utf8.count + 12), UInt32(rtf.utf8.count), 0x414C454D, 0] {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
    }
    data.append(contentsOf: rtf.utf8)
    return data
}
