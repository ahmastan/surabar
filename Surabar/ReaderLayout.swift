import CoreGraphics

/// Reader dimensions shared by the popover and the detached window.
enum ReaderLayout {
    static let headerHeight = 46.0
    static let translationHeight = 72.0
    static let playerHeight = 96.0
    /// A 15-line mushaf page is taller than it is wide.
    static let pageAspect = 1.42
    /// Space kept free between the reader and the bottom of the screen.
    static let screenMargin = 16.0
    static let minimumWidth = 320.0
    static let maximumWidth = 760.0
    static let minimumHeight = 360.0

    static func preferredHeight(width: Double, showTranslation: Bool) -> Double {
        headerHeight + (width * pageAspect).rounded() + (showTranslation ? translationHeight : 0) + playerHeight
    }

    /// The popover size for a width, clamped so it never extends past the visible screen area.
    static func popoverSize(width: Double, showTranslation: Bool, availableHeight: Double) -> CGSize {
        let height = min(preferredHeight(width: width, showTranslation: showTranslation), availableHeight - screenMargin)
        return CGSize(width: width, height: max(height, minimumHeight))
    }
}
