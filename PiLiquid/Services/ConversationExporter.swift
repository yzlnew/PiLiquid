import SwiftUI
import AppKit
import WebKit

/// Turns a conversation into shareable artifacts: a long PNG rendered through
/// the *same* Markdown + KaTeX pipeline as the live transcript (so formulas,
/// tables, code and skill chips all match), or the raw pi session `.jsonl`.
@MainActor
enum ConversationExporter {
    /// Render the whole conversation to one tall PNG (via an offscreen WebView)
    /// and write it to a temp file, returning the URL. Sharing the *file* keeps
    /// the artifact a compact PNG — sharing a bare `NSImage` makes the share
    /// sheet fall back to a huge uncompressed TIFF. Async: waits on page layout
    /// + web fonts.
    static func imageFile(items: [TranscriptItem], title: String, subtitle: String) async -> URL? {
        let entries = payload(items: items)
        guard !entries.isEmpty else { return nil }
        let data: [String: Any] = ["title": title, "subtitle": subtitle, "items": entries]
        guard let json = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: json, encoding: .utf8),
              let png = await WebExportRenderer().renderPNG(conversation: jsonString) else { return nil }

        let name = fileName(from: title)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try png.write(to: url); return url } catch { return nil }
    }

    /// A friendly, filesystem-safe `.png` name from the project/session title.
    private static func fileName(from title: String) -> String {
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return (cleaned.isEmpty ? "Conversation" : cleaned) + ".png"
    }

    /// Present the macOS share sheet for the given items (an NSImage, a file
    /// URL, …), anchored to `anchor`. The sheet's "Save to Files" covers plain
    /// export too.
    static func share(_ items: [Any], from anchor: NSView) {
        guard !items.isEmpty else { return }
        NSSharingServicePicker(items: items)
            .show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    // MARK: - Transcript → export payload

    /// Flatten the transcript into the JSON items `export.html` expects, mirroring
    /// what the transcript actually shows: skill/prompt invocations collapse to a
    /// chip, tool calls are one compact line, thinking is dropped.
    private static func payload(items: [TranscriptItem]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for item in items {
            switch item {
            case .user(let e):
                if let inv = invocation(in: e.text) {
                    out.append(["type": "user", "source": inv.source, "name": inv.name, "text": inv.userText])
                } else if !e.text.isEmpty {
                    out.append(["type": "user", "text": e.text])
                }
            case .assistant(let e):
                let text = e.segments.compactMap { seg -> String? in
                    if case .text(let t) = seg, !t.isEmpty { return t }   // thinking dropped
                    return nil
                }.joined(separator: "\n\n")
                if !text.isEmpty { out.append(["type": "assistant", "text": text]) }
            case .tool(let e):
                var d: [String: Any] = ["type": "tool", "name": e.name, "args": e.argsSummary]
                if let diff = e.diff {
                    if diff.addedCount > 0 { d["added"] = diff.addedCount }
                    if diff.removedCount > 0 { d["removed"] = diff.removedCount }
                }
                out.append(d)
            case .notice(let e):
                out.append(["type": "notice", "text": e.text])
            }
        }
        return out
    }

    /// Port of `UserRow.invocation`: detect a leading `<skill|prompt|command|
    /// extension name="…">…</…>` injected block so the export collapses it to a
    /// chip and keeps only the user's own trailing text.
    private static func invocation(in text: String) -> (source: String, name: String, userText: String)? {
        guard text.hasPrefix("<"),
              let tagEnd = text[text.index(after: text.startIndex)...].firstIndex(where: { $0 == " " || $0 == ">" })
        else { return nil }
        let tag = String(text[text.index(after: text.startIndex)..<tagEnd])
        guard ["skill", "prompt", "command", "extension"].contains(tag),
              let open = text.range(of: "name=\""),
              let close = text[open.upperBound...].firstIndex(of: "\"")
        else { return nil }
        let name = String(text[open.upperBound..<close])
        guard !name.isEmpty else { return nil }

        let closeTag = "</\(tag)>"
        let userText: String
        if let end = text.range(of: closeTag) {
            userText = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            userText = ""
        }
        let source = (tag == "command") ? "extension" : tag
        return (source, name, userText)
    }
}

/// One-shot offscreen WebView that renders `export.html` for a conversation and
/// captures it as a full-height image. Kept alive by the `await` in `render`.
@MainActor
private final class WebExportRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let width: CGFloat = 760
    private var webView: WKWebView?
    private var conversation: String?
    private var heightContinuation: CheckedContinuation<CGFloat, Never>?

    func renderPNG(conversation json: String) async -> Data? {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "exported")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1200), configuration: config)
        webView.navigationDelegate = self
        self.webView = webView
        self.conversation = json

        // Host offscreen inside a real window so the page actually lays out
        // (a detached WebView may never render). Positioned far outside the
        // visible bounds and removed as soon as we're done.
        guard let host = NSApp.keyWindow?.contentView
            ?? NSApp.mainWindow?.contentView
            ?? NSApp.windows.first(where: { $0.contentView != nil })?.contentView
        else { return nil }
        webView.frame = CGRect(x: -30000, y: 0, width: width, height: 1200)
        host.addSubview(webView)
        defer {
            webView.removeFromSuperview()
            config.userContentController.removeScriptMessageHandler(forName: "exported")
            self.webView = nil
        }

        guard let url = Bundle.main.url(forResource: "export", withExtension: "html", subdirectory: "Web") else { return nil }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        // Wait for the page to report its settled content height.
        let height = await withCheckedContinuation { (cont: CheckedContinuation<CGFloat, Never>) in
            heightContinuation = cont
        }
        guard height > 1 else { return nil }

        webView.frame = CGRect(x: -30000, y: 0, width: width, height: height)
        try? await Task.sleep(for: .milliseconds(60))   // let the resize settle
        return await capturePNG(webView, height: height)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let conversation else { return }
        self.conversation = nil
        webView.evaluateJavaScript("window.renderConversation(\(conversation));", completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "exported", let h = message.body as? NSNumber else { return }
        heightContinuation?.resume(returning: CGFloat(truncating: h))
        heightContinuation = nil
    }

    /// Capture the full page as a PDF (no CoreAnimation texture-size cap),
    /// rasterize it to a 2× bitmap, and encode as PNG.
    private func capturePNG(_ webView: WKWebView, height: CGFloat) async -> Data? {
        let cfg = WKPDFConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: width, height: height)
        let pdf: Data? = await withCheckedContinuation { cont in
            webView.createPDF(configuration: cfg) { result in
                cont.resume(returning: try? result.get())
            }
        }
        guard let pdf, let pdfImage = NSImage(data: pdf) else { return nil }

        let scale: CGFloat = 2
        let size = NSSize(width: width, height: height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        pdfImage.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}

/// Captures the backing `NSView` of the SwiftUI view it's attached to, so an
/// AppKit share sheet can anchor to it.
struct ViewAnchor: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if view.window != nil { onResolve(view) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if nsView.window != nil { onResolve(nsView) } }
    }
}
