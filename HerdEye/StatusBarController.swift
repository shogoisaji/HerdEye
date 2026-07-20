import AppKit
import SwiftUI

/// Manages the menu bar NSStatusItem and draws and updates the 3x3 dot icon.
/// Shows an NSPopover on click with the agent list.
/// The popover's settings button opens the settings window.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let store: PastureStore
    private let settings: BarDotSettingsStore
    private let popover: NSPopover
    private var settingsWindow: NSWindow?

    init() {
        let transport = HerdrSocketTransport()
        self.store = PastureStore(
            client: HerdrClient(transport: transport)
        )
        self.settings = BarDotSettingsStore()

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popover.behavior = .transient
        self.popover.animates = true
    }

    func start() {
        configureStatusItem()
        store.start()
        observeStore()
        observeSettings()
    }

    // MARK: - Status Item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = drawDotGrid(agents: [], connectionState: .connecting)
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.imagePosition = .imageOnly
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            let view = BarPopoverView(
                store: store,
                settings: settings,
                onReconnect: { [weak self] in
                    self?.store.reconnect()
                },
                onOpenSettings: { [weak self] in
                    self?.openSettings()
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
            popover.contentViewController = NSHostingController(rootView: view)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    // MARK: - Settings Window

    private func openSettings() {
        popover.performClose(nil)
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = BarSettingsView(settings: settings)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "HerdEye Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    // MARK: - Store Observation

    /// Observe @Observable changes in PastureStore and redraw the icon.
    private func observeStore() {
        withObservationTracking {
            _ = store.sortedAgents
            _ = store.connectionState
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observeStore()
            }
        }
    }

    /// Observe changes in BarDotSettingsStore and redraw the icon.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.idle
            _ = settings.working
            _ = settings.blocked
            _ = settings.done
            _ = settings.unknown
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observeSettings()
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let agents = BarAgentSelection.select(store.sortedAgents)
        button.image = drawDotGrid(agents: agents, connectionState: store.connectionState)
    }

    // MARK: - Icon Drawing

    /// Draw the dot grid.
    /// Use a 2x2 grid for up to four agents and a 3x3 grid for five or more.
    /// Apply each agent's DotAppearance settings for shape, outline, and fill.
    /// Empty slots use a light-gray circular outline.
    private func drawDotGrid(agents: [PastureAgent], connectionState: ConnectionState) -> NSImage {
        let canvas: CGFloat = 22
        let isLive = connectionState == .live
        let gridSize = agents.count > 4 ? 3 : 2
        let slotCount = gridSize * gridSize
        let dotDiameter: CGFloat = gridSize == 3 ? 5 : 7
        let gap: CGFloat = gridSize == 3 ? 2 : 3
        let totalGrid = CGFloat(gridSize) * dotDiameter + CGFloat(gridSize - 1) * gap
        let offset = (canvas - totalGrid) / 2

        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()

        for i in 0..<slotCount {
            let row = i / gridSize
            let col = i % gridSize
            // NSImage coordinates use a lower-left origin: row 0 is the top row.
            let x = offset + CGFloat(col) * (dotDiameter + gap)
            let y = canvas - offset - CGFloat(row + 1) * dotDiameter - CGFloat(row) * gap
            let rect = NSRect(x: x, y: y, width: dotDiameter, height: dotDiameter)

            if isLive && i < agents.count {
                drawDot(in: rect, state: agents[i].state)
            } else {
                drawEmptyDot(in: rect)
            }
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func drawDot(in rect: NSRect, state: AgentState) {
        let appearance = settings.appearance(for: state)
        let path = shapePath(appearance.shape, in: rect)

        if appearance.fill {
            appearance.fillColor.nsColor.setFill()
            path.fill()
        }
        if appearance.outline {
            appearance.outlineColor.nsColor.setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }
    }

    /// Empty slot with no assigned agent: light-gray outline.
    private func drawEmptyDot(in rect: NSRect) {
        let path = NSBezierPath(ovalIn: rect)
        NSColor(white: 0.5, alpha: 0.8).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func shapePath(_ shape: DotShape, in rect: NSRect) -> NSBezierPath {
        switch shape {
        case .circle:
            return NSBezierPath(ovalIn: rect)
        case .square:
            return NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
        }
    }
}
