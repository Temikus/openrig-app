#if DEBUG
    import AppKit

    /// OPENRIG_DEBUG_AX=<file>[,<tabs>]: after launch settles, writes the main window's accessibility tree as the app
    /// itself serves it (macOS hides other apps' windows from AX while the screen is locked), then moves keyboard
    /// focus `tabs` times as Tab would and logs each stop. Moving focus sends nothing to tmux.
    @MainActor
    enum AccessibilityDump {
        static func run() async {
            guard let spec = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_AX"] else { return }
            let parts = spec.split(separator: ",")
            let path = String(parts[0])
            let tabs = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            try? await Task.sleep(for: .seconds(6))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "" && !($0 is NSPanel) })
            else { return }
            var out = ""
            dump(window, depth: 0, into: &out)
            out += "\n# Views that take Tab\n"
            keyViews(window.contentView, into: &out)
            out += "\n# Tab stops\n"
            for _ in 0..<tabs {
                window.selectNextKeyView(nil)
                try? await Task.sleep(for: .milliseconds(200))
                let responder = window.firstResponder
                let element = responder.map(describe) ?? "nil"
                out += "\(responder.map { String(describing: type(of: $0)) } ?? "nil"): \(element)\n"
            }
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
        }

        private static func describe(_ element: Any) -> String {
            let e = element as AnyObject
            let read = Selector(("accessibilityValue"))
            let raw = (element as? NSObject)?.responds(to: read) == true ? e.perform(read)?.takeUnretainedValue() : nil
            let value =
                (raw as? String ?? raw.map { "\($0)" }).map { $0.replacingOccurrences(of: "\n", with: "⏎") } ?? ""
            let selected = (e.isAccessibilitySelected?() ?? false) ? " [selected]" : ""
            return
                "\(e.accessibilityRole?()?.rawValue ?? "-") \"\(e.accessibilityLabel?() ?? "")\" "
                + "title=\"\(e.accessibilityTitle?() ?? "")\" value=\"\(value.prefix(120))\" "
                + "help=\"\(e.accessibilityHelp?() ?? "")\"\(selected) frame=\(e.accessibilityFrame?().integral ?? .zero)"
        }

        private static func keyViews(_ view: NSView?, into out: inout String) {
            guard let view else { return }
            if view.canBecomeKeyView { out += "\(type(of: view)): \(describe(view))\n" }
            view.subviews.forEach { keyViews($0, into: &out) }
        }

        private static func dump(_ element: Any, depth: Int, into out: inout String) {
            guard depth < 60 else { return }
            let e = element as AnyObject
            let ignored = !(e.isAccessibilityElement?() ?? true)
            if !ignored { out += String(repeating: "  ", count: depth) + describe(element) + "\n" }
            for child in (e.accessibilityChildren?() ?? nil) ?? [] {
                dump(child, depth: ignored ? depth : depth + 1, into: &out)
            }
        }
    }
#endif
