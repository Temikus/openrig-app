import Foundation

/// A new rig's name: it becomes the seats' session addresses (seat@rig) and the saved spec's folder name.
public enum RigName {
    /// What's wrong with `name`, for under Continue. Nil when it can be used.
    public static func problem(_ name: String) -> String? {
        if name.isEmpty { return "Name the rig." }
        if name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_-]*/) == nil {
            return "Use letters, digits, - and _ in the name, starting with a letter or digit."
        }
        return nil
    }

    /// A folder name as a rig name: "Payments Service" → "payments-service".
    public static func suggested(_ folder: String) -> String {
        let words = folder.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return words.joined(separator: "-").filter(\.isASCII)
    }

    /// The name once the person picks `folder`. An untyped name follows the folder, until the spec is saved: after
    /// that the saved spec's folder and `name:` are fixed, and a new project folder only changes `--cwd`.
    public static func afterPicking(folder: String, current: String, typed: Bool, saved: Bool) -> String {
        typed || saved ? current : suggested(folder)
    }
}
