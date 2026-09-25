import Foundation
import Testing
@testable import MSGViewer

@Test func rejectsInvalidSignature() throws {
    #expect(throws: ParseError.self) {
        _ = try MSGParser(data: Data(repeating: 0, count: 512))
    }
}

@Test func parsesLocalFixtureWhenProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["MSG_FIXTURE"] else { return }
    let parser = try MSGParser(data: Data(contentsOf: URL(fileURLWithPath: path)))
    let message = try parser.parse()
    #expect(message.subject != nil)
    #expect(message.htmlBody != nil)
    #expect(message.htmlBody?.localizedCaseInsensitiveContains("<body") == true)
    #expect(message.htmlBody?.contains("\\htmlrtf") == false)
    #expect(!message.attachments.isEmpty)
    if let attachment = message.attachments.first, !attachment.isEmbeddedMessage {
        #expect(UInt64(try parser.data(for: attachment).count) == attachment.size)
    }
}

@Test func decompressesSpecSampleRTF() throws {
    // Compressed sample from MS-OXRTFCP section 4.1.
    let compressed: [UInt8] = [
        0x2d, 0x00, 0x00, 0x00, 0x2b, 0x00, 0x00, 0x00, 0x4c, 0x5a, 0x46, 0x75, 0xf1, 0xc5, 0xc7, 0xa7,
        0x03, 0x00, 0x0a, 0x00, 0x72, 0x63, 0x70, 0x67, 0x31, 0x32, 0x35, 0x42, 0x32, 0x0a, 0xf3, 0x20,
        0x68, 0x65, 0x6c, 0x09, 0x00, 0x20, 0x62, 0x77, 0x05, 0xb0, 0x6c, 0x64, 0x7d, 0x0a, 0x80, 0x0f,
        0xa0,
    ]
    let output = try CompressedRTF.decompress(Data(compressed))
    #expect(String(decoding: output, as: UTF8.self) == "{\\rtf1\\ansi\\ansicpg1252\\pard hello world}\r\n")
}

@Test func extractsEncapsulatedHTMLFromRTF() {
    let rtf = #"{\rtf1\ansi\ansicpg1252\fromhtml1 {\*\htmltag19 <html>}{\*\htmltag50 <body>}\htmlrtf {\htmlrtf0 Hello {\*\htmltag84 <b>}\htmlrtf {\b\htmlrtf0 world}\htmlrtf0 {\*\htmltag92 </b>}{\*\htmltag58 </body>}{\*\htmltag27 </html>}}"#
    let html = RTFHTMLExtractor.extract(Data(rtf.utf8))
    #expect(html?.contains("<body>Hello <b>world</b></body>") == true)
}

@Test func ignoresOverflowingRTFControlNumbers() {
    let rtf = #"{\rtf1\ansi\fromhtml1 {\*\htmltag19 <html>}\f99999999999999999999999 x{\*\htmltag27 </html>}}"#
    #expect(RTFHTMLExtractor.extract(Data(rtf.utf8))?.contains("<html>") == true)
}

@Test func sanitizesUnwritableFilenames() {
    #expect(safeFilename("..") == "Attachment")
    #expect(safeFilename(" . ") == "Attachment")
    #expect(safeFilename("a/b:c.pdf") == "a-b-c.pdf")
    let long = safeFilename(String(repeating: "é", count: 300) + ".pdf")
    #expect(long.utf8.count <= 240)
    #expect(long.hasSuffix(".pdf"))
}

/// Runs the built CLI with a hard 5-second cap; a hang shows up as status -1.
private func runCLI(_ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, stdout: String) {
    let binary = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/MSGViewer")
    try #require(FileManager.default.isExecutableFile(atPath: binary.path))
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning && Date() < deadline { usleep(20_000) }
    if process.isRunning { process.terminate(); return (-1, "") }
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

private func fixture(_ nodes: [CFBNode], mutate: (inout [CFBEntry]) -> Void = { _ in }) throws -> URL {
    var entries = cfbEntries(root: nodes)
    mutate(&entries)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("msgviewer-fixture-\(UUID().uuidString).msg")
    try buildCFB(entries).write(to: url)
    return url
}

@Test func commandLineNeverBlocksOnBadArguments() throws {
    for (arguments, expected) in [(["--help"], Int32(0)), (["x.msg", "--json"], 2), (["dump"], 2), (["dump", "/nonexistent.msg"], 1)] {
        #expect(try runCLI(arguments).status == expected, "\(arguments)")
    }
}

@Test func dumpExtractsNestedEmbeddedMessages() throws {
    let inner = CFBNode.message(subject: "Inner", body: "innermost body")
    let middle = CFBNode.message(subject: "Middle", body: "middle body", extra: [.attachedMessage(index: 0, inner)])
    let url = try fixture(CFBNode.message(subject: "Outer", body: "outer body", extra: [.attachedMessage(index: 0, middle)]))
    let output = url.deletingPathExtension()
    let result = try runCLI(["dump", url.path, "--output", output.path])
    #expect(result.status == 0)
    #expect(result.stdout.components(separatedBy: "=== EMBEDDED MESSAGE:").count == 3)
    #expect(result.stdout.contains("Subject: Inner"))
    let nested = output.appendingPathComponent("embedded/Attached message/embedded/Attached message/body.txt")
    #expect(try String(contentsOf: nested, encoding: .utf8).hasPrefix("innermost body"))
}

@Test func dumpSurvivesCyclicEmbeddedMessage() throws {
    // The embedded storage's child list points back at its own attachment folder.
    let url = try fixture(CFBNode.message(subject: "Loop", body: "loop body", extra: [.attachedMessage(index: 0, [])])) { entries in
        let attach = entries.firstIndex { $0.name.hasPrefix("__attach") }!
        let embedded = entries.firstIndex { $0.name == "__substg1.0_3701000D" }!
        entries[embedded].child = UInt32(attach)
    }
    let result = try runCLI(["dump", url.path, "--output", url.deletingPathExtension().path])
    #expect(result.status == 0)
    #expect(result.stdout.contains("Warning: embedded message not extracted"))
    #expect(result.stdout.contains("nested too deeply"))
}

@Test func watchdogExitsWithCodeThree() throws {
    // Crafted RTF with 300k unmatched braces makes extraction quadratic (minutes).
    let rtf = #"{\rtf1\ansi\fromhtml1 {\*\htmltag <html>}"# + String(repeating: "{", count: 300_000)
    let url = try fixture([.stream("__substg1.0_10090102", melaRTF(rtf))])
    let start = Date()
    let result = try runCLI(["dump", url.path, "--output", url.deletingPathExtension().path], environment: ["MSGVIEWER_TIMEOUT": "1"])
    #expect(result.status == 3)
    #expect(Date().timeIntervalSince(start) < 4)
}

@Test func embedsInlineImagesWithoutTouchingRemoteImages() {
    let html = #"<img src="cid:logo"><img src="https://example.com/logo.png">"#
    let resource = InlineImageResource(references: ["logo"], mimeType: "image/png", data: Data([1, 2, 3]))
    let rendered = embeddingInlineImages(in: html, resources: [resource])
    #expect(rendered.contains("src=\"data:image/png;base64,AQID\""))
    #expect(rendered.contains("src=\"https://example.com/logo.png\""))
}
