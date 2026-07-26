import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: MessageStore
    @State private var isImporting = false

    var body: some View {
        Group {
            if store.isLoading {
                ProgressView("Opening message...")
            } else if let loaded = store.message {
                MessageView(loaded: loaded, save: store.save)
            } else {
                ContentUnavailableView {
                    Label("Open an Outlook Message", systemImage: "envelope.open")
                } description: {
                    Text("Drop a .msg file here or choose one from Finder.")
                } actions: {
                    Button("Open Message...") { isImporting = true }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            store.open(url)
            return true
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.init(filenameExtension: "msg")!]
        ) { result in
            if case .success(let url) = result { store.open(url) }
        }
        .alert("MSG Viewer", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "Unknown error")
        }
    }
}

private struct MessageView: View {
    let loaded: LoadedMessage
    let save: (MessageSummary.Attachment) -> Void

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(loaded.summary.subject ?? "No Subject")
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline) {
                        Text(sender)
                            .font(.headline)
                        Spacer()
                        if let date = loaded.summary.date {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let to = loaded.summary.to {
                        Text("To: \(to)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(18)

                Divider()
                BodyView(message: loaded.summary)
            }
            .frame(minWidth: 520)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Attachments")
                        .font(.headline)
                    Spacer()
                    Text("\(loaded.summary.attachments.count)")
                        .foregroundStyle(.secondary)
                }

                if loaded.summary.attachments.isEmpty {
                    ContentUnavailableView("No Attachments", systemImage: "paperclip")
                } else {
                    List(loaded.summary.attachments) { attachment in
                        AttachmentRow(attachment: attachment) { save(attachment) }
                    }
                    .listStyle(.inset)
                }
            }
            .padding(14)
            .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
        }
        .navigationTitle(loaded.url.lastPathComponent)
    }

    private var sender: String {
        let name = loaded.summary.senderName ?? "Unknown Sender"
        return loaded.summary.senderEmail.map { "\(name) <\($0)>" } ?? name
    }
}

private struct AttachmentRow: View {
    let attachment: MessageSummary.Attachment
    let save: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.isEmbeddedMessage ? "envelope" : "doc")
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: save) {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("Save attachment")
            .disabled(attachment.isEmbeddedMessage)
        }
        .padding(.vertical, 4)
    }
}
