import AppKit
import SwiftUI

/// A small AppKit bridge so the composer gets native text input, selection, undo,
/// and input-method behavior while remaining usable from a SwiftUI hierarchy.
@MainActor
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusRequested: Bool
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        textView.setAccessibilityRole(.textField)
        textView.setAccessibilityLabel("Message composer")
        textView.setAccessibilityHelp("Type a message and press Return to send. Press Shift-Return for a new line.")

        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.owner = self
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        if let textView = scrollView.documentView as? PlaceholderTextView {
            textView.placeholder = placeholder
            textView.onDidBecomeFirstResponder = {
                focusRequested = false
            }
            textView.shouldBecomeFirstResponder = focusRequested
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: ComposerTextView

        init(owner: ComposerTextView) {
            self.owner = owner
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            owner.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let isReturn = commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            guard isReturn else { return false }

            if textView.window?.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }

            owner.onSubmit()
            return true
        }
    }
}

@MainActor
private final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var shouldBecomeFirstResponder = false {
        didSet {
            if shouldBecomeFirstResponder {
                attemptToBecomeFirstResponder()
            }
        }
    }
    var onDidBecomeFirstResponder: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attemptToBecomeFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            shouldBecomeFirstResponder = false
            onDidBecomeFirstResponder?()
        }
        return becameFirstResponder
    }

    private func attemptToBecomeFirstResponder() {
        guard shouldBecomeFirstResponder, let window else { return }
        _ = window.makeFirstResponder(self)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText() else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let inset = textContainerInset
        let rect = NSRect(
            x: inset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: inset.height,
            width: max(0, bounds.width - (inset.width * 2)),
            height: max(0, bounds.height - (inset.height * 2))
        )
        placeholder.draw(in: rect, withAttributes: attributes)
    }
}
