import AppKit
import ApplicationServices

/// A small text window for dictated or typed input (e.g. the task for a new worktree).
/// It takes focus so VoiceInk can paste into it, then hands focus back to the previous app.
public final class InputWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow?
    private var field: NSTextField?
    private var previous: NSRunningApplication?
    private var done: ((String?) -> Void)?
    private var lastText = ""
    /// Live edits: (text now, characters added by this edit — a VoiceInk paste adds many at once).
    public var onChange: ((String, Int) -> Void)?
    public var isOpen: Bool { window != nil }

    public override init() { super.init() }

    public func open(prompt: String, hint: String? = nil, completion: @escaping (String?) -> Void) {
        close(nil)
        done = completion
        lastText = ""
        previous = NSWorkspace.shared.frontmostApplication
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 118),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "padctl — \(prompt)"
        // above floating terminals (an iTerm hotkey window sits at level 22) and on every Space, like the legend
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.delegate = self
        let label = NSTextField(labelWithString: hint ?? "\(prompt) — hold ● to dictate · ▶ or Enter to go · ⏸ or Esc to cancel")
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
        Self.takeFocus()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(f)
        // the box must have keyboard focus: VoiceInk pastes into the focused window (else into the terminal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let w = self.window else { return }
            if !(NSApp.isActive && w.isKeyWindow) {
                Self.takeFocus()
                w.makeKeyAndOrderFront(nil); w.makeFirstResponder(self.field)
            }
            Log.write("input box: focused=\(NSApp.isActive && w.isKeyWindow) (front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
        }
    }

    /// macOS 14+ treats activation as a request another app can win; Accessibility (which padctl has)
    /// makes padctl frontmost the way window managers do.
    static func takeFocus() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.isActive {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    @objc func submitField() { submit() }

    public func submit() {
        let text = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        close(text.isEmpty ? nil : text)
    }

    public func cancel() { close(nil) }

    /// Put text in the box as if it had been typed or pasted (dictation caught elsewhere).
    public func setText(_ t: String) {
        guard let f = field else { return }
        f.stringValue = t
        let added = t.count - lastText.count
        lastText = t
        onChange?(t, max(added, t.count))
    }

    /// Close without reporting anything (the choice was made elsewhere, e.g. on the pad).
    public func dismiss() { done = nil; onChange = nil; close(nil) }

    public func controlTextDidChange(_ n: Notification) {
        let t = field?.stringValue ?? ""
        let added = t.count - lastText.count
        lastText = t
        onChange?(t, added)
    }

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
        let cb = done; done = nil; onChange = nil
        previous?.activate()
        previous = nil
        cb?(result)
    }
}
