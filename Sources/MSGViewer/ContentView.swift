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
                MessageView(store: store, loaded: loaded)
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
    @ObservedObject var store: MessageStore
    let loaded: LoadedMessage
    @State private var recipientsExpanded = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        if store.canGoBack {
                            Button(action: store.goBack) { Image(systemName: "chevron.left") }
                                .buttonStyle(.borderless)
                                .help("Back to parent message")
                        }
                        Text(loaded.summary.subject ?? "No Subject")
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(sender)
                            .font(.headline)
                        Spacer()
                        if let date = loaded.summary.date {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if loaded.summary.recipientCount > 0 {
                        DisclosureGroup(isExpanded: $recipientsExpanded) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let to = loaded.summary.to {
                                        RecipientLine(label: "To", value: to)
                                    }
                                    if let cc = loaded.summary.cc {
                                        RecipientLine(label: "Cc", value: cc)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        } label: {
                            Text("Recipients (\(loaded.summary.recipientCount))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                    Button("Save All", action: store.saveAll)
                        .controlSize(.small)
                        .disabled(!loaded.summary.attachments.contains { !$0.isEmbeddedMessage })
                }

                if loaded.summary.attachments.isEmpty {
                    ContentUnavailableView("No Attachments", systemImage: "paperclip")
                } else {
                    List(loaded.summary.attachments, selection: $store.selectedAttachmentID) { attachment in
                        AttachmentRow(store: store, attachment: attachment)
                            .tag(attachment.id)
                    }
                    .listStyle(.inset)
                    .focusEffectDisabled()
                    .onKeyPress(.space) { store.previewSelected() ? .handled : .ignored }
                }
            }
            .padding(14)
            .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
        }
        .navigationTitle(loaded.displayName)
    }

    private var sender: String {
        let name = loaded.summary.senderName ?? "Unknown Sender"
        return loaded.summary.senderEmail.map { "\(name) <\($0)>" } ?? name
    }
}

private struct RecipientLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
}

private struct AttachmentRow: View {
    let store: MessageStore
    let attachment: MessageSummary.Attachment

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
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .help("Attachment actions")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            attachment.isEmbeddedMessage ? store.openEmbedded(attachment) : store.openAttachment(attachment)
        }
        .simultaneousGesture(TapGesture().onEnded { store.selectedAttachmentID = attachment.id })
        .onDrag { attachment.isEmbeddedMessage ? NSItemProvider() : store.itemProvider(for: attachment) }
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        if attachment.isEmbeddedMessage {
            Button("Open Message") { store.openEmbedded(attachment) }
        } else {
            Button("Quick Look") { store.preview(attachment) }
            Button("Open") { store.openAttachment(attachment) }
            Divider()
            Button("Save As...") { store.save(attachment) }
        }
    }
}
