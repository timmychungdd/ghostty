import AppKit

class HiddenTitlebarTerminalWindow: TerminalWindow {
    // No titlebar, we don't support accessories.
    override var supportsUpdateAccessory: Bool { false }

    override func awakeFromNib() {
        super.awakeFromNib()

        // Setup our initial style
        reapplyHiddenStyle()

        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fullscreenDidExit(_:)),
            name: .fullscreenDidExit,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private static let hiddenStyleMask: NSWindow.StyleMask = [
        // We need `titled` in the mask to get the normal window frame
        .titled,

        // Full size content view so we can extend
        // content in to the hidden titlebar's area
        .fullSizeContentView,

        .resizable,
        .closable,
        .miniaturizable,
    ]

    /// Apply the hidden titlebar style.
    private func reapplyHiddenStyle() {
        // If our window is fullscreen then we don't reapply the hidden style because
        // it can result in messing up non-native fullscreen. See:
        // https://github.com/ghostty-org/ghostty/issues/8415
        if terminalController?.fullscreenStyle?.isFullscreen ?? false {
            return
        }

        // Apply our style mask while preserving the .fullScreen option
        if styleMask.contains(.fullScreen) {
            styleMask = Self.hiddenStyleMask.union([.fullScreen])
        } else {
            styleMask = Self.hiddenStyleMask
        }

        // Hide the title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Fork: keep the traffic lights visible. Upstream hides them (and
        // nukes NSTitlebarContainerView below) for the hidden style; the
        // fork wants the window buttons without the tab strip. With
        // titleVisibility hidden + titlebarAppearsTransparent, the
        // container draws nothing but the buttons.
        standardWindowButton(.closeButton)?.isHidden = false
        standardWindowButton(.miniaturizeButton)?.isHidden = false
        standardWindowButton(.zoomButton)?.isHidden = false

        // Disallow tabbing if the titlebar is hidden, since that will (should) also hide the tab bar.
        tabbingMode = .disallowed

        // It seems AppKit moves `NSScrollPocket` to the title bar on macOS 27.
        // We should hide it to prevent it covering terminal contents.
        //
        // Linked issue: https://github.com/ghostty-org/ghostty/issues/13390
        // Reference: https://developer.apple.com/forums/thread/798392?answerId=856013022#856013022
        // Note: hiding `NSTitlebarBackgroundView` won't work here, because it later uses the pocket view from the `SurfaceScrollView`.
        if #available(macOS 27, *),
           let themeFrame = contentView?.superview,
           let scrollPocket = themeFrame.firstDescendant(withClassName: "NSScrollPocket") {
            scrollPocket.isHidden = true
        }
    }

    // MARK: NSWindow

    override var title: String {
        didSet {
            // Updating the title text as above automatically reveals the
            // native title view in macOS 15.0 and above. Since we're using
            // a custom view instead, we need to re-hide it.
            reapplyHiddenStyle()
        }
    }

    // We override this so that with the hidden titlebar style the titlebar
    // area is not draggable.
    override var contentLayoutRect: CGRect {
        var rect = super.contentLayoutRect
        rect.origin.y = 0
        rect.size.height = self.frame.height
        return rect
    }

    // MARK: Notifications

    @objc private func fullscreenDidExit(_ notification: Notification) {
        // Make sure they're talking about our window
        guard let fullscreen = notification.object as? FullscreenBase else { return }
        guard fullscreen.window == self else { return }

        // On exit we need to reapply the style because macOS breaks it usually.
        // This is safe to call repeatedly so if its not broken its still safe.
        reapplyHiddenStyle()
    }
}
