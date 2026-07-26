import Foundation

enum ParseError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .invalid(let message): "Invalid MSG: \(message)"
        case .unsupported(let message): "Unsupported MSG: \(message)"
        }
    }
}

struct DirectoryEntry: Sendable {
    let name: String
    let type: UInt8
    let leftSibling: UInt32
    let rightSibling: UInt32
    let child: UInt32
    let startingSector: UInt32
    let size: UInt64
}

struct CompoundFile: Sendable {
    private static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let endOfChain = UInt32.max - 1
    private static let freeSector = UInt32.max
    private static let maxFileSize = 512 * 1024 * 1024

    let data: Data
    let sectorSize: Int
    let miniSectorSize: Int
    let miniStreamCutoff: UInt64
    let entries: [DirectoryEntry]

    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let miniStream: Data

    init(data: Data) throws {
        self.data = data
        guard data.count >= 512 else { throw ParseError.invalid("file is shorter than the CFB header") }
        guard data.count <= Self.maxFileSize else { throw ParseError.unsupported("file exceeds 512 MB") }
        guard Array(data.prefix(8)) == Self.signature else { throw ParseError.invalid("CFB signature mismatch") }
        guard try data.u16(at: 28) == 0xFFFE else { throw ParseError.invalid("unsupported byte order") }

        let majorVersion = try data.u16(at: 26)
        guard majorVersion == 3 || majorVersion == 4 else {
            throw ParseError.unsupported("CFB major version \(majorVersion)")
        }

        let sectorShift = try data.u16(at: 30)
        let miniSectorShift = try data.u16(at: 32)
        guard (majorVersion == 3 && sectorShift == 9) || (majorVersion == 4 && sectorShift == 12) else {
            throw ParseError.invalid("sector size does not match CFB version")
        }
        guard miniSectorShift == 6 else { throw ParseError.invalid("mini-sector size is not 64 bytes") }

        sectorSize = 1 << Int(sectorShift)
        miniSectorSize = 1 << Int(miniSectorShift)
        let fatSectorCount = Int(try data.u32(at: 44))
        let firstDirectorySector = try data.u32(at: 48)
        miniStreamCutoff = UInt64(try data.u32(at: 56))
        guard miniStreamCutoff == 4096 else { throw ParseError.invalid("unexpected mini-stream cutoff") }
        let firstMiniFatSector = try data.u32(at: 60)
        let miniFatSectorCount = Int(try data.u32(at: 64))
        let firstDifatSector = try data.u32(at: 68)
        let difatSectorCount = Int(try data.u32(at: 72))
        let maximumSectorCount = data.count / sectorSize
        guard fatSectorCount <= maximumSectorCount,
              miniFatSectorCount <= maximumSectorCount,
              difatSectorCount <= maximumSectorCount else {
            throw ParseError.invalid("header sector counts exceed the file size")
        }

        var fatSectors: [UInt32] = []
        for offset in stride(from: 76, to: 512, by: 4) {
            let sector = try data.u32(at: offset)
            if sector != Self.freeSector { fatSectors.append(sector) }
        }

        var difatSector = firstDifatSector
        var seenDifat = Set<UInt32>()
        for _ in 0..<difatSectorCount {
            guard difatSector < Self.endOfChain, seenDifat.insert(difatSector).inserted else {
                throw ParseError.invalid("cyclic or truncated DIFAT chain")
            }
            let offset = try Self.sectorOffset(difatSector, sectorSize: sectorSize, dataCount: data.count)
            for index in 0..<(sectorSize / 4 - 1) {
                let sector = try data.u32(at: offset + index * 4)
                if sector != Self.freeSector { fatSectors.append(sector) }
            }
            difatSector = try data.u32(at: offset + sectorSize - 4)
        }
        guard fatSectors.count >= fatSectorCount else { throw ParseError.invalid("FAT sector list is truncated") }

        var loadedFat: [UInt32] = []
        for sector in fatSectors.prefix(fatSectorCount) {
            let offset = try Self.sectorOffset(sector, sectorSize: sectorSize, dataCount: data.count)
            for index in 0..<(sectorSize / 4) {
                loadedFat.append(try data.u32(at: offset + index * 4))
            }
        }
        fat = loadedFat

        let miniFatBytes = try Self.readRegularChain(
            data: data,
            firstSector: firstMiniFatSector,
            fat: loadedFat,
            sectorSize: sectorSize,
            byteLimit: miniFatSectorCount * sectorSize
        )
        var loadedMiniFat: [UInt32] = []
        for offset in stride(from: 0, to: miniFatBytes.count, by: 4) {
            loadedMiniFat.append(try miniFatBytes.u32(at: offset))
        }
        miniFat = loadedMiniFat

        let directoryBytes = try Self.readRegularChain(
            data: data,
            firstSector: firstDirectorySector,
            fat: loadedFat,
            sectorSize: sectorSize
        )
        guard directoryBytes.count >= 128 else { throw ParseError.invalid("directory stream is empty") }
        guard directoryBytes.count / 128 <= 100_000 else { throw ParseError.unsupported("too many directory entries") }

        var loadedEntries: [DirectoryEntry] = []
        for offset in stride(from: 0, through: directoryBytes.count - 128, by: 128) {
            let nameByteCount = Int(try directoryBytes.u16(at: offset + 64))
            guard nameByteCount <= 64, nameByteCount % 2 == 0 else {
                throw ParseError.invalid("invalid directory name length")
            }
            let nameData = nameByteCount >= 2 ? directoryBytes.subdata(in: offset..<(offset + nameByteCount - 2)) : Data()
            let streamSize = majorVersion == 3
                ? UInt64(try directoryBytes.u32(at: offset + 120))
                : try directoryBytes.u64(at: offset + 120)
            loadedEntries.append(DirectoryEntry(
                name: String(data: nameData, encoding: .utf16LittleEndian) ?? "",
                type: try directoryBytes.u8(at: offset + 66),
                leftSibling: try directoryBytes.u32(at: offset + 68),
                rightSibling: try directoryBytes.u32(at: offset + 72),
                child: try directoryBytes.u32(at: offset + 76),
                startingSector: try directoryBytes.u32(at: offset + 116),
                size: streamSize
            ))
        }
        entries = loadedEntries

        guard let root = loadedEntries.first, root.type == 5 else {
            throw ParseError.invalid("root directory entry is missing")
        }
        miniStream = try Self.readRegularChain(
            data: data,
            firstSector: root.startingSector,
            fat: loadedFat,
            sectorSize: sectorSize,
            byteLimit: try Self.intSize(root.size)
        )
    }

