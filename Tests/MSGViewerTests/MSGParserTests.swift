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
    let message = try MSGParser(data: Data(contentsOf: URL(fileURLWithPath: path))).parse()
    #expect(message.subject != nil)
    #expect(message.htmlBody != nil || message.rtfBody != nil)
    #expect(!message.attachments.isEmpty)
}
