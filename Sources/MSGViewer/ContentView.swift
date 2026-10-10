import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: MessageStore

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
                    Button("Open Message...") { (NSApp.delegate as? AppDelegate)?.showOpenPanel(replacing: store) }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            (NSApp.delegate as? AppDelegate)?.open(urls, replacing: store)
            return !urls.isEmpty
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
    @State private var showHeaders = false

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
                        if loaded.summary.headers != nil {
                            Button("Headers") { showHeaders = true }
                                .buttonStyle(.link)
                                .controlSize(.small)
                        }
                        if let date = loaded.summary.date {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !recipientLines.isEmpty {
                        DisclosureGroup(isExpanded: $recipientsExpanded) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(recipientLines, id: \.label) { RecipientLine(label: $0.label, value: $0.value) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        } label: {
                            Text(loaded.summary.recipientCount > 0 ? "Recipients (\(loaded.summary.recipientCount))" : "Recipients")
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
        .sheet(isPresented: $showHeaders) { HeadersSheet(text: loaded.summary.headers ?? "") }
    }

    private var recipientLines: [(label: String, value: String)] {
        Recipient.Kind.allCases.compactMap { kind in
            loaded.summary.addresses(for: kind).map { (kind.label, $0) }
        }
    }

    private var sender: String {
        let name = loaded.summary.senderName ?? "Unknown Sender"
        return loaded.summary.senderEmail.map { "\(name) <\($0)>" } ?? name
    }
}

private struct HeadersSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .trailing) {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(width: 640, height: 420)
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
            if attachment.isEmbeddedMessage {
                Image(systemName: "envelope")
                    .font(.title3)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (attachment.name as NSString).pathExtension) ?? .data))
                    .resizable()
                    .frame(width: 24, height: 24)
            }
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
