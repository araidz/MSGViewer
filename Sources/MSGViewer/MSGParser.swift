import Foundation

struct MessageSummary {
    struct Attachment {
        let name: String
        let size: UInt64
        let isEmbeddedMessage: Bool
    }

    let subject: String?
    let senderName: String?
    let senderEmail: String?
    let date: Date?
    let to: String?
    let cc: String?
    let recipientCount: Int
    let plainBody: String?
    let htmlBody: String?
    let rtfBody: String?
    let attachments: [Attachment]
}

struct MSGParser {
    private let file: CompoundFile

    init(data: Data) throws {
        file = try CompoundFile(data: data)
    }

    func parse() throws -> MessageSummary {
        let root = 0
        let recipientFolders = try file.children(of: root).filter { $0.1.name.hasPrefix("__recip_version1.0_#") }
        let attachmentFolders = try file.children(of: root).filter { $0.1.name.hasPrefix("__attach_version1.0_#") }

        let attachments = try attachmentFolders.map { index, _ in
            let embeddedName = "__substg1.0_3701000D"
            let embedded = try file.child(named: embeddedName, of: index) != nil
            let contentEntry = try propertyEntry(id: "3701", types: ["0102"], in: index)?.1
            let name = try stringProperty(id: "3707", in: index)
                ?? stringProperty(id: "3704", in: index)
                ?? stringProperty(id: "3001", in: index)
                ?? (embedded ? "Attached message.msg" : "Attachment")
            return MessageSummary.Attachment(
                name: name,
                size: contentEntry?.size ?? 0,
                isEmbeddedMessage: embedded
            )
        }

        return MessageSummary(
            subject: try stringProperty(id: "0037", in: root),
            senderName: try stringProperty(id: "0C1A", in: root),
            senderEmail: try stringProperty(id: "5D02", in: root) ?? stringProperty(id: "0C1F", in: root),
            date: try messageDate(in: root),
            to: try stringProperty(id: "0E04", in: root),
            cc: try stringProperty(id: "0E03", in: root),
            recipientCount: recipientFolders.count,
            plainBody: try stringProperty(id: "1000", in: root),
            htmlBody: try htmlProperty(in: root),
            rtfBody: try rtfProperty(in: root),
            attachments: attachments
        )
    }

    private func propertyEntry(id: String, types: [String], in parent: Int) throws -> (Int, DirectoryEntry)? {
        for type in types {
            if let entry = try file.child(named: "__substg1.0_\(id.uppercased())\(type)", of: parent) {
                return entry
            }
        }
        return nil
    }

    private func stringProperty(id: String, in parent: Int) throws -> String? {
        if let (_, entry) = try propertyEntry(id: id, types: ["001F"], in: parent) {
            return clean(String(data: try file.stream(entry), encoding: .utf16LittleEndian))
        }
        if let (_, entry) = try propertyEntry(id: id, types: ["001E"], in: parent) {
            let data = try file.stream(entry)
            return clean(String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .utf8))
        }
        return nil
    }

    private func htmlProperty(in parent: Int) throws -> String? {
        if let value = try stringProperty(id: "1013", in: parent) { return value }
        guard let (_, entry) = try propertyEntry(id: "1013", types: ["0102"], in: parent) else { return nil }
        let data = try file.stream(entry)
        if data.starts(with: [0xFF, 0xFE]) { return clean(String(data: data.dropFirst(2), encoding: .utf16LittleEndian)) }
        return clean(String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252))
    }

    private func rtfProperty(in parent: Int) throws -> String? {
        guard let (_, entry) = try propertyEntry(id: "1009", types: ["0102"], in: parent) else { return nil }
        return clean(String(data: try CompressedRTF.decompress(file.stream(entry)), encoding: .windowsCP1252))
    }

    private func messageDate(in parent: Int) throws -> Date? {
        guard let (_, entry) = try file.child(named: "__properties_version1.0", of: parent) else { return nil }
        let data = try file.stream(entry)
        let headerSize = parent == 0 ? 32 : 8
        guard data.count >= headerSize else { throw ParseError.invalid("property stream header is truncated") }

        for offset in stride(from: headerSize, through: data.count - 16, by: 16) {
            let tag = try data.u32(at: offset)
            guard tag >> 16 == 0x0E06, tag & 0xFFFF == 0x0040 else { continue }
            let fileTime = try data.u64(at: offset + 8)
            let seconds = Double(fileTime) / 10_000_000 - 11_644_473_600
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? nil : cleaned
    }
}
