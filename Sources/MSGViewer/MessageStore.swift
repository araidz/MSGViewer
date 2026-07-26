import AppKit
import Foundation

struct LoadedMessage: Sendable {
    let url: URL
    let parser: MSGParser
    let summary: MessageSummary
}

@MainActor
final class MessageStore: ObservableObject {
    static let shared = MessageStore()

    @Published private(set) var message: LoadedMessage?
    @Published private(set) var isLoading = false
    @Published var error: String?

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "msg")!]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
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
                    return LoadedMessage(url: url, parser: parser, summary: try parser.parse())
                }.value
                message = loaded
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

    private func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Attachment" : cleaned
    }
}
