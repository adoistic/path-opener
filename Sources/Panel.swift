import AppKit
import SwiftUI

/// A Spotlight-style floating window, centred near the top of the screen.
/// Used for the global shortcut and when the app is opened, so Path Opener
/// works even when macOS hides the menu bar icon (full menu bar, notch).
final class LauncherPanel: NSPanel, NSWindowDelegate {
    var onClose: () -> Void = {}

    init(store: Store) {
        let host = NSHostingView(rootView: ContentView(store: store))
        let size = host.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        delegate = self

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.cgColor
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        contentView = blur
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func present() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let f = frame
            setFrameOrigin(NSPoint(x: vf.midX - f.width / 2, y: vf.maxY - f.height - vf.height * 0.14))
        }
        NSApp.activate(ignoringOtherApps: true)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        onClose()
    }

    // Click anywhere else → close, like Spotlight.
    func windowDidResignKey(_ notification: Notification) { dismiss() }

    override func cancelOperation(_ sender: Any?) { dismiss() }
}
