import Foundation
import UniformTypeIdentifiers

struct MessageSummary: Sendable {
    struct Attachment: Identifiable, Sendable {
        let id: Int
        let name: String
        let size: UInt64
        let isEmbeddedMessage: Bool
        let mimeType: String?
        let contentID: String?
        let contentLocation: String?
        fileprivate let contentEntryIndex: Int?
        fileprivate let embeddedEntryIndex: Int?
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

struct MSGParser: Sendable {
    private let file: CompoundFile
    private let rootIndex: Int

    init(data: Data) throws {
        file = try CompoundFile(data: data)
        rootIndex = 0
    }

    private init(file: CompoundFile, rootIndex: Int) {
        self.file = file
        self.rootIndex = rootIndex
    }

    func parse() throws -> MessageSummary {
        let root = rootIndex
        let recipientFolders = try file.children(of: root).filter { $0.1.name.hasPrefix("__recip_version1.0_#") }
        let attachmentFolders = try file.children(of: root).filter { $0.1.name.hasPrefix("__attach_version1.0_#") }
        let rtfData = try rtfProperty(in: root)
        let rawHTML = try htmlProperty(in: root) ?? rtfData.flatMap(RTFHTMLExtractor.extract)

        let attachments = try attachmentFolders.map { index, _ in
            let embeddedName = "__substg1.0_3701000D"
            let embeddedEntry = try file.child(named: embeddedName, of: index)
            let contentEntry = try propertyEntry(id: "3701", types: ["0102"], in: index)
            let name = try stringProperty(id: "3707", in: index)
                ?? stringProperty(id: "3704", in: index)
                ?? stringProperty(id: "3001", in: index)
                ?? (embeddedEntry == nil ? "Attachment" : "Attached message.msg")
            return MessageSummary.Attachment(
                id: index,
                name: name,
                size: contentEntry?.1.size ?? 0,
                isEmbeddedMessage: embeddedEntry != nil,
                mimeType: try stringProperty(id: "370E", in: index),
                contentID: try stringProperty(id: "3712", in: index),
                contentLocation: try stringProperty(id: "3713", in: index),
                contentEntryIndex: contentEntry?.0,
                embeddedEntryIndex: embeddedEntry?.0
            )
        }

        let resources = try attachments.compactMap { attachment -> InlineImageResource? in
            guard let contentIndex = attachment.contentEntryIndex,
                  file.entries.indices.contains(contentIndex) else { return nil }
            let mimeType = attachment.mimeType
                ?? UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.preferredMIMEType
            guard let mimeType, ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/tiff", "image/bmp", "image/webp"].contains(mimeType.lowercased()) else {
                return nil
            }
            let references = [attachment.contentID?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), attachment.contentLocation, attachment.name]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            guard !references.isEmpty,
                  rawHTML.map({ html in references.contains { html.localizedCaseInsensitiveContains($0) } }) == true else { return nil }
            return InlineImageResource(references: references, mimeType: mimeType, data: try file.stream(file.entries[contentIndex]))
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
            htmlBody: rawHTML.map { embeddingInlineImages(in: $0, resources: resources) },
            rtfBody: clean(rtfData.flatMap { String(data: $0, encoding: .windowsCP1252) }),
            attachments: attachments
        )
    }

    func data(for attachment: MessageSummary.Attachment) throws -> Data {
        guard let index = attachment.contentEntryIndex, file.entries.indices.contains(index) else {
            throw ParseError.unsupported("attachment has no binary content")
        }
        return try file.stream(file.entries[index])
    }

    func embeddedMessage(for attachment: MessageSummary.Attachment) throws -> MSGParser {
        guard let index = attachment.embeddedEntryIndex else {
            throw ParseError.unsupported("attachment is not an embedded message")
        }
        return MSGParser(file: file, rootIndex: index)
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

    private func rtfProperty(in parent: Int) throws -> Data? {
        guard let (_, entry) = try propertyEntry(id: "1009", types: ["0102"], in: parent) else { return nil }
        return try CompressedRTF.decompress(file.stream(entry))
    }

    private func messageDate(in parent: Int) throws -> Date? {
        guard let (_, entry) = try file.child(named: "__properties_version1.0", of: parent) else { return nil }
        let data = try file.stream(entry)
        let folderName = file.entries[parent].name
        let headerSize = folderName.hasPrefix("__attach") || folderName.hasPrefix("__recip")
            ? 8
            : folderName == "Root Entry" ? 32 : 24
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

struct InlineImageResource: Sendable {
    let references: [String]
    let mimeType: String
    let data: Data
}

func embeddingInlineImages(in html: String, resources: [InlineImageResource]) -> String {
    resources.reduce(html) { result, resource in
        let dataURL = "data:\(resource.mimeType);base64,\(resource.data.base64EncodedString())"
        return resource.references.reduce(result) { html, reference in
            var html = html.replacingOccurrences(of: "cid:\(reference)", with: dataURL, options: .caseInsensitive)
            for quote in ["\"", "'"] {
                for attribute in ["src", "background"] {
                    html = html.replacingOccurrences(
                        of: "\(attribute)=\(quote)\(reference)\(quote)",
                        with: "\(attribute)=\(quote)\(dataURL)\(quote)",
                        options: .caseInsensitive
                    )
                }
            }
            return html
        }
    }
}
