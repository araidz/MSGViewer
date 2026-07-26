import AppKit
import SwiftUI

@main
enum MSGViewerMain {
    static func main() {
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

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        delegate.installMainMenu()
        application.run()
    }
}

@MainActor
final class MessageWindowController: NSWindowController, NSWindowDelegate {
    let store: MessageStore
    let sourceURL: URL?
    var didClose: ((MessageWindowController) -> Void)?

    init(url: URL?) {
        sourceURL = url?.standardizedFileURL
        store = MessageStore()
        let rootView = ContentView(store: store).frame(minWidth: 820, minHeight: 560)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: rootView)
        window.title = url?.lastPathComponent ?? "MSG Viewer"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        if let url { store.open(url) }
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        store.cleanupTemporaryFiles()
        didClose?(self)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [MessageWindowController] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openWindow)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames
            .map { URL(fileURLWithPath: $0) }
            .filter { $0.pathExtension.lowercased() == "msg" }
            .forEach(openWindow)
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        DispatchQueue.main.async { [weak self] in
            if self?.windows.isEmpty == true { self?.openWindow(nil) }
        }
        return true
    }

    @objc func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "msg")!]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            panel.urls.forEach(openWindow)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MSGViewer", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MSG Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openItem = fileMenu.addItem(withTitle: "Open Message...", action: #selector(showOpenPanel), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        NSApp.mainMenu = main
    }

    private func openWindow(_ url: URL?) {
        if let url = url?.standardizedFileURL,
           let existing = windows.first(where: { $0.sourceURL == url }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = MessageWindowController(url: url)
        controller.didClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        if let previous = windows.last?.window {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        } else {
            controller.window?.center()
        }
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
    print("RTF kind: \(message.rtfBody?.contains("\\fromhtml") == true ? "encapsulated HTML" : "native RTF")")
    print("Plain body: \(message.plainBody.map { "yes (\($0.count) characters)" } ?? "no")")
    print("Attachments: \(message.attachments.count) (\(attachmentBytes) bytes, \(message.attachments.filter(\.isEmbeddedMessage).count) embedded messages)")
    print("Inline images: \(message.htmlBody?.components(separatedBy: "data:image/").count.advanced(by: -1) ?? 0)")
}
