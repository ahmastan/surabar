import AppKit

// AppKit entry point. The app is menu-bar-only (LSUIElement), so there is no main window or app menu.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
