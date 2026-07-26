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

@Test func extractsEncapsulatedHTMLFromRTF() {
    let rtf = #"{\rtf1\ansi\ansicpg1252\fromhtml1 {\*\htmltag19 <html>}{\*\htmltag50 <body>}\htmlrtf {\htmlrtf0 Hello {\*\htmltag84 <b>}\htmlrtf {\b\htmlrtf0 world}\htmlrtf0 {\*\htmltag92 </b>}{\*\htmltag58 </body>}{\*\htmltag27 </html>}}"#
    let html = RTFHTMLExtractor.extract(Data(rtf.utf8))
    #expect(html?.contains("<body>Hello <b>world</b></body>") == true)
}
