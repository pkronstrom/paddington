import AppKit

/// A small text window for dictated or typed input (e.g. the task for a new worktree).
/// It takes focus so VoiceInk can paste into it, then hands focus back to the previous app.
public final class InputWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow?
    private var field: NSTextField?
    private var previous: NSRunningApplication?
    private var done: ((String?) -> Void)?
    public var isOpen: Bool { window != nil }

    public override init() { super.init() }

    public func open(prompt: String, completion: @escaping (String?) -> Void) {
        close(nil)
        done = completion
        previous = NSWorkspace.shared.frontmostApplication
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 118),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "padctl — \(prompt)"
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.delegate = self
        let label = NSTextField(labelWithString: "\(prompt) — hold ● to dictate · ▶ or Enter to go · ⏸ or Esc to cancel")
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 16, y: 78, width: 528, height: 18)
        let f = NSTextField(frame: NSRect(x: 16, y: 20, width: 528, height: 48))
        f.font = .systemFont(ofSize: 15)
        f.placeholderString = prompt
        f.delegate = self
        f.target = self; f.action = #selector(submitField)
        f.cell?.wraps = true; f.cell?.isScrollable = false
        w.contentView?.addSubview(label); w.contentView?.addSubview(f)
        w.center()
        window = w; field = f
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(f)
    }

    @objc func submitField() { submit() }

    public func submit() {
        let text = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        close(text.isEmpty ? nil : text)
    }

    public func cancel() { close(nil) }

    public func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }

    public func windowWillClose(_ n: Notification) { if window != nil { finish(nil) } }

    private func close(_ result: String?) {
        guard let w = window else { return }
        window = nil; field = nil
        w.delegate = nil
        w.orderOut(nil)
        finish(result)
    }

    private func finish(_ result: String?) {
        window = nil
        let cb = done; done = nil
        previous?.activate()
        previous = nil
        cb?(result)
    }
}
