import CoreGraphics

/// Reader dimensions shared by the popover and the detached window.
enum ReaderLayout {
    static let headerHeight = 46.0
    static let footerHeight = 28.0
    /// Three lines of translation text; longer translations scroll.
    static let translationTextHeight = 54.0
    static let translationHeight = 88.0
    static let playerHeight = 110.0
    /// The now-playing card above the player in "Player only" mode.
    static let nowPlayingHeight = 36.0
    /// "Player only": the header, the now-playing card, and the player, with their dividers.
    static let playerOnlyHeight = headerHeight + 1 + nowPlayingHeight + 1 + playerHeight
    static let settingsTabsHeight = 58.0
    /// The page sits on a rounded "paper" card this far from the window's sides.
    static let pageInset = 8.0
    static let pageCornerRadius = 14.0

    /// The page's width in a window of `width`.
    static func pageWidth(_ width: Double) -> Double { width - 2 * pageInset }
    /// Space kept free between the reader and the bottom of the screen.
    static let screenMargin = 16.0
    static let minimumWidth = 320.0
    static let maximumWidth = 760.0
    static let minimumHeight = 360.0

    /// Everything except the page: header, page footer, player, and the translation strip when shown.
    static func chromeHeight(showTranslation: Bool) -> Double {
        headerHeight + footerHeight + playerHeight + (showTranslation ? translationHeight : 0)
    }

    static func preferredHeight(pageHeight: Double, showTranslation: Bool) -> Double {
        chromeHeight(showTranslation: showTranslation) + pageHeight.rounded(.up)
    }

    /// Settings: the title bar, the tabs and their divider, then the tab's content down to its last setting.
    static func settingsHeight(content: Double) -> Double {
        headerHeight + settingsTabsHeight + 1 + content.rounded(.up)
    }

    /// The popover size, clamped so it never extends past the visible screen area.
    /// The page view shrinks the page to fit when the height is clamped. While Settings are shown
    /// (`settingsContentHeight` is set), the reader fits them exactly in either mode.
    static func popoverSize(width: Double, pageHeight: Double, showTranslation: Bool, availableHeight: Double,
                            mode: ReaderViewMode = .quranAndPlayer, settingsContentHeight: Double? = nil) -> CGSize {
        let limit = availableHeight - screenMargin
        let height: Double
        if let settingsContentHeight {
            height = min(settingsHeight(content: settingsContentHeight), limit)
        } else if mode == .playerOnly {
            height = playerOnlyHeight
        } else {
            height = max(min(preferredHeight(pageHeight: pageHeight, showTranslation: showTranslation), limit), minimumHeight)
        }
        return CGSize(width: width, height: height)
    }
}
