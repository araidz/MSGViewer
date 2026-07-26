import Foundation

enum RTFHTMLExtractor {
    private static let htmlTag = Array("{\\*\\htmltag".utf8)
    private static let htmlRtf = Array("\\htmlrtf".utf8)

    static func extract(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard data.range(of: Data("\\fromhtml1".utf8)) != nil,
              let start = find(htmlTag, in: bytes, from: 0) else { return nil }

        let encoding = stringEncoding(in: bytes)
        var output = ""
        var pending = Data()
        var index = start
        var skipRTF = false

        func flush() {
            guard !pending.isEmpty else { return }
            output += String(data: pending, encoding: encoding)
                ?? String(data: pending, encoding: .isoLatin1)
                ?? ""
            pending.removeAll(keepingCapacity: true)
        }

        while index < bytes.count {
            if matches(htmlTag, in: bytes, at: index), let end = matchingBrace(in: bytes, at: index) {
                flush()
                var content = index + htmlTag.count
                while content < end, isDigit(bytes[content]) { content += 1 }
                if content < end, bytes[content] == 0x20 { content += 1 }
                decode(bytes, range: content..<end, encoding: encoding, into: &output)
                index = end + 1
                continue
            }

            if matches(htmlRtf, in: bytes, at: index) {
                flush()
                index += htmlRtf.count
                if index < bytes.count, bytes[index] == 0x30 {
                    skipRTF = false
                    index += 1
                } else {
                    skipRTF = true
                }
                if index < bytes.count, bytes[index] == 0x20 { index += 1 }
                continue
            }

            if skipRTF {
                index += 1
                continue
            }

            switch bytes[index] {
            case 0x7B: // {
                flush()
                if let end = matchingBrace(in: bytes, at: index) {
                    index = end + 1
                } else {
                    index += 1
                }
            case 0x7D, 0x0A, 0x0D: // }, newline
                flush()
                index += 1
            case 0x5C: // backslash
                let control = readControl(in: bytes, at: index)
                switch control.kind {
                case .hex(let byte):
                    pending.append(byte)
                case .literal(let byte):
                    flush()
                    output.append(Character(UnicodeScalar(byte)))
                case .word(let word, let value):
                    flush()
                    switch word {
                    case "par", "pard": output.append("\n")
                    case "tab": output.append("\t")
                    case "line": output += "<br>"
                    case "u":
                        if let value {
                            let scalar = UInt16(bitPattern: Int16(truncatingIfNeeded: value))
                            if let unicode = UnicodeScalar(scalar) { output.append(Character(unicode)) }
                        }
                    default: break
                    }
                case .none: break
                }
                index = control.next
            default:
                if bytes[index] < 0x80 {
                    flush()
                    output.append(Character(UnicodeScalar(bytes[index])))
                } else {
                    pending.append(bytes[index])
                }
                index += 1
            }
        }
        flush()
        let html = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return html.contains("<") && html.contains(">") ? html : nil
    }

    private static func decode(
        _ bytes: [UInt8],
        range: Range<Int>,
        encoding: String.Encoding,
        into output: inout String
    ) {
        var index = range.lowerBound
        var pending = Data()

        func flush() {
            guard !pending.isEmpty else { return }
            output += String(data: pending, encoding: encoding)
                ?? String(data: pending, encoding: .isoLatin1)
                ?? ""
            pending.removeAll(keepingCapacity: true)
        }

        while index < range.upperBound {
            if matches(htmlRtf, in: bytes, at: index) {
                flush()
                let after = index + htmlRtf.count
                if after >= range.upperBound || bytes[after] != 0x30 {
                    index = find(Array("\\htmlrtf0".utf8), in: bytes, from: after) ?? range.upperBound
                    continue
                }
            }

            if bytes[index] == 0x5C {
                let control = readControl(in: bytes, at: index)
                switch control.kind {
                case .hex(let byte): pending.append(byte)
                case .literal(let byte):
                    flush()
                    output.append(Character(UnicodeScalar(byte)))
                case .word(let word, let value):
                    flush()
                    switch word {
                    case "par", "pard": output.append("\n")
                    case "tab": output.append("\t")
                    case "line": output += "<br>"
                    case "u":
                        if let value {
                            let scalar = UInt16(bitPattern: Int16(truncatingIfNeeded: value))
                            if let unicode = UnicodeScalar(scalar) { output.append(Character(unicode)) }
                        }
                    default: break
                    }
                case .none: break
                }
                index = min(control.next, range.upperBound)
            } else if bytes[index] == 0x7B || bytes[index] == 0x7D {
                flush()
                index += 1
            } else {
                if bytes[index] < 0x80 {
                    flush()
                    output.append(Character(UnicodeScalar(bytes[index])))
                } else {
                    pending.append(bytes[index])
                }
                index += 1
            }
        }
        flush()
    }

    private enum ControlKind {
        case word(String, Int?)
        case hex(UInt8)
        case literal(UInt8)
        case none
    }

    private static func readControl(in bytes: [UInt8], at start: Int) -> (kind: ControlKind, next: Int) {
        guard start + 1 < bytes.count else { return (.none, bytes.count) }
        let next = bytes[start + 1]
        if next == 0x27, start + 3 < bytes.count,
           let high = hex(bytes[start + 2]), let low = hex(bytes[start + 3]) {
            return (.hex(high << 4 | low), start + 4)
        }
        if next == 0x5C || next == 0x7B || next == 0x7D {
            return (.literal(next), start + 2)
        }
        guard isLetter(next) else { return (.none, start + 2) }

        var index = start + 1
        let wordStart = index
        while index < bytes.count, isLetter(bytes[index]) { index += 1 }
        let word = String(decoding: bytes[wordStart..<index], as: UTF8.self)
        var sign = 1
        if index < bytes.count, bytes[index] == 0x2D {
            sign = -1
            index += 1
        }
        let numberStart = index
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        let number = index > numberStart
            ? sign * Int(String(decoding: bytes[numberStart..<index], as: UTF8.self))!
            : nil
        if index < bytes.count, bytes[index] == 0x20 { index += 1 }
        return (.word(word, number), index)
    }

    private static func matchingBrace(in bytes: [UInt8], at start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x5C, index + 1 < bytes.count,
               bytes[index + 1] == 0x5C || bytes[index + 1] == 0x7B || bytes[index + 1] == 0x7D {
                index += 2
                continue
            }
            if bytes[index] == 0x7B { depth += 1 }
            if bytes[index] == 0x7D {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func stringEncoding(in bytes: [UInt8]) -> String.Encoding {
        let marker = Array("\\ansicpg".utf8)
        guard let start = find(marker, in: bytes, from: 0) else { return .windowsCP1252 }
        var index = start + marker.count
        let numberStart = index
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        let codePage = Int(String(decoding: bytes[numberStart..<index], as: UTF8.self))
        switch codePage {
        case 65001: return .utf8
        case 1250: return .windowsCP1250
        case 1251: return .windowsCP1251
        case 1253: return .windowsCP1253
        case 1254: return .windowsCP1254
        default: return .windowsCP1252
        }
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start <= bytes.count - needle.count else { return nil }
        for index in start...(bytes.count - needle.count) where matches(needle, in: bytes, at: index) {
            return index
        }
        return nil
    }

    private static func matches(_ needle: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        index >= 0 && index + needle.count <= bytes.count
            && bytes[index..<(index + needle.count)].elementsEqual(needle)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
