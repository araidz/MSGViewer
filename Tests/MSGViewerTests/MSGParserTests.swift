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

@Test func embedsInlineImagesWithoutTouchingRemoteImages() {
    let html = #"<img src="cid:logo"><img src="https://example.com/logo.png">"#
    let resource = InlineImageResource(references: ["logo"], mimeType: "image/png", data: Data([1, 2, 3]))
    let rendered = embeddingInlineImages(in: html, resources: [resource])
    #expect(rendered.contains("src=\"data:image/png;base64,AQID\""))
    #expect(rendered.contains("src=\"https://example.com/logo.png\""))
}
