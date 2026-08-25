import AppKit
import Combine
import DisplayVolumeKit
import SwiftUI

@main
struct DisplayVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The status item, popover, and windows are all managed by the
        // delegate (SwiftUI's MenuBarExtra cannot distinguish right-clicks).
        Settings { EmptyView() }
    }
}

/// Owns the whole UI shell: the status item (left-click → minimal popover,
/// right-click → context menu), the settings window, the volume HUD, the
/// one-time onboarding window, and clean teardown on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var appState: AppState?
    private var statusItem: NSStatusItem?
    private var volumePanel: StatusPanelController?
    private var settingsPanel: StatusPanelController?
    private var onboardingWindow: NSWindow?
    private var volumeHUD: VolumeHUDController?
    private var cancellables = Set<AnyCancellable>()
    private var currentSymbolName = ""

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let state = AppState()
        appState = state

        setUpStatusItem(with: state)

        volumePanel = StatusPanelController(
            content: MenuBarView().environmentObject(state))
        settingsPanel = StatusPanelController(
            content: SettingsWindowView().environmentObject(state))

        subscribeToHUDEvents(state)

        if !Preferences().onboardingCompleted {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop IO, destroy the tap and aggregate, remove listeners and the
        // media-key tap. After this, macOS reverts to normal direct playback.
        appState?.shutdown()
    }

    // MARK: - Status item

    private func setUpStatusItem(with state: AppState) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        updateIcon(name: state.menuBarIconName)

        // Keep the glyph in sync with device/mute/status changes.
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak state] in
                DispatchQueue.main.async {
                    guard let self, let state else { return }
                    self.updateIcon(name: state.menuBarIconName)
                }
            }
            .store(in: &cancellables)
    }

    private func updateIcon(name: String) {
        guard name != currentSymbolName else { return }
        currentSymbolName = name
        statusItem?.button?.image = NSImage(
            systemSymbolName: name, accessibilityDescription: "DisplayVolume")
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if volumePanel?.isShown == true {
            volumePanel?.close()
        } else {
            settingsPanel?.close()
            appState?.refreshDevices()
            volumePanel?.show(under: button)
        }
    }

    // MARK: - Right-click menu

    private func showContextMenu() {
        guard let item = statusItem, let state = appState else { return }
        volumePanel?.close()
        settingsPanel?.close()

        let menu = NSMenu()

        if state.controlMode == .software {
            let title = state.isProcessing ? "Stop Processing" : "Start Processing"
            let processingItem = NSMenuItem(title: title,
                                            action: #selector(toggleProcessing),
                                            keyEquivalent: "")
            processingItem.target = self
            processingItem.isEnabled = state.selectedDeviceUID != nil
            menu.addItem(processingItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit DisplayVolume",
                                  action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Attach the menu just for this click, then detach so the next
        // left-click opens the popover again.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleProcessing() {
        guard let state = appState else { return }
        if state.isProcessing {
            state.stopProcessing()
        } else {
            state.startProcessing()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings panel

    /// Opens the Settings panel exactly like the volume popover: flat,
    /// rounded, anchored under the status item.
    @objc func openSettings() {
        guard let button = statusItem?.button else { return }
        volumePanel?.close()
        settingsPanel?.show(under: button)
    }

    // MARK: - Volume HUD

    /// Shows the volume bezel whenever the media keys adjust the volume in
    /// either control mode (the app consumes the keys, so the system bezel
    /// never appears alongside).
    private func subscribeToHUDEvents(_ state: AppState) {
        state.hudEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.volumeHUD == nil {
                        self.volumeHUD = VolumeHUDController()
                    }
                    self.volumeHUD?.show(volume: event.volume, muted: event.muted)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Onboarding

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView { [weak self] in
                // Persist directly so completion sticks regardless of state.
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
