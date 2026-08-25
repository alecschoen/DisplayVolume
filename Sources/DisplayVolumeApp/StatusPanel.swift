import AppKit
import SwiftUI

/// A flat, arrow-less replacement for NSPopover: a borderless panel with a
/// popover-material rounded background, anchored under the status item.
/// Used for both the main volume popover and the Settings panel so they
/// look and behave identically.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {

    /// Borderless panels refuse key status by default; sliders, pickers,
    /// and toggles need it.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let panel: KeyablePanel
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var topLeftAnchor: NSPoint = .zero

    /// Called after the panel closes for any reason.
    var onClose: (() -> Void)?

    var isShown: Bool { panel.isVisible }

    init<Content: View>(content: Content) {
        let hosting = NSHostingController(rootView: PanelChrome { content })
        hosting.sizingOptions = [.preferredContentSize]

        panel = KeyablePanel(contentRect: .zero,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        super.init()
        panel.delegate = self
    }

    // MARK: - Show / hide

    func show(under button: NSStatusBarButton) {
        guard let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        let size = panel.contentViewController?.view.fittingSize ?? panel.frame.size

        let buttonRect = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - size.width / 2
        let visible = screen.visibleFrame
        x = min(max(x, visible.minX + 8),
                screen.frame.maxX - size.width - 8)
        let topY = buttonRect.minY - 6

        topLeftAnchor = NSPoint(x: x, y: topY)
        panel.setFrame(NSRect(x: x, y: topY - size.height,
                              width: size.width, height: size.height),
                       display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
    }

    func close() {
        guard panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
        onClose?()
    }

    // MARK: - Dismissal (transient behavior)

    private func installMonitors() {
        removeMonitors()
        // Any click outside the app closes the panel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        // Escape closes it too.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated { self?.close() }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    func windowDidResize(_ notification: Notification) {
        // Content growth (e.g. expanding Diagnostics) must extend downward,
        // keeping the panel glued under the menu bar.
        guard panel.isVisible else { return }
        panel.setFrameTopLeftPoint(topLeftAnchor)
        panel.invalidateShadow()
    }
}

/// The shared rounded popover-material chrome.
private struct PanelChrome<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
