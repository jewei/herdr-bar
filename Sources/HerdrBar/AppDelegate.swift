import AppKit
import HerdrBarCore
import SwiftUI
import UserNotifications

@main
enum HerdrBarApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private let store = AgentStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var renderWindow: NSWindow?
    private var statusPresentation: StatusPresentation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--check") {
            Task {
                do {
                    let snapshot = try await store.client.snapshot()
                    var tracker = AttentionTracker()
                    let rows = tracker.update(snapshot)
                    print("Connected to Herdr \(snapshot.version) at \(store.socketPath)")
                    print(AgentSummary(rows: rows).description)
                    for row in AgentOrder.grouped.sorted(rows) {
                        print("\(row.title) | \(row.kind) | \(row.status.label) | \(row.id)")
                    }
                    exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        if let index = arguments.firstIndex(of: "--render-preview"), arguments.indices.contains(index + 1) {
            renderPreview(to: arguments[index + 1], live: arguments.contains("--live"),
                          state: argument("--state", in: arguments) ?? "agents")
            return
        }

        // Reopening the app reveals the existing instance instead of creating a second menu item.
        if let bundleID = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            running.activate(options: [])
            NSApp.terminate(nil)
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Herdr Bar"
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: makePalette())
        store.onChange = { [weak self] in self?.updateStatusItem() }
        store.onOpen = { [weak self] in self?.popover.performClose(nil) }
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
        updateStatusItem()
        store.start()
        if arguments.contains("--show") { showPopover() }
    }

    func applicationWillTerminate(_ notification: Notification) { store.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    private func makePalette() -> PaletteView {
        PaletteView(store: store, close: { [weak self] in self?.popover.performClose(nil) },
                    editConnection: { [weak self] in self?.editConnection() })
    }

    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Show agents", action: #selector(showPopover), keyEquivalent: "")
                .target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Herdr Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    @objc private func showPopover() {
        guard let button = statusItem?.button else { return }
        store.selectInitialRow()
        updatePopoverSize()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await store.refresh() }
    }

    private func updatePopoverSize() {
        if let screen = statusItem?.button?.window?.screen ?? NSScreen.main {
            let height = min(Theme.maximumPaletteHeight, screen.visibleFrame.height - 32)
            if store.maximumPaletteHeight != height { store.maximumPaletteHeight = height }
        }
        let size = NSSize(width: Theme.width, height: store.paletteHeight)
        if popover.contentSize != size { popover.contentSize = size }
    }

    private func updateStatusItem() {
        if popover.isShown { updatePopoverSize() }
        guard let button = statusItem?.button else { return }
        let summary = store.summary
        let presentation = StatusPresentation(summary: summary, connected: store.connected, loading: store.loading)
        guard presentation != statusPresentation else { return }
        statusPresentation = presentation
        button.image = nil
        button.attributedTitle = presentation.attributedTitle
        button.toolTip = "Herdr Bar · \(presentation.text)"
        button.setAccessibilityLabel("Herdr Bar. \(presentation.text). Show agents.")
    }

    private func editConnection() {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Herdr connection"
        alert.informativeText = "Set the socket path for a Herdr session. Leave it empty to use the default."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: "socketPath") ?? ""
        field.placeholderString = SocketLocation.resolve()
        field.setAccessibilityLabel("Herdr socket path")
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.setSocketPath(field.stringValue)
        }
        showPopover()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let target = NotificationTarget(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await store.refresh()
            if let target, let row = store.row(for: target) { store.open(row) }
            else { showPopover() }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func argument(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func renderPreview(to path: String, live: Bool, state: String) {
        store.isPreview = true
        Task {
            do {
                if live {
                    store.apply(try await store.client.snapshot())
                } else if ["agents", "attention", "error", "long-error", "many", "long-names", "opening"].contains(state) {
                    store.apply(try PreviewData.snapshot(attention: state == "attention" || state == "long-names",
                                                         extended: state == "many" || state == "long-names"))
                    if state == "error" || state == "long-error" {
                        store.actionError = "Cannot confirm the agent opened. Unexpected Herdr reply. Open it in your terminal."
                        if state == "long-error" {
                            store.actionError = String(repeating: "The terminal could not open this agent. ", count: 20)
                                + "Open Herdr in your terminal, then select the agent again."
                        }
                    }
                    if state == "opening" { store.openingID = store.selectedID }
                } else if state == "empty" {
                    store.apply(try PreviewData.empty())
                } else if ["offline", "cached-offline", "compact"].contains(state) {
                    // Let the normal error path build an offline view using a missing socket.
                    let offline = AgentStore(client: HerdrClient(socketPath: "/tmp/herdr-bar-preview-missing.sock"))
                    if state != "offline" {
                        offline.isPreview = true
                        offline.apply(try PreviewData.snapshot(attention: true, extended: state == "compact"))
                        offline.isPreview = false
                    }
                    await offline.refresh()
                    if state == "compact" {
                        offline.maximumPaletteHeight = 540
                        offline.actionError = String(repeating: "The terminal could not open this agent. ", count: 20)
                    }
                    render(view: PaletteView(store: offline, close: {}, editConnection: {}),
                           height: offline.paletteHeight, path: path)
                    return
                }
                render(view: makePalette(), height: store.paletteHeight, path: path)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
        }
    }

    private func render(view: PaletteView, height: CGFloat, path: String) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: Theme.width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: Theme.width, height: height)
        renderWindow = window
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(EXIT_FAILURE) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(EXIT_FAILURE) }
            do {
                try data.write(to: URL(fileURLWithPath: path))
                print("Saved palette preview to \(path)")
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
        }
    }
}
