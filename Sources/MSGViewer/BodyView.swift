import AppKit
import SwiftUI
import WebKit

struct BodyView: View {
    let message: MessageSummary
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let html = message.htmlBody {
            OfflineHTMLView(html: html)
        } else if let rtf = message.rtfBody {
            RTFView(rtf: rtf, isDark: colorScheme == .dark)
        } else {
            // Rendered by the web view so find, print and zoom work for every body type.
            let text = (message.plainBody ?? "No message body")
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            OfflineHTMLView(html: "<div style=\"white-space:pre-wrap\">\(text)</div>")
        }
    }
}

extension NSView {
    /// The message body's web or text view somewhere inside a hosting view.
    var bodyView: NSView? {
        self is WKWebView || self is NSTextView ? self : subviews.lazy.compactMap(\.bodyView).first
    }
}

extension MessageWindowController {
    private var body: NSView? { window?.contentView?.bodyView }

    func printBody() {
        guard let body, let window else { return }
        let operation: NSPrintOperation
        if let web = body as? WKWebView {
            operation = web.printOperation(with: .shared)
            operation.view?.frame = web.bounds
        } else {
            operation = NSPrintOperation(view: body, printInfo: .shared)
        }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func showFind(_ sender: Any?) {
        guard let body else { return }
        // ponytail: WKWebView has no find bar on macOS, so HTML bodies get a prompt + ⌘G; replace with an in-window bar if this feels clumsy.
        guard body is WKWebView else {
            window?.makeFirstResponder(body)
            body.performTextFinderAction(sender)
            return
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = lastFind
        let alert = NSAlert()
        alert.messageText = "Find in Message"
        alert.accessoryView = field
        alert.addButton(withTitle: "Find")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        lastFind = field.stringValue
        findNext()
    }

    func findNext() {
        guard let web = body as? WKWebView, !lastFind.isEmpty else { return }
        let query = lastFind
        Task { if (try? await web.find(query))?.matchFound != true { NSSound.beep() } }
    }

    /// Multiplies the current zoom by `factor`; nil resets to 100%.
    func zoom(by factor: CGFloat?) {
        func apply(_ current: CGFloat) -> CGFloat { factor.map { min(3, max(0.5, current * $0)) } ?? 1 }
        if let web = body as? WKWebView {
            web.pageZoom = apply(web.pageZoom)
        } else if let scrollView = (body as? NSTextView)?.enclosingScrollView {
            scrollView.magnification = apply(scrollView.magnification)
        }
    }
}

private struct RTFView: NSViewRepresentable {
    let rtf: String
    let isDark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        let textView = NSTextView()
        textView.usesFindBar = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.rtf != rtf || context.coordinator.isDark != isDark,
              let textView = scrollView.documentView as? NSTextView,
              let data = rtf.data(using: .windowsCP1252),
              let value = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ) else { return }
        let readable = NSMutableAttributedString(attributedString: value)
        if isDark {
            let range = NSRange(location: 0, length: readable.length)
            readable.removeAttribute(.backgroundColor, range: range)
            readable.addAttribute(
                .foregroundColor,
                value: NSColor(calibratedWhite: 0.9, alpha: 1),
                range: range
            )
        }
        context.coordinator.rtf = rtf
        context.coordinator.isDark = isDark
        textView.textStorage?.setAttributedString(readable)
    }

    final class Coordinator {
        var rtf: String?
        var isDark: Bool?
    }
}

private struct OfflineHTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:\">"
        let style = "<style>html{color-scheme:light dark}body{font:14px -apple-system;padding:18px;line-height:1.45;margin:0}table{max-width:100%;border-collapse:collapse}td,th{padding:3px}img{max-width:100%;height:auto}@media screen and (prefers-color-scheme:dark){body,body *{color:#eee!important;background-color:transparent!important;border-color:#666!important}}</style>"
        view.loadHTMLString(policy + style + html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Links open in the default app; the web view itself never navigates, so it stays offline.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
                NSWorkspace.shared.open(url)
            }
            return navigationAction.navigationType == .other ? .allow : .cancel
        }
    }
}
