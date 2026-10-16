import AppKit
import ApplicationServices
import PaddingtonCore

/// Every app's windows for the window list (knob bank B): apps front to back, each app's windows in its own
/// order (front first). Titles come from Accessibility (window names from CGWindowList need Screen Recording).
public enum WindowList {
    static let sep = "\u{1F}"

    public static func items() -> [PickerItem] {
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [pid_t] = []
        for w in onScreen where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t, !order.contains(pid) { order.append(pid) }
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .sorted { (order.firstIndex(of: $0.processIdentifier) ?? Int.max) < (order.firstIndex(of: $1.processIdentifier) ?? Int.max) }
        var items: [PickerItem] = []
        for app in apps {
            let name = app.localizedName ?? "?"
            for (i, w) in windows(of: app.processIdentifier).enumerated() {
                let title = string(w, kAXTitleAttribute)
                let minimised = (value(w, kAXMinimizedAttribute) as? Bool) == true
                let label = "\(name) — \(title.isEmpty ? "window \(i + 1)" : title)\(minimised ? " (minimised)" : "")"
                let id = "\(app.processIdentifier)\(sep)\(i)\(sep)\(title)"
                items.append(PickerItem(label: label, value: id, action: .focusWindow(id), detail: name))
            }
        }
        return items
    }

    /// Bring one window to the front: matched by title (the list may have shifted), else by its position.
    public static func focus(_ id: String) throws {
        let p = id.components(separatedBy: sep)
        guard p.count >= 3, let pid = pid_t(p[0]), let idx = Int(p[1]),
              let app = NSRunningApplication(processIdentifier: pid) else { throw KeyError("that window's app is gone") }
        let wins = windows(of: pid)
        let title = p[2...].joined(separator: sep)
        guard let w = (title.isEmpty ? nil : wins.first { string($0, kAXTitleAttribute) == title }) ?? (idx < wins.count ? wins[idx] : nil) else {
            throw KeyError("that window is gone")
        }
        if (value(w, kAXMinimizedAttribute) as? Bool) == true { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        app.activate()
    }

    /// An app's ordinary windows (no panels, sheets or hidden helper windows).
    static func windows(of pid: pid_t) -> [AXUIElement] {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.25)        // a hung app mustn't stall the list
        guard let wins = value(ax, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return wins.filter { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
    }

    static func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }
    static func string(_ e: AXUIElement, _ attr: String) -> String { value(e, attr) as? String ?? "" }
}
