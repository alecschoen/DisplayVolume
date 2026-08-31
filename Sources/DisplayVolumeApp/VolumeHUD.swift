import AppKit
import SwiftUI

/// Native-looking volume bezel shown when the media keys change the
/// software volume (fixed-volume displays). Borderless, non-activating,
/// click-through panel that fades out after a moment — visually modeled on
/// the system volume HUD, which cannot appear for these devices.
@MainActor
final class VolumeHUDController {

    final class Model: ObservableObject {
        @Published var volume: Float = 0.5
        @Published var muted = false
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    private static let size = NSSize(width: 260, height: 52)

    func show(volume: Float, muted: Bool) {
        model.volume = volume
        model.muted = muted

        let panel = ensurePanel()
        position(panel)
        hideWork?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        newPanel.level = .statusBar
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.ignoresMouseEvents = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // maskImage, not a layer mask: the window server composites the
        // blur and ignores layer masks, which left square corners ghosting
        // around the rounded pill.
        effect.maskImage = .roundedRectMask(radius: 16)
        effect.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: VolumeHUDView(model: model))
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        newPanel.contentView = effect
        panel = newPanel
        return newPanel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + 110)
        panel.setFrameOrigin(origin)
    }
}

private struct VolumeHUDView: View {
    @ObservedObject var model: VolumeHUDController.Model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 26)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.primary)
                        .frame(width: max(0, geo.size.width * CGFloat(model.muted ? 0 : model.volume)))
                }
            }
            .frame(height: 7)

            Text(model.muted ? "0%" : "\(Int((model.volume * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        if model.muted { return "speaker.slash.fill" }
        switch model.volume {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
