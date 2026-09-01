import AppKit
import Foundation
@preconcurrency import QuickLookUI
import UniformTypeIdentifiers

struct LoadedMessage: Sendable {
    let url: URL
    let displayName: String
    let parser: MSGParser
    let summary: MessageSummary
}

@MainActor
final class MessageStore: ObservableObject {
    @Published private(set) var messages: [LoadedMessage] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var selectedAttachmentID: MessageSummary.Attachment.ID?
    private let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MSGViewer", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let preview = AttachmentPreviewController()

    var message: LoadedMessage? { messages.last }
    var canGoBack: Bool { messages.count > 1 }

    isolated deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func open(_ url: URL) {
        guard url.pathExtension.lowercased() == "msg" else {
            error = "Choose an Outlook .msg file."
            return
        }
        isLoading = true
        error = nil
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let parser = try MSGParser(data: data)
                    return LoadedMessage(url: url, displayName: url.lastPathComponent, parser: parser, summary: try parser.parse())
                }.value
                messages = [loaded]
                selectedAttachmentID = loaded.summary.attachments.first?.id
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    func save(_ attachment: MessageSummary.Attachment) {
        guard let message else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFilename(attachment.name)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try message.parser.data(for: attachment).write(to: destination, options: .atomic)
        } catch {
            self.error = "Could not save \(attachment.name): \(error.localizedDescription)"
        }
    }

    func saveAll() {
        guard let message else { return }
        let attachments = message.summary.attachments.filter { !$0.isEmbeddedMessage }
        guard !attachments.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save All"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        do {
            for attachment in attachments {
                let destination = uniqueURL(in: directory, filename: safeFilename(attachment.name))
                try message.parser.data(for: attachment).write(to: destination, options: .atomic)
            }
        } catch {
            self.error = "Could not save all attachments: \(error.localizedDescription)"
        }
    }

    func preview(_ attachment: MessageSummary.Attachment) {
        do {
            let url = try temporaryFile(for: attachment)
            preview.show(url)
        } catch {
            self.error = "Could not preview \(attachment.name): \(error.localizedDescription)"
        }
    }

    func previewSelected() -> Bool {
        guard let message,
              let selectedAttachmentID,
              let attachment = message.summary.attachments.first(where: { $0.id == selectedAttachmentID }),
              !attachment.isEmbeddedMessage else { return false }
        preview(attachment)
        return true
    }

    func openAttachment(_ attachment: MessageSummary.Attachment) {
        do {
            NSWorkspace.shared.open(try temporaryFile(for: attachment))
        } catch {
            self.error = "Could not open \(attachment.name): \(error.localizedDescription)"
        }
    }

    func itemProvider(for attachment: MessageSummary.Attachment) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = safeFilename(attachment.name)
        guard let message else { return provider }
        let type = UTType(filenameExtension: (attachment.name as NSString).pathExtension) ?? .data
        let directory = temporaryDirectory
        let filename = safeFilename(attachment.name)
        let parser = message.parser

        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task.detached {
                do {
                    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent(filename)
                    try parser.data(for: attachment).write(to: url, options: .atomic)
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    func openEmbedded(_ attachment: MessageSummary.Attachment) {
        guard let message else { return }
        do {
            let parser = try message.parser.embeddedMessage(for: attachment)
            messages.append(LoadedMessage(
                url: message.url,
                displayName: attachment.name,
                parser: parser,
                summary: try parser.parse()
            ))
            selectedAttachmentID = messages.last?.summary.attachments.first?.id
        } catch {
            self.error = "Could not open attached message: \(error.localizedDescription)"
        }
    }

    func goBack() {
        if canGoBack {
            messages.removeLast()
            selectedAttachmentID = messages.last?.summary.attachments.first?.id
        }
    }

    private func temporaryFile(for attachment: MessageSummary.Attachment) throws -> URL {
        guard let message else { throw ParseError.invalid("no message is open") }
        let directory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(safeFilename(attachment.name))
        try message.parser.data(for: attachment).write(to: url, options: .atomic)
        return url
    }

}

func uniqueURL(in directory: URL, filename: String) -> URL {
    let base = (filename as NSString).deletingPathExtension
    let ext = (filename as NSString).pathExtension
    var candidate = directory.appendingPathComponent(filename)
    var number = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
        candidate = directory.appendingPathComponent(numbered)
        number += 1
    }
    return candidate
}

func safeFilename(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:").union(.controlCharacters)
    let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
    return cleaned.isEmpty ? "Attachment" : cleaned
}

@MainActor
private final class AttachmentPreviewController: NSObject {
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

}

extension AttachmentPreviewController: @MainActor QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        url! as NSURL
    }
}