    func children(of parentIndex: Int) throws -> [(Int, DirectoryEntry)] {
        guard entries.indices.contains(parentIndex) else { throw ParseError.invalid("directory index is out of range") }
        var result: [(Int, DirectoryEntry)] = []
        var visited = Set<UInt32>()

        func walk(_ id: UInt32) throws {
            guard id != UInt32.max else { return }
            guard let index = Int(exactly: id), entries.indices.contains(index) else {
                throw ParseError.invalid("directory tree points outside the directory")
            }
            guard visited.insert(id).inserted else { throw ParseError.invalid("cyclic directory tree") }
            let entry = entries[index]
            try walk(entry.leftSibling)
            result.append((index, entry))
            try walk(entry.rightSibling)
        }

        try walk(entries[parentIndex].child)
        return result
    }

    func child(named name: String, of parentIndex: Int) throws -> (Int, DirectoryEntry)? {
        try children(of: parentIndex).first { $0.1.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func stream(_ entry: DirectoryEntry) throws -> Data {
        guard entry.type == 2 else { throw ParseError.invalid("directory entry is not a stream") }
        let size = try Self.intSize(entry.size)
        guard size <= data.count else { throw ParseError.invalid("stream size exceeds file size") }
        guard size > 0 else { return Data() }

        if entry.size < miniStreamCutoff {
            return try Self.readMiniChain(
                miniStream: miniStream,
                firstSector: entry.startingSector,
                miniFat: miniFat,
                miniSectorSize: miniSectorSize,
                byteLimit: size
            )
        }
        return try Self.readRegularChain(
            data: data,
            firstSector: entry.startingSector,
            fat: fat,
            sectorSize: sectorSize,
            byteLimit: size
        )
    }

    private static func readRegularChain(
        data: Data,
        firstSector: UInt32,
        fat: [UInt32],
        sectorSize: Int,
        byteLimit: Int? = nil
    ) throws -> Data {
        if firstSector >= endOfChain { return Data() }
        var output = Data()
        var sector = firstSector
        var visited = Set<UInt32>()

        while sector < endOfChain && byteLimit.map({ output.count < $0 }) != false {
            guard visited.insert(sector).inserted else { throw ParseError.invalid("cyclic FAT chain") }
            guard let index = Int(exactly: sector), fat.indices.contains(index) else {
                throw ParseError.invalid("FAT chain points outside the FAT")
            }
            let offset = try sectorOffset(sector, sectorSize: sectorSize, dataCount: data.count)
            let remaining = byteLimit.map { $0 - output.count } ?? sectorSize
            output.append(data.subdata(in: offset..<(offset + min(sectorSize, remaining))))
            sector = fat[index]
        }
        if let byteLimit, output.count != byteLimit { throw ParseError.invalid("stream chain is truncated") }
        return output
    }

    private static func readMiniChain(
        miniStream: Data,
        firstSector: UInt32,
        miniFat: [UInt32],
        miniSectorSize: Int,
        byteLimit: Int
    ) throws -> Data {
        var output = Data()
        var sector = firstSector
        var visited = Set<UInt32>()

        while output.count < byteLimit {
            guard sector < endOfChain, visited.insert(sector).inserted else {
                throw ParseError.invalid("cyclic or truncated miniFAT chain")
            }
            guard let index = Int(exactly: sector), miniFat.indices.contains(index) else {
                throw ParseError.invalid("miniFAT chain points outside the miniFAT")
            }
            let (offset, overflow) = index.multipliedReportingOverflow(by: miniSectorSize)
            guard !overflow, offset <= miniStream.count - min(miniSectorSize, byteLimit - output.count) else {
                throw ParseError.invalid("mini stream points outside its container")
            }
            let count = min(miniSectorSize, byteLimit - output.count)
            output.append(miniStream.subdata(in: offset..<(offset + count)))
            sector = miniFat[index]
        }
        return output
    }

    private static func sectorOffset(_ sector: UInt32, sectorSize: Int, dataCount: Int) throws -> Int {
        guard let index = Int(exactly: sector) else { throw ParseError.invalid("sector index is too large") }
        let (offset, overflow) = (index + 1).multipliedReportingOverflow(by: sectorSize)
        guard !overflow, offset >= 0, offset <= dataCount - sectorSize else {
            throw ParseError.invalid("sector points outside the file")
        }
        return offset
    }

    private static func intSize(_ value: UInt64) throws -> Int {
        guard let size = Int(exactly: value) else { throw ParseError.unsupported("stream is too large") }
        return size
    }
}

extension Data {
    func u8(at offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < count else { throw ParseError.invalid("read outside file bounds") }
        return self[startIndex + offset]
    }

    func u16(at offset: Int) throws -> UInt16 {
        UInt16(try u8(at: offset)) | UInt16(try u8(at: offset + 1)) << 8
    }

    func u32(at offset: Int) throws -> UInt32 {
        UInt32(try u16(at: offset)) | UInt32(try u16(at: offset + 2)) << 16
    }

    func u64(at offset: Int) throws -> UInt64 {
        UInt64(try u32(at: offset)) | UInt64(try u32(at: offset + 4)) << 32
    }
}
