import Foundation

enum CompressedRTF {
    private static let compressedMagic: UInt32 = 0x75465A4C // LZFu
    private static let uncompressedMagic: UInt32 = 0x414C454D // MELA
    private static let initialDictionary = Data("{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss \\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par \\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx".utf8)

    static func decompress(_ data: Data) throws -> Data {
        guard data.count >= 16 else { throw ParseError.invalid("compressed RTF header is truncated") }
        let compressedSize = Int(try data.u32(at: 0))
        let rawSize = Int(try data.u32(at: 4))
        let magic = try data.u32(at: 8)
        let expectedCRC = try data.u32(at: 12)
        let end = compressedSize + 4
        guard compressedSize >= 12, end <= data.count, rawSize <= 64 * 1024 * 1024 else {
            throw ParseError.invalid("compressed RTF sizes are invalid")
        }

        if magic == uncompressedMagic {
            guard 16 + rawSize <= end else { throw ParseError.invalid("uncompressed RTF is truncated") }
            return data.subdata(in: 16..<(16 + rawSize))
        }
        guard magic == compressedMagic else { throw ParseError.unsupported("unknown compressed RTF format") }
        guard crc(data[16..<end]) == expectedCRC else { throw ParseError.invalid("compressed RTF checksum mismatch") }

        var dictionary = [UInt8](repeating: 0, count: 4096)
        dictionary.replaceSubrange(0..<initialDictionary.count, with: initialDictionary)
        var writeOffset = initialDictionary.count
        var cursor = 16
        var output = Data()
        output.reserveCapacity(rawSize)

        while cursor < end, output.count < rawSize {
            let control = try data.u8(at: cursor)
            cursor += 1

            for bit in 0..<8 where output.count < rawSize {
                if control & (1 << bit) == 0 {
                    guard cursor < end else { throw ParseError.invalid("compressed RTF literal is truncated") }
                    let byte = try data.u8(at: cursor)
                    cursor += 1
                    dictionary[writeOffset] = byte
                    writeOffset = (writeOffset + 1) & 0xFFF
                    output.append(byte)
                } else {
                    guard cursor + 1 < end else { throw ParseError.invalid("compressed RTF reference is truncated") }
                    let reference = UInt16(try data.u8(at: cursor)) << 8 | UInt16(try data.u8(at: cursor + 1))
                    cursor += 2
                    var readOffset = Int(reference >> 4)
                    if readOffset == writeOffset {
                        guard output.count == rawSize else { throw ParseError.invalid("compressed RTF ended early") }
                        return output
                    }
                    let length = Int(reference & 0xF) + 2
                    for _ in 0..<length where output.count < rawSize {
                        let byte = dictionary[readOffset]
                        readOffset = (readOffset + 1) & 0xFFF
                        dictionary[writeOffset] = byte
                        writeOffset = (writeOffset + 1) & 0xFFF
                        output.append(byte)
                    }
                }
            }
        }
        guard output.count == rawSize else { throw ParseError.invalid("compressed RTF output is truncated") }
        return output
    }

    private static func crc(_ bytes: Data.SubSequence) -> UInt32 {
        var value: UInt32 = 0
        for byte in bytes {
            var tableValue = (value ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                tableValue = tableValue & 1 == 1 ? 0xEDB88320 ^ (tableValue >> 1) : tableValue >> 1
            }
            value = tableValue ^ (value >> 8)
        }
        return value
    }
}
