/// Whether a prompt's command has been read to its end, so Allow once can turn on.
public enum CommandEnd {
    /// `endY` is the end of the command in the scroll content's coordinates. The rest is SwiftUI's `ScrollGeometry`:
    /// its `containerSize` already leaves out the content insets, the pinned buttons among them (measured on iOS 27:
    /// 874 pt screen, 116 top, 160 bottom, 598 container). So the visible region ends at offset + top inset + height,
    /// and content under the buttons never counts as seen.
    public static func isSeen(endY: Double, offsetY: Double, topInset: Double, visibleHeight: Double) -> Bool {
        offsetY + topInset + visibleHeight >= endY
    }
}
