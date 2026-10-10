import AppKit
import Combine
import SwiftUI

@main
enum MSGViewerMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // Any argument other than a launcher flag is a CLI call and must never reach the GUI run loop,
        // which would block a shell caller forever.
        if let first = arguments.first, !["-psn_", "-NS", "-Apple"].contains(where: first.hasPrefix) {
            exit(runCommandLine(arguments))
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        delegate.installMainMenu()
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class MessageWindowController: NSWindowController, NSWindowDelegate {
    let store: MessageStore
    let sourceURL: URL?
    var didClose: ((MessageWindowController) -> Void)?
    private var titleSubscription: AnyCancellable?
    var lastFind = ""

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
        titleSubscription = store.$messages.sink { [weak window] messages in
            MainActor.assumeIsolated {
                if let loaded = messages.last { window?.title = loaded.summary.subject ?? loaded.displayName }
            }
        }
        if let url { store.open(url) }
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        didClose?(self)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [MessageWindowController] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openWindow)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        DispatchQueue.main.async { [weak self] in
            if self?.windows.isEmpty == true { self?.openWindow(nil) }
        }
        return true
    }

    @objc func showOpenPanel() { showOpenPanel(replacing: keyController?.store) }

    func showOpenPanel(replacing store: MessageStore?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "msg")!]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { open(panel.urls, replacing: store) }
    }

    /// Opens each file in its own window; an empty window that asked for them is closed afterwards.
    func open(_ urls: [URL], replacing store: MessageStore?) {
        urls.forEach(openWindow)
        if let store, store.message == nil, !store.isLoading,
           let empty = windows.first(where: { $0.store === store }) {
            empty.close()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MSGViewer", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func installMainMenu() {
        let main = NSMenu()
        func addMenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
        }

        addMenu("MSG Viewer") {
            $0.addItem(withTitle: "Quit MSG Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
        addMenu("File") { menu in
            menu.addItem(withTitle: "Open Message...", action: #selector(showOpenPanel as () -> Void), keyEquivalent: "o").target = self
            let recent = NSMenu(title: "Open Recent")
            recent.delegate = self
            let recentItem = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
            recentItem.submenu = recent
            menu.addItem(.separator())
            menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Print...", action: #selector(printMessage), keyEquivalent: "p").target = self
        }
        addMenu("Edit") { menu in
            menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            menu.addItem(.separator())
            let find = menu.addItem(withTitle: "Find...", action: #selector(showFind(_:)), keyEquivalent: "f")
            find.target = self
            find.tag = NSTextFinder.Action.showFindInterface.rawValue
            menu.addItem(withTitle: "Find Next", action: #selector(findNext), keyEquivalent: "g").target = self
        }
        addMenu("View") { menu in
            menu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+").target = self
            menu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-").target = self
            menu.addItem(withTitle: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0").target = self
        }
        addMenu("Window") { menu in
            menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            NSApp.windowsMenu = menu
        }
        NSApp.mainMenu = main
    }

    private var keyController: MessageWindowController? { windows.first { $0.window === NSApp.keyWindow } }
    @objc private func printMessage() { keyController?.printBody() }
    @objc private func showFind(_ sender: Any?) { keyController?.showFind(sender) }
    @objc private func findNext() { keyController?.findNext() }
    @objc private func zoomIn() { keyController?.zoom(by: 1.25) }
    @objc private func zoomOut() { keyController?.zoom(by: 0.8) }
    @objc private func zoomReset() { keyController?.zoom(by: nil) }

    @objc private func openRecent(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { openWindow(url) }
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
            if self?.windows.isEmpty == true { NSApp.terminate(nil) }
        }
        if let previous = windows.last?.window {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        } else if let window = controller.window {
            // Only the first window is remembered; the rest cascade from it.
            if !window.setFrameUsingName("MSGViewer") { window.center() }
            window.setFrameAutosaveName("MSGViewer")
        }
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = NSDocumentController.shared
    }
}

private let usage = """
usage: MSGViewer dump <file.msg> [--output <directory>]
       MSGViewer <file.msg>
exit codes: 0 ok, 1 parse/IO error, 2 bad arguments, 3 timed out (default 60 s, MSGVIEWER_TIMEOUT overrides)

"""

/// Exit codes: 0 success, 1 parse/IO error, 2 usage error, 3 timed out.
private func runCommandLine(_ arguments: [String]) -> Int32 {
    if arguments == ["--help"] || arguments == ["-h"] {
        print(usage, terminator: "")
        return 0
    }

    var rest = arguments
    let isDump = rest.first == "dump"
    if isDump { rest.removeFirst() }
    var outputPath: String?
    if let flag = rest.firstIndex(of: "--output"), flag + 1 < rest.count {
        outputPath = rest[flag + 1]
        rest.removeSubrange(flag...(flag + 1))
    }
    guard rest.count == 1, !rest[0].hasPrefix("-"), isDump || outputPath == nil else {
        FileHandle.standardError.write(Data("MSGViewer: unrecognized arguments: \(arguments.joined(separator: " "))\n\(usage)".utf8))
        return 2
    }

    // Backstop so a shell caller never waits forever (e.g. an iCloud file that will not download).
    // Real messages parse in well under a second. MSGVIEWER_TIMEOUT (seconds) overrides the default.
    let timeout = ProcessInfo.processInfo.environment["MSGVIEWER_TIMEOUT"].flatMap(Double.init) ?? 60
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        FileHandle.standardError.write(Data("MSGViewer: timed out after \(timeout) seconds\n".utf8))
        exit(3)
    }
    do {
        if isDump {
            try dump(rest[0], outputPath: outputPath)
        } else {
            try inspect(rest[0])
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("MSGViewer: \(error)\n".utf8))
        return 1
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

private func dump(_ path: String, outputPath: String?) throws {
    let source = URL(fileURLWithPath: path).standardizedFileURL
    let parser = try MSGParser(data: Data(contentsOf: source, options: .mappedIfSafe))
    let output = outputPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("MSGViewer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    print("File: \(source.path)")
    try dump(parser, into: output, depth: 0)
    print("Output directory: \(output.path)")
}

private func dump(_ parser: MSGParser, into output: URL, depth: Int) throws {
    let message = try parser.parse()
    print("Subject: \(message.subject ?? "")")
    print("Sender: \(message.senderName ?? "")")
    print("Sender email: \(message.senderEmail ?? "")")
    print("Date: \(message.date?.description ?? "")")
    print("To: \(message.addresses(for: .to) ?? "")")
    print("Cc: \(message.addresses(for: .cc) ?? "")")
    if let bcc = message.addresses(for: .bcc) { print("Bcc: \(bcc)") }
    print("Recipients: \(message.recipientCount)")
    let body = message.plainBody ?? message.htmlBody ?? message.rtfBody ?? ""
    print("\n--- BODY ---")
    print(body)
    print("--- END BODY ---\n")

    let bodyURL = uniqueURL(in: output, filename: "body.txt")
    try Data(body.utf8).write(to: bodyURL, options: .atomic)
    print("Body file: \(bodyURL.path)")

    if let html = message.htmlBody {
        let destination = uniqueURL(in: output, filename: "body.html")
        try Data(html.utf8).write(to: destination, options: .atomic)
        print("HTML body: \(destination.path)")
    }

    if let headers = message.headers {
        let destination = uniqueURL(in: output, filename: "headers.txt")
        try Data(headers.utf8).write(to: destination, options: .atomic)
        print("Headers file: \(destination.path)")
    }

    let attachments = message.attachments.filter { !$0.isEmbeddedMessage }
    if !attachments.isEmpty {
        let directory = output.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for attachment in attachments {
            do {
                let destination = uniqueURL(in: directory, filename: safeFilename(attachment.name))
                try parser.data(for: attachment).write(to: destination, options: .atomic)
                print("Attachment: \(destination.path)")
            } catch {
                print("Warning: attachment not extracted: \(attachment.name) — \(error)")
            }
        }
    }

    for attachment in message.attachments where attachment.isEmbeddedMessage {
        do {
            // A crafted file can point an embedded message back at an ancestor.
            guard depth < 8 else { throw ParseError.unsupported("embedded messages are nested too deeply") }
            let parent = output.appendingPathComponent("embedded", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var name = safeFilename(attachment.name)
            if name.lowercased().hasSuffix(".msg") { name = String(name.dropLast(4)) }
            let directory = uniqueURL(in: parent, filename: name.isEmpty ? "Attached message" : name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            print("\n=== EMBEDDED MESSAGE: \(attachment.name) ===")
            print("Embedded message directory: \(directory.path)")
            try dump(parser.embeddedMessage(for: attachment), into: directory, depth: depth + 1)
            print("=== END EMBEDDED MESSAGE ===\n")
        } catch {
            print("Warning: embedded message not extracted: \(attachment.name) — \(error)")
        }
    }
}
