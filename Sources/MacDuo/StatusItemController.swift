import AppKit
import Combine
import SwiftUI

/// The menu bar item and the settings popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let preferences: Preferences
    private let controller: LidController
    private var showsAngleSubscription: AnyCancellable?
    private var angleSubscription: AnyCancellable?
    private var barWindowMoved: NSObjectProtocol?

    init(controller: LidController, preferences: Preferences) {
        self.controller = controller
        self.preferences = preferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "laptopcomputer",
                accessibilityDescription: "Mac Duo"
            )
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let hostingController = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                controller: controller,
                onQuit: { NSApp.terminate(nil) }
            )
        )
        // Without this the popover keeps its default height and clips the content.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        showsAngleSubscription = preferences.$showsAngleInMenuBar
            .removeDuplicates()
            .sink { [weak self] showsAngle in
                self?.configureAngleTitle(isVisible: showsAngle)
            }
        watchBarWindow()
    }

    deinit {
        if let barWindowMoved {
            NotificationCenter.default.removeObserver(barWindowMoved)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate()
            anchor(to: button)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Showing the angle changes the button width, and the status item window
    /// slides along the menu bar about a tenth of a second later. AppKit places
    /// the popover on the width change, before the slide, so it lands a whole
    /// button width away until the window has settled.
    private func watchBarWindow() {
        barWindowMoved = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown,
                      let button = self.statusItem.button,
                      let moved = notification.object as? NSWindow,
                      moved === button.window else { return }
                // Re-showing an animating popover makes it flicker shut.
                let animates = self.popover.animates
                self.popover.animates = false
                self.anchor(to: button)
                self.popover.animates = animates
            }
        }
    }

    /// An empty rectangle means the button's own bounds.
    private func anchor(to button: NSStatusBarButton) {
        popover.show(relativeTo: .zero, of: button, preferredEdge: .minY)
    }

    func popoverWillShow(_ notification: Notification) {
        controller.setAngleUpdatesRequested(true, for: .settings)
    }

    func popoverDidClose(_ notification: Notification) {
        controller.setAngleUpdatesRequested(false, for: .settings)
    }

    private func configureAngleTitle(isVisible: Bool) {
        angleSubscription = nil
        controller.setAngleUpdatesRequested(isVisible, for: .menuBar)
        guard let button = statusItem.button else { return }
        guard isVisible else {
            button.title = ""
            return
        }

        angleSubscription = controller.$currentAngle
            .removeDuplicates { round($0) == round($1) }
            .sink { [weak self] angle in
                self?.statusItem.button?.title = String(format: " %.0f°", angle)
            }
    }
}
