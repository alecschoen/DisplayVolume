import AppKit
import DisplayVolumeKit
import SwiftUI

@main
struct DisplayVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .onAppear { appDelegate.appState = appState }
        } label: {
            // The label renders at launch, so this wires the delegate even
            // if the popover is never opened (shutdown must always run).
            Image(systemName: menuBarSymbol)
                .accessibilityLabel("DisplayVolume")
                .onAppear { appDelegate.appState = appState }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if appState.isMuted { return "speaker.slash" }
        switch appState.status {
        case .active: return "speaker.wave.2.fill"
        case .stopped: return "speaker.wave.2"
        default: return "speaker.badge.exclamationmark"
        }
    }
}

/// Handles lifecycle concerns SwiftUI scenes cannot: accessory activation
/// policy (menu-bar only, no Dock icon — also when running the bare SPM
/// binary), the one-time onboarding window, and clean teardown on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Show onboarding once. The AppState may not be wired yet (the
        // MenuBarExtra content view appears lazily), so read the preference
        // directly.
        if !Preferences().onboardingCompleted {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop IO, destroy the tap and aggregate, remove listeners and the
        // media-key tap. After this, macOS reverts to normal direct playback.
        MainActor.assumeIsolated {
            appState?.shutdown()
        }
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView { [weak self] in
                // Persist directly so completion sticks even if the
                // popover (and thus the AppState wiring) was never opened.
                Preferences().onboardingCompleted = true
                MainActor.assumeIsolated {
                    self?.appState?.completeOnboarding()
                }
                self?.onboardingWindow?.close()
            }
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to DisplayVolume"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}
