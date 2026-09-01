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
        let rootChildren = try childMap(of: root)
        let recipientCount = rootChildren.values.count { $0.1.name.hasPrefix("__recip_version1.0_#") }
        let attachmentFolders = rootChildren.values
            .filter { $0.1.name.hasPrefix("__attach_version1.0_#") }
            .sorted { $0.1.name < $1.1.name }
        let rtfData = try rtfProperty(in: rootChildren)
        let rawHTML = try htmlProperty(in: rootChildren) ?? rtfData.flatMap(RTFHTMLExtractor.extract)

        let attachments = try attachmentFolders.map { index, _ in
            let children = try childMap(of: index)
            let embeddedEntry = children["__SUBSTG1.0_3701000D"]
            let contentEntry = propertyEntry(id: "3701", type: "0102", in: children)
            let name = try stringProperty(id: "3707", in: children)
                ?? stringProperty(id: "3704", in: children)
                ?? stringProperty(id: "3001", in: children)
                ?? (embeddedEntry == nil ? "Attachment" : "Attached message.msg")
            return MessageSummary.Attachment(
                id: index,
                name: name,
                size: contentEntry?.1.size ?? 0,
                isEmbeddedMessage: embeddedEntry != nil,
                mimeType: try stringProperty(id: "370E", in: children),
                contentID: try stringProperty(id: "3712", in: children),
                contentLocation: try stringProperty(id: "3713", in: children),
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
                  rawHTML.map({ html in references.contains { html.range(of: $0, options: .caseInsensitive) != nil } }) == true else { return nil }
            return InlineImageResource(references: references, mimeType: mimeType, data: try file.stream(file.entries[contentIndex]))
        }

        return MessageSummary(
            subject: try stringProperty(id: "0037", in: rootChildren),
            senderName: try stringProperty(id: "0C1A", in: rootChildren),
            senderEmail: try stringProperty(id: "5D02", in: rootChildren) ?? stringProperty(id: "0C1F", in: rootChildren),
            date: try messageDate(of: root, in: rootChildren),
            to: try stringProperty(id: "0E04", in: rootChildren),
            cc: try stringProperty(id: "0E03", in: rootChildren),
            recipientCount: recipientCount,
            plainBody: try stringProperty(id: "1000", in: rootChildren),
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

    private typealias ChildMap = [String: (Int, DirectoryEntry)]

    /// Walks a directory's children once so property lookups are O(1) instead
    /// of re-traversing the tree per property.
    private func childMap(of parent: Int) throws -> ChildMap {
        try Dictionary(file.children(of: parent).map { ($0.1.name.uppercased(), $0) }) { first, _ in first }
    }

    private func propertyEntry(id: String, type: String, in children: ChildMap) -> (Int, DirectoryEntry)? {
        children["__SUBSTG1.0_\(id.uppercased())\(type)"]
    }

    private func stringProperty(id: String, in children: ChildMap) throws -> String? {
        if let (_, entry) = propertyEntry(id: id, type: "001F", in: children) {
            return clean(String(data: try file.stream(entry), encoding: .utf16LittleEndian))
        }
        if let (_, entry) = propertyEntry(id: id, type: "001E", in: children) {
            let data = try file.stream(entry)
            return clean(String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .utf8))
        }
        return nil
    }

    private func htmlProperty(in children: ChildMap) throws -> String? {
        if let value = try stringProperty(id: "1013", in: children) { return value }
        guard let (_, entry) = propertyEntry(id: "1013", type: "0102", in: children) else { return nil }
        let data = try file.stream(entry)
        if data.starts(with: [0xFF, 0xFE]) { return clean(String(data: data.dropFirst(2), encoding: .utf16LittleEndian)) }
        return clean(String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252))
    }

    private func rtfProperty(in children: ChildMap) throws -> Data? {
        guard let (_, entry) = propertyEntry(id: "1009", type: "0102", in: children) else { return nil }
        return try CompressedRTF.decompress(file.stream(entry))
    }

    private func messageDate(of parent: Int, in children: ChildMap) throws -> Date? {
        guard let (_, entry) = children["__PROPERTIES_VERSION1.0"] else { return nil }
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
