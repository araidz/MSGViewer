import AppKit
import SwiftUI

@main
struct MSGViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1].lowercased().hasSuffix(".msg") {
            do {
                try inspect(arguments[1])
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: .shared)
                .frame(minWidth: 820, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Message...") { MessageStore.shared.showOpenPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { MessageStore.shared.open(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MessageStore.shared.cleanupTemporaryFiles()
    }
}

private func inspect(_ path: String) throws {
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
