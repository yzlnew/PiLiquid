import SwiftUI
import AppKit

/// A borderless, transparent text field for the sidebar search bar. SwiftUI's
/// `TextField` draws an opaque white editing background on macOS; this AppKit
/// field draws nothing, so it sits cleanly inside a SwiftUI capsule whose icon
/// and text can be aligned with the rows below it.
struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = String(localized: "Search")
    var fontSize: CGFloat = 14
    var automaticallyFocus = false
    var onCancel: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderAttributedString = placeholderString
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if automaticallyFocus {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderAttributedString = placeholderString
    }

    /// AppKit's default placeholder renders darker than the SwiftUI `.secondary`
    /// gray used by the adjacent magnifier icon. Draw it in `secondaryLabelColor`
    /// so the placeholder matches the rest of the search bar's gray.
    private var placeholderString: NSAttributedString {
        NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: SearchTextField
        init(_ parent: SearchTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)),
                  let onCancel = parent.onCancel else { return false }
            onCancel()
            return true
        }
    }
}

/// A self-contained search capsule (magnifier + field + clear button) for places
/// that just need a search box without row alignment (e.g. the branch picker).
struct SearchBar: View {
    @Binding var text: String
    var placeholder: String = String(localized: "Search")

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            SearchTextField(text: $text, placeholder: placeholder, fontSize: 13)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DS.chipFill, in: Capsule())
    }
}
