#if DEBUG
    import AppKit

    /// OPENRIG_DEBUG_AX=<file>[,<tabs>]: after launch settles, writes the main window's accessibility tree as the app
    /// itself serves it (macOS hides other apps' windows from AX while the screen is locked), then moves keyboard
    /// focus `tabs` times as Tab would and logs each stop. Moving focus sends nothing to tmux.
    enum OpenRigDebug {
        /// The rig OPENRIG_DEBUG_OPEN names; the main window's title starts with it.
        static var rigName: String {
            String(ProcessInfo.processInfo.environment["OPENRIG_DEBUG_OPEN"]?.split(separator: "/").first ?? "")
        }
    }

    @MainActor
    enum AccessibilityDump {
        static func run() async {
            guard let spec = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_AX"] else { return }
            let parts = spec.split(separator: ",")
            let path = String(parts[0])
            let tabs = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            try? await Task.sleep(for: .seconds(6))
            // The main window, not the menu bar item's own window ("Item-0").
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix(OpenRigDebug.rigName) })
            else {
                let all = NSApp.windows.map { "\(type(of: $0)) \"\($0.title)\" visible=\($0.isVisible)" }
                try? all.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                return
            }
            // Menu items read focused scene values from the key window; while the screen is locked there is none,
            // and they all read as off.
            var out = "key window: \(NSApp.keyWindow?.title ?? "none"), dumping \"\(window.title)\" with "
            out += "\(window.accessibilityChildren()?.count ?? -1) children\n"
            dump(window, depth: 0, into: &out)
            out += "\n# Menus\n"
            for top in NSApp.mainMenu?.items ?? [] {
                guard let menu = top.submenu else { continue }
                menu.update()
                out += "\(top.title): "
                out += menu.items.map { item in
                    item.isSeparatorItem
                        ? "|"
                        : "\(item.title)\(item.keyEquivalent.isEmpty ? "" : " ⌘" + item.keyEquivalent)\(item.isEnabled ? "" : " (off)")"
                }.joined(separator: ", ")
                out += "\n"
            }
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

    /// OPENRIG_DEBUG_RESPONDER=<file>: ten times a second, writes the main window's first responder whenever it
    /// changes, with Type mode's state, to check where keys go without pressing any. A terminal view says whether it
    /// takes keys (`interactive`). Each launch replaces the file.
    @MainActor
    enum ResponderLog {
        /// Started once: the rig list refreshes again whenever no rig is selected, and this loop never ends.
        private static var started = false

        static func run(typing: @escaping @MainActor () -> Bool) async {
            guard !started, let path = ProcessInfo.processInfo.environment["OPENRIG_DEBUG_RESPONDER"] else { return }
            started = true
            var last = ""
            var first = true
            let start = Date.now
            while true {
                let window = NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(OpenRigDebug.rigName) }
                let responder = window?.firstResponder
                let keys = (responder as? TileTerminalView).map { " interactive=\($0.interactive)" } ?? ""
                let line =
                    "\(responder.map { String(describing: type(of: $0)) } ?? "nil")\(keys)"
                    + "\(window != nil && responder === window ? " (the window)" : "") typing=\(typing())"
                if line != last {
                    let at = String(format: "%.1f", Date.now.timeIntervalSince(start))
                    let entry = "\(at)s \(line)\n"
                    if !first, let handle = FileHandle(forWritingAtPath: path) {
                        handle.seekToEndOfFile()
                        handle.write(Data(entry.utf8))
                        try? handle.close()
                    } else {
                        try? entry.write(toFile: path, atomically: true, encoding: .utf8)
                    }
                    first = false
                    last = line
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
#endif
