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
            ScrollView {
                Text(message.plainBody ?? "No message body")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
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
        let textView = NSTextView()
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
        let style = "<style>html{color-scheme:light dark}body{font:14px -apple-system;padding:18px;line-height:1.45;margin:0}table{max-width:100%;border-collapse:collapse}td,th{padding:3px}img{max-width:100%;height:auto}@media(prefers-color-scheme:dark){body,body *{color:#eee!important;background-color:transparent!important;border-color:#666!important}}</style>"
        view.loadHTMLString(policy + style + html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.navigationType == .other ? .allow : .cancel
        }
    }
}
