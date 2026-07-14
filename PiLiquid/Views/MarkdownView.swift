import SwiftUI
import WebKit
import AppKit

/// Renders assistant Markdown (with LaTeX via KaTeX) in a transparent,
/// natively-themed WKWebView. The bundled `Web/` folder ships marked.js +
/// KaTeX + fonts so rendering works fully offline. The view sizes itself to
/// its content height, so it drops into the transcript's LazyVStack like any
/// other row.
struct MarkdownView: View {
    let markdown: String
    @State private var height: CGFloat

    init(markdown: String) {
        self.markdown = markdown
        // Re-created views (expanding a collapsed turn, scrolling back, session
        // reload) reserve their previously measured height up front, so rows
        // don't reflow from 1pt as each webview finishes loading.
        _height = State(initialValue: MarkdownHeightCache.height(for: markdown) ?? 1)
    }

    var body: some View {
        MarkdownWebView(markdown: markdown, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Measured content heights keyed by markdown hash. Best-effort: a stale value
/// (e.g. after a window resize) is still a far better initial frame than 1pt,
/// and the live height report corrects it immediately.
@MainActor
enum MarkdownHeightCache {
    private static var store: [Int: CGFloat] = [:]

    static func height(for markdown: String) -> CGFloat? { store[markdown.hashValue] }

    static func set(_ height: CGFloat, for markdown: String) {
        if store.count > 1000 { store.removeAll() }   // crude cap; refills as rows render
        store[markdown.hashValue] = height
    }
}

/// A content-sized web view that bubbles vertical scrolling up to the enclosing
/// SwiftUI `ScrollView` (the transcript), instead of swallowing it. Horizontal
/// scrolls are kept so wide code blocks and tables can still scroll in place.
private final class ScrollForwardingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

private struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "height")
        config.userContentController.add(context.coordinator, name: "copy")

        let webView = ScrollForwardingWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // transparent so the surface shows through
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false

        context.coordinator.webView = webView
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.render(markdown)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "copy")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let height: Binding<CGFloat>
        weak var webView: WKWebView?
        private var loaded = false
        private var pending: String?
        private var lastRendered: String?
        private var lastRunMarkdown: String?
        private var flushScheduled = false

        init(height: Binding<CGFloat>) { self.height = height }

        /// Coalesce rapid (streaming) updates: parsing the full message through
        /// marked + KaTeX on every token floods the web process and the main
        /// thread, so render at most ~12fps, always landing on the latest text.
        func render(_ markdown: String) {
            guard markdown != lastRendered else { return }
            lastRendered = markdown
            guard loaded, webView != nil else { pending = markdown; return }
            scheduleFlush()
        }

        private func scheduleFlush() {
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.flush()
            }
        }

        private func flush() {
            flushScheduled = false
            guard let webView, let markdown = lastRendered, markdown != lastRunMarkdown else { return }
            run(markdown, on: webView)
        }

        private func run(_ markdown: String, on webView: WKWebView) {
            lastRunMarkdown = markdown
            let json = (try? JSONEncoder().encode(markdown)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            webView.evaluateJavaScript("window.render(\(json));", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let pending { run(pending, on: webView); self.pending = nil }
            else if let lastRendered { run(lastRendered, on: webView) }
        }

        /// All message web views share one WebContent process; when the system
        /// kills it (memory pressure), every message blanks at once. Reload the
        /// page — `didFinish` then re-renders `lastRendered` automatically.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loaded = false
            lastRunMarkdown = nil
            if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "height":
                guard let h = message.body as? NSNumber else { return }
                // Pre-render reports (page load / ResizeObserver on the empty
                // document) are 0 — they'd stomp the cached initial height.
                guard let rendered = lastRunMarkdown else { return }
                let value = max(CGFloat(truncating: h), 1)
                DispatchQueue.main.async {
                    if abs(self.height.wrappedValue - value) > 0.5 { self.height.wrappedValue = value }
                    MarkdownHeightCache.set(value, for: rendered)
                }
            case "copy":
                guard let text = message.body as? String else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            default:
                break
            }
        }

        /// Open tapped links in the default browser instead of navigating in-place.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
