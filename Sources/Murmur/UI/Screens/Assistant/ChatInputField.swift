import AppKit
import SwiftUI

/// The chat's multi-line input. A thin `NSTextView` wrapper rather than a SwiftUI `TextField`,
/// because the key contract has to be exact: Return sends, ⇧Return (or ⌥Return) inserts a
/// newline. `NSTextView` reports Return as `insertNewline:` through its delegate, which is the
/// one reliable place to tell the two apart. Grows with its content up to `maxHeight`, then
/// scrolls.
struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var onSubmit: () -> Void
    @Binding var height: CGFloat

    static let minHeight: CGFloat = 20
    static let maxHeight: CGFloat = 120

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13.5)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityHelp("Return sends. Shift-Return adds a new line.")
        context.coordinator.placeholder = placeholder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.recalculateHeight(textView)
        }
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 13.5)])
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputField
        var placeholder = ""

        init(_ parent: ChatInputField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let clamped = min(max(used, ChatInputField.minHeight), ChatInputField.maxHeight)
            guard abs(parent.height - clamped) > 0.5 else { return }
            // Deferred: this also runs from `updateNSView`, where writing state is not allowed.
            let binding = parent.$height
            DispatchQueue.main.async { binding.wrappedValue = clamped }
        }
    }
}

extension NSTextView {
    /// `NSTextView` draws `placeholderAttributedString` when empty, but only exposes it via KVC.
    fileprivate var placeholderAttributedString: NSAttributedString? {
        get { value(forKey: "placeholderAttributedString") as? NSAttributedString }
        set { setValue(newValue, forKey: "placeholderAttributedString") }
    }
}
