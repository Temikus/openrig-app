import Foundation

/// Joins hard-wrapped lines inside paragraphs and list items, so prose reflows to the view's width instead of breaking
/// twice (once where the author wrapped it, again where the view does). Blank lines, headings, list items, quotes and
/// fenced code keep their breaks.
public func reflowedProse(_ text: String) -> String {
    var out: [String] = []
    var inFence = false
    // Whether the last line written can take a continuation: plain text or a list item, not a heading or fence.
    var open = false
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            inFence.toggle()
            out.append(line)
            open = false
        } else if inFence || trimmed.isEmpty {
            out.append(line)
            open = false
        } else if startsBlock(trimmed) {
            out.append(line)
            open = !trimmed.hasPrefix("#")
        } else if open, let last = out.popLast() {
            out.append(last + " " + trimmed)
        } else {
            out.append(line)
            open = true
        }
    }
    return out.joined(separator: "\n")
}

private func startsBlock(_ line: String) -> Bool {
    if line.hasPrefix("#") || line.hasPrefix(">") { return true }
    if ["- ", "* ", "+ "].contains(where: line.hasPrefix) { return true }
    // "1. " or "1) "
    let digits = line.prefix { $0.isNumber }
    let rest = line.dropFirst(digits.count)
    return !digits.isEmpty && (rest.hasPrefix(". ") || rest.hasPrefix(") "))
}
