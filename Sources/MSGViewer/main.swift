import Foundation

func inspect(_ path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    let message = try MSGParser(data: data).parse()
    let attachmentBytes = message.attachments.reduce(UInt64(0)) { $0 + $1.size }

    print("Parsed: \(URL(fileURLWithPath: path).lastPathComponent)")
    print("Subject: \(message.subject.map { "yes (\($0.count) characters)" } ?? "no")")
    print("Sender name: \(message.senderName == nil ? "no" : "yes")")
    print("Sender email: \(message.senderEmail == nil ? "no" : "yes")")
    print("Date: \(message.date == nil ? "no" : "yes")")
    print("Recipients: \(message.recipientCount)")
    print("HTML body: \(message.htmlBody.map { "yes (\($0.utf8.count) bytes)" } ?? "no")")
    print("RTF body: \(message.rtfBody.map { "yes (\($0.utf8.count) bytes decompressed)" } ?? "no")")
    print("Plain body: \(message.plainBody.map { "yes (\($0.count) characters)" } ?? "no")")
    print("Attachments: \(message.attachments.count) (\(attachmentBytes) bytes, \(message.attachments.filter(\.isEmbeddedMessage).count) embedded messages)")
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("Usage: MSGViewer <file.msg>")
    exit(2)
}

do {
    try inspect(arguments[1])
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
