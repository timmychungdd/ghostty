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

        // Fork: tabbing stays enabled. Upstream sets `tabbingMode = .disallowed`
        // here; the fork drops that so cmd+T creates a real native tab in this
        // frame (TerminalWindow.awakeFromNib sets .preferred/.automatic, which
        // this method no longer overrides). The native tab strip is force-hidden
        // instead — the agent sidebar is the only tab chrome.
        hideTabBarStrip()

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

    // MARK: Tab Strip Suppression (fork)

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)

        // AppKit reveals the native tab strip (an NSTabBar titlebar accessory)
        // when a second tab joins the group. Hide it synchronously in this
        // same runloop pass: an async-only hide lets AppKit commit at least
        // one frame with the strip drawn (the flash Tim saw). isHidden on
        // the accessory is not toggleTabBar — it touches no tab group state,
        // so it is safe mid-AppKit-tab-machinery. The staggered async passes
        // stay as backstop for AppKit's later re-flips.
        if isTabBar(childViewController) {
            childViewController.isHidden = true
            hideTabBarStrip()
        }
    }

    override func becomeKey() {
        super.becomeKey()
        hideTabBarStrip()
    }

    /// Force the native tab strip off. Two layers:
    ///
    /// 1. Hide the tab bar's titlebar ACCESSORY. `isHidden` removes it from
    ///    titlebar layout entirely, collapsing the space it reserves — hiding
    ///    only the NSTabBar view leaves the reserved strip inflating the
    ///    content's top safe-area inset.
    /// 2. `toggleTabBar` flips the group's visibility state properly. It
    ///    toggles, so guard on `isTabBarVisible` first.
    ///
    /// AppKit flips the strip visible on its own schedule after a tab joins
    /// the group, so every hook re-checks on staggered delays rather than
    /// once — the callers also run mid-AppKit-tab-machinery (accessory add,
    /// title change), where mutating synchronously can re-enter.
    func hideTabBarStrip() {
        for delay in [0.0, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                for accessory in self.titlebarAccessoryViewControllers where self.isTabBar(accessory) {
                    accessory.isHidden = true
                }
                if let group = self.tabGroup, group.isTabBarVisible {
                    self.toggleTabBar(nil)
                }
            }
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
