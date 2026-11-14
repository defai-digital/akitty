import AppKit

/// The find bar. Return moves to the next hit, Shift-Return to the previous, and Escape closes it.
@MainActor final class FindBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    let status = NSTextField(labelWithString: "")
    var onChange: (() -> Void)?, onSubmit: ((Bool) -> Void)?, onCancel: (() -> Void)?, onStep: ((Bool) -> Void)?
    var query: String { field.stringValue }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.placeholderString = "Find in scrollback"; field.delegate = self
        field.setAccessibilityLabel("Find in scrollback"); field.setAccessibilityIdentifier("find-query")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("find-status")
        let previous = button("chevron.left", "Find previous", identifier: "find-previous", action: #selector(stepBackward(_:)))
        let next = button("chevron.right", "Find next", identifier: "find-next", action: #selector(stepForward(_:)))
        let close = button("xmark", "Close find", identifier: "find-close", action: #selector(closeClicked(_:)))
        let stack = NSStackView(views: [field, previous, next, status, close])
        stack.orientation = .horizontal; stack.spacing = 6; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidChange(_ obj: Notification) { onChange?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { onSubmit?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        return false
    }
    @objc private func stepBackward(_ sender: Any?) { onStep?(true) }
    @objc private func stepForward(_ sender: Any?) { onStep?(false) }
    @objc private func closeClicked(_ sender: Any?) { onCancel?() }
    private func button(_ symbol: String, _ label: String, identifier: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .smallSquare; button.imageScaling = .scaleProportionallyDown
        button.toolTip = label; button.setAccessibilityLabel(label); button.setAccessibilityIdentifier(identifier)
        return button
    }
}
