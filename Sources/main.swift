// Path Opener: a menu bar launcher. Search apps, files, folders and file contents
// through the Spotlight index, or paste any path and it opens.
import AppKit
import SwiftUI
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    let store = Store()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var hotKeyRef: EventHotKeyRef?
    var handlerInstalled = false
    var panel: LauncherPanel!
    static let showNote = Notification.Name("com.thothica.pathopener.show")

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self

        // One copy at a time: if another is running, ask it to show itself and quit.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me }) {
            DistributedNotificationCenter.default().postNotificationName(AppDelegate.showNote, object: nil, userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: AppDelegate.showNote, object: nil, queue: .main) { _ in
            AppDelegate.shared.showPanel()
        }

        panel = LauncherPanel(store: store)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            let img = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Path Opener")
            img?.isTemplate = true
            b.image = img
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ContentView(store: store))
        store.close = { [weak self] in
            self?.popover.performClose(nil)
            self?.panel.dismiss()
        }
        store.showSettings = { [weak self] in self?.showSettingsMenu() }
        registerHotKey()

        // Opened by hand (Finder, Launchpad, Spotlight): show the window so something happens.
        // Skip it right after startup, when Launch at Login opens us.
        if ProcessInfo.processInfo.systemUptime > 180 {
            DispatchQueue.main.async { self.showPanel() }
        }
    }

    /// Double-clicking the app while it runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(); return false
    }

    /// Global shortcut and app launches: the floating Spotlight-style window.
    func showPanel(toggle: Bool = false) {
        if popover.isShown { popover.performClose(nil) }
        if panel.isVisible {
            if toggle { panel.dismiss() } else { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            return
        }
        store.prepareForShow()
        panel.present()
        DispatchQueue.main.async { self.store.focusTick += 1 }
    }

    /// The settings menu, shown from the gear in the window footer.
    func showSettingsMenu() {
        guard let w = NSApp.keyWindow, let v = w.contentView else { return }
        let m = buildMenu()
        m.popUp(positioning: nil, at: NSPoint(x: v.bounds.maxX - 30, y: 30), in: v)
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true { showMenu() } else { toggle() }
    }

    func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = statusItem.button else { return }
        store.prepareForShow()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        DispatchQueue.main.async { self.store.focusTick += 1 }
    }

    func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Open Path Opener", #selector(menuOpen)))
        m.addItem(.separator())

        let keys = NSMenu()
        for k in HotKey.allCases {
            let i = item(k.label + (k == .cmdSpace ? "  (turn off Spotlight's shortcut first)" : ""), #selector(pickHotKey(_:)))
            i.tag = k.rawValue
            i.state = k == HotKey.current ? .on : .off
            keys.addItem(i)
        }
        let keysItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        keysItem.submenu = keys
        m.addItem(keysItem)

        let paste = item("Open Instantly on Paste", #selector(togglePaste))
        paste.state = store.openOnPaste ? .on : .off; m.addItem(paste)
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off; m.addItem(login)
        m.addItem(item("Clear Recents", #selector(clearRecents)))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit Path Opener", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return m
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; return i
    }

    @objc func menuOpen() { DispatchQueue.main.async { self.showPanel() } }
    @objc func togglePaste() { store.openOnPaste.toggle() }
    @objc func clearRecents() { store.clearRecents() }
    @objc func pickHotKey(_ sender: NSMenuItem) {
        HotKey.current = HotKey(rawValue: sender.tag) ?? .optCmdO
        registerHotKey()
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't change Launch at Login"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    func registerHotKey() {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { AppDelegate.shared.showPanel(toggle: true) }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        let k = HotKey.current
        let id = EventHotKeyID(signature: OSType(0x5054_4F50), id: 1)
        let status = RegisterEventHotKey(k.keyCode, k.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            let a = NSAlert()
            a.messageText = "\(k.label) is taken"
            a.informativeText = "Another app or macOS already uses \(k.label). Pick a different shortcut from the menu bar icon (right-click → Shortcut)."
            a.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
