import AppKit
import Combine
import CoreAudio
import Foundation
import ServiceManagement

/// User-visible application status.
public enum AppStatus: Equatable {
    case stopped
    case active
    case nativeVolume
    case permissionRequired
    case outputDisconnected
    case audioError(String)

    public var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .active: return "Active"
        case .nativeVolume: return "Active (native volume)"
        case .permissionRequired: return "Permission required"
        case .outputDisconnected: return "Output disconnected"
        case .audioError: return "Audio error"
        }
    }
}

/// How the current output device's volume is controlled.
public enum OutputControlMode: Equatable {
    /// Fixed-volume device: tap → software gain → render (the pipeline).
    case software
    /// Device with settable hardware volume: the slider drives the device's
    /// own volume (the same control macOS uses), no tap needed.
    case hardware
}

/// Central, main-actor state machine. Owns the pipeline, device manager,
/// preferences, permissions, and media-key controller, and exposes
/// observable state to the SwiftUI menu-bar UI.
@MainActor
public final class AppState: ObservableObject {

    // MARK: Published UI state

    @Published public private(set) var status: AppStatus = .stopped
    @Published public private(set) var devices: [AudioOutputDevice] = []
    @Published public var selectedDeviceUID: String?
    @Published public private(set) var volume: Float
    @Published public private(set) var isMuted: Bool
    @Published public private(set) var startAtLoginEnabled = false
    @Published public private(set) var keyboardControlEnabled: Bool
    @Published public private(set) var matchSystemOutput: Bool
    @Published public private(set) var controlMode: OutputControlMode = .software
    @Published public private(set) var audioPermissionState: PermissionState = .unknown
    @Published public private(set) var accessibilityPermissionState: PermissionState = .unknown
    @Published public private(set) var stats = PipelineStats()
    @Published public private(set) var lastErrorUserMessage: String?
    @Published public private(set) var lastErrorTechnicalDetails: String = "none"
    @Published public private(set) var showOnboarding: Bool

    public var volumePercent: Int { Int((volume * 100).rounded()) }
    public var isProcessing: Bool { pipeline.isRunning }

    // MARK: Components

    private let preferences: Preferences
    private let deviceManager = AudioDeviceManager()
    private let gainProcessor = GainProcessor()
    private let pipeline: AudioPipeline
    private let mediaKeys = MediaKeyController()
    private let audioPermission = AudioCapturePermission()

    // MARK: Internal state

    /// True while the user wants processing running (survives disconnects,
    /// sleep, and transient errors; cleared by an explicit Stop).
    private var wantsProcessing = false
    private var consecutiveStartFailures = 0
    private var nextRetryAllowedAt = Date.distantPast
    private var pendingRestart: DispatchWorkItem?
    private var pollTimer: Timer?
    private var lastInputCallbackCount: UInt64 = 0
    private var stalledTicks = 0

    /// Device driven directly in hardware mode (transient object ID).
    private var hardwareDeviceID = AudioObjectID(kAudioObjectUnknown)
    /// Volume to restore when unmuting a device that has no mute control.
    private var hardwareMuteFallbackVolume: Float = Preferences.defaultVolume

    // MARK: - Init

    public init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        self.pipeline = AudioPipeline(gain: gainProcessor)

        volume = preferences.volume
        isMuted = preferences.muted
        keyboardControlEnabled = preferences.keyboardControlEnabled
        matchSystemOutput = preferences.matchSystemOutput
        selectedDeviceUID = preferences.selectedDeviceUID
        showOnboarding = !preferences.onboardingCompleted

        // When matching the system output, the macOS Sound selection is the
        // source of truth at launch.
        if matchSystemOutput,
           let systemUID = deviceManager.defaultOutputDeviceUID(),
           !systemUID.hasPrefix(AudioDeviceManager.aggregateUIDPrefix) {
            selectedDeviceUID = systemUID
            preferences.selectedDeviceUID = systemUID
        }

        gainProcessor.setTarget(volume: volume, muted: isMuted)

        // Defense in depth against interrupted previous launches.
        AggregateDeviceController.destroyStaleAggregates()

        refreshDevices()
        wireCallbacks()
        deviceManager.startWatchingSystem()
        observeWorkspaceNotifications()
        startAtLoginEnabled = SMAppService.mainApp.status == .enabled
        accessibilityPermissionState = AccessibilityPermission.state
        startPollTimer()

        // Resume intent only if processing was active at last quit
        // (permission was necessarily granted then; no surprise first-run
        // prompt). The delayed re-evaluation picks hardware or software
        // mode for the current device and starts the pipeline only in
        // software mode.
        wantsProcessing = preferences.processingWasActive && selectedDeviceUID != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reevaluateControlMode()
        }

        if keyboardControlEnabled, AccessibilityPermission.isGranted {
            try? mediaKeys.start()
        }
    }

    private func wireCallbacks() {
        deviceManager.onDevicesChanged = { [weak self] in
            self?.handleDevicesChanged()
        }
        deviceManager.onDefaultOutputChanged = { [weak self] in
            self?.handleDefaultOutputChanged()
        }
        deviceManager.onWatchedDeviceEvent = { [weak self] event in
            self?.handleWatchedDeviceEvent(event)
        }
        mediaKeys.onKey = { [weak self] key, fine, _ in
            guard let self else { return }
            let step: Float = fine ? 0.01 : 0.05
            switch key {
            case .volumeUp: self.adjustVolume(by: step)
            case .volumeDown: self.adjustVolume(by: -step)
            case .mute: self.toggleMute()
            }
        }
    }

    // MARK: - Processing control

    /// Explicit user start. This is the moment the System Audio Recording
    /// prompt may appear (first tap creation) — never at launch.
    public func startProcessing() {
        wantsProcessing = true
        preferences.processingWasActive = true
        consecutiveStartFailures = 0
        nextRetryAllowedAt = .distantPast
        attemptStart()
    }

    /// Explicit user stop: tears down tap + aggregate, restoring normal
    /// direct audio output.
    public func stopProcessing() {
        wantsProcessing = false
        preferences.processingWasActive = false
        pendingRestart?.cancel()
        stopPipeline(newStatus: .stopped)
    }

    private func attemptStart() {
        guard controlMode == .software else { return }
        guard wantsProcessing, !pipeline.isRunning else { return }
        guard Date() >= nextRetryAllowedAt else { return }
        guard let uid = selectedDeviceUID else {
            status = .stopped
            return
        }

        do {
            try pipeline.start(deviceUID: uid)
            audioPermission.noteTapCreationSucceeded()
            deviceManager.watchSelectedDevice(pipeline.currentDeviceID)
            consecutiveStartFailures = 0
            stalledTicks = 0
            lastInputCallbackCount = 0
            status = .active
            clearError()
            AppLog.app.info("Processing started")
        } catch let error as DisplayVolumeError {
            handleStartFailure(error)
        } catch {
            recordError(userMessage: error.localizedDescription,
                        technical: String(describing: error))
            status = .audioError(error.localizedDescription)
        }
        refreshPermissionStates()
        refreshStats()
    }

    private func handleStartFailure(_ error: DisplayVolumeError) {
        recordError(userMessage: error.errorDescription ?? "Audio error",
                    technical: error.technicalDetails)
        consecutiveStartFailures += 1
        // Bounded exponential backoff: 1, 2, 4, 8, … capped at 30 s. Retries
        // are only triggered by device/wake events, so there is no tight loop.
        let backoff = min(pow(2.0, Double(consecutiveStartFailures - 1)), 30)
        nextRetryAllowedAt = Date().addingTimeInterval(backoff)

        switch error {
        case .deviceUnavailable:
            status = .outputDisconnected
        case .tapCreationFailed:
            audioPermission.noteTapCreationFailed()
            status = audioPermission.state == .denied ? .permissionRequired
                                                      : .audioError(error.errorDescription ?? "")
        case .systemAudioPermissionMissing:
            status = .permissionRequired
        default:
            status = .audioError(error.errorDescription ?? "Audio error")
        }
        AppLog.app.error("Start failed: \(error.technicalDetails, privacy: .public)")
    }

    private func stopPipeline(newStatus: AppStatus) {
        deviceManager.stopWatchingSelectedDevice()
        pipeline.stop()
        status = newStatus
        refreshStats()
    }

    /// Full teardown for app termination.
    public func shutdown() {
        pendingRestart?.cancel()
        pollTimer?.invalidate()
        pollTimer = nil
        mediaKeys.stop()
        deviceManager.stopWatchingSelectedDevice()
        deviceManager.stopWatchingSystem()
        pipeline.stop()
        AppLog.app.info("Shutdown complete")
    }

    // MARK: - Device selection

    public func refreshDevices() {
        devices = deviceManager.outputDevices()
    }

    public func selectDevice(uid: String) {
        guard uid != selectedDeviceUID else { return }
        selectedDeviceUID = uid
        preferences.selectedDeviceUID = uid
        if pipeline.isRunning {
            stopPipeline(newStatus: .stopped)
        }
        // Keep macOS Sound output in step: audio only reaches the tap when
        // the system actually plays to the selected device. (The resulting
        // default-changed notification is a no-op — UIDs already match.)
        if matchSystemOutput {
            deviceManager.setDefaultOutputDevice(uid: uid)
        }
        nextRetryAllowedAt = .distantPast
        reevaluateControlMode()
    }

    /// Enables/disables two-way sync with the macOS default output. When
    /// turning it on, the current system output wins.
    public func setMatchSystemOutput(_ enabled: Bool) {
        matchSystemOutput = enabled
        preferences.matchSystemOutput = enabled
        if enabled {
            adoptSystemDefaultOutput()
        }
    }

    private func handleDefaultOutputChanged() {
        guard matchSystemOutput else { return }
        adoptSystemDefaultOutput()
    }

    /// Follows the system default output: retargets the selection (and the
    /// control mode / pipeline) to whatever macOS is now playing to.
    private func adoptSystemDefaultOutput() {
        guard let systemUID = deviceManager.defaultOutputDeviceUID(),
              !systemUID.hasPrefix(AudioDeviceManager.aggregateUIDPrefix),
              systemUID != selectedDeviceUID else { return }
        AppLog.devices.info("Following system output change")
        selectedDeviceUID = systemUID
        preferences.selectedDeviceUID = systemUID
        if pipeline.isRunning {
            stopPipeline(newStatus: .stopped)
        }
        nextRetryAllowedAt = .distantPast
        reevaluateControlMode()
    }

    // MARK: - Control mode (software tap vs. native hardware volume)

    /// Decides, for the currently selected device, whether volume is applied
    /// in software (fixed-volume displays → tap pipeline) or by driving the
    /// device's own hardware volume (Mac speakers, headphones, DACs).
    private func reevaluateControlMode() {
        guard let uid = selectedDeviceUID else {
            status = .stopped
            return
        }
        guard let deviceID = CA.deviceID(forUID: uid), CA.isAlive(deviceID) else {
            // Device gone: keep current mode; disconnect handling and the
            // devices-changed listener drive recovery.
            if controlMode == .software {
                if wantsProcessing { attemptStart() }   // sets outputDisconnected
            } else {
                status = .outputDisconnected
            }
            return
        }

        if deviceManager.hasSettableVolume(deviceID) {
            enterHardwareMode(deviceID: deviceID)
        } else {
            enterSoftwareMode()
        }
    }

    private func enterHardwareMode(deviceID: AudioObjectID) {
        if controlMode == .hardware, hardwareDeviceID == deviceID {
            refreshHardwareVolumeState()
            return
        }
        if pipeline.isRunning {
            // Native device needs no processing; tearing down the tap also
            // un-mutes the previous device's direct path.
            stopPipeline(newStatus: .stopped)
        }
        controlMode = .hardware
        hardwareDeviceID = deviceID
        mediaKeys.passThroughSoundKeys = true
        deviceManager.watchSelectedDevice(deviceID)
        refreshHardwareVolumeState()
        hardwareMuteFallbackVolume = max(volume, 0.1)
        status = .nativeVolume
        clearError()
        AppLog.devices.info("Hardware-volume mode for current device")
    }

    private func enterSoftwareMode() {
        let wasHardware = controlMode == .hardware
        if wasHardware {
            controlMode = .software
            hardwareDeviceID = AudioObjectID(kAudioObjectUnknown)
            mediaKeys.passThroughSoundKeys = false
            deviceManager.stopWatchingSelectedDevice()
            // Restore the app's own saved (software) volume and mute.
            volume = preferences.volume
            isMuted = preferences.muted
            gainProcessor.setTarget(volume: volume, muted: isMuted)
            AppLog.devices.info("Software-volume mode for current device")
        }
        if wantsProcessing {
            if !pipeline.isRunning { attemptStart() }
        } else if !pipeline.isRunning {
            status = .stopped
        }
    }

    /// Pulls the device's actual hardware volume/mute into the UI state
    /// (also called when the user changes volume elsewhere in macOS).
    private func refreshHardwareVolumeState() {
        guard controlMode == .hardware,
              hardwareDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        if let v = deviceManager.deviceVolume(hardwareDeviceID) {
            volume = v
        }
        if let m = deviceManager.deviceMute(hardwareDeviceID) {
            isMuted = m
        }
    }

    private func handleDevicesChanged() {
        refreshDevices()
        // Auto-recover when the remembered device returns (either mode).
        guard let uid = selectedDeviceUID,
              devices.contains(where: { $0.uid == uid }) else { return }
        let needsRecovery = status == .outputDisconnected
            || (controlMode == .software && wantsProcessing && !pipeline.isRunning)
        if needsRecovery {
            reevaluateControlMode()
        }
    }

    private func handleWatchedDeviceEvent(_ event: AudioDeviceManager.WatchedDeviceEvent) {
        switch event {
        case .aliveChanged(let isAlive):
            guard !isAlive else { return }
            if pipeline.isRunning {
                AppLog.devices.warning("Selected device died; stopping pipeline")
                stopPipeline(newStatus: .outputDisconnected)
            } else if controlMode == .hardware {
                AppLog.devices.warning("Hardware-controlled device died")
                status = .outputDisconnected
            }
        case .sampleRateChanged(let rate):
            guard controlMode == .software else { return }
            AppLog.devices.info("Sample rate changed to \(rate); rebuilding pipeline")
            scheduleRestart()
        case .streamConfigurationChanged:
            guard controlMode == .software else { return }
            AppLog.devices.info("Stream configuration changed; rebuilding pipeline")
            scheduleRestart()
        case .volumeChanged, .muteChanged:
            // Volume moved elsewhere in macOS (Sound settings, volume keys):
            // mirror it in the app UI.
            refreshHardwareVolumeState()
        }
    }

    /// Debounced stop→rebuild for format/rate changes.
    private func scheduleRestart() {
        guard pipeline.isRunning || wantsProcessing else { return }
        pendingRestart?.cancel()
        if pipeline.isRunning {
            stopPipeline(newStatus: .stopped)
        }
        let work = DispatchWorkItem { [weak self] in
            self?.nextRetryAllowedAt = .distantPast
            self?.attemptStart()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    // MARK: - Volume / mute

    /// Slider and programmatic volume changes. Changing volume while muted
    /// unmutes (matching system behavior).
    ///
    /// Hardware mode drives the device's real volume — 100% here is 100% in
    /// System Settings → Sound, identically. Software mode drives the
    /// pipeline's gain and persists the app's own volume.
    public func setVolume(_ newValue: Float, unmute: Bool = true) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, 0), 1)
        volume = clamped

        if controlMode == .hardware {
            deviceManager.setDeviceVolume(hardwareDeviceID, clamped)
            if unmute, isMuted {
                isMuted = false
                deviceManager.setDeviceMute(hardwareDeviceID, false)
            }
            return
        }

        preferences.volume = clamped
        if unmute, isMuted {
            isMuted = false
            preferences.muted = false
        }
        gainProcessor.setTarget(volume: clamped, muted: isMuted)
    }

    public func adjustVolume(by delta: Float) {
        setVolume(volume + delta, unmute: true)
    }

    public func toggleMute() {
        if controlMode == .hardware {
            let newMuted = !isMuted
            isMuted = newMuted
            if !deviceManager.setDeviceMute(hardwareDeviceID, newMuted) {
                // Device has no mute control: emulate with volume 0.
                if newMuted {
                    hardwareMuteFallbackVolume = max(volume, 0.1)
                    deviceManager.setDeviceVolume(hardwareDeviceID, 0)
                    volume = 0
                } else {
                    deviceManager.setDeviceVolume(hardwareDeviceID, hardwareMuteFallbackVolume)
                    volume = hardwareMuteFallbackVolume
                }
            }
            return
        }
        isMuted.toggle()
        preferences.muted = isMuted
        gainProcessor.setTarget(volume: volume, muted: isMuted)
    }

    // MARK: - Start at login

    public func setStartAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            preferences.startAtLogin = enabled
        } catch {
            AppLog.app.error("SMAppService failed: \(error.localizedDescription, privacy: .public)")
            recordError(userMessage: "Could not update Start at Login.",
                        technical: "SMAppService: \(error.localizedDescription)")
        }
        startAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Keyboard control

    /// Turning this on is the only place Accessibility permission is
    /// requested (per privacy policy: no prompts until the feature is used).
    public func setKeyboardControlEnabled(_ enabled: Bool) {
        keyboardControlEnabled = enabled
        preferences.keyboardControlEnabled = enabled
        if enabled {
            if !AccessibilityPermission.isGranted {
                AccessibilityPermission.request()
            }
            if AccessibilityPermission.isGranted {
                try? mediaKeys.start()
            }
        } else {
            mediaKeys.stop()
        }
        refreshPermissionStates()
    }

    // MARK: - Permissions helpers

    public func openAudioPermissionSettings() {
        AudioCapturePermission.openSystemSettings()
    }

    public func openAccessibilityPermissionSettings() {
        AccessibilityPermission.openSystemSettings()
    }

    private func refreshPermissionStates() {
        audioPermissionState = audioPermission.state
        accessibilityPermissionState = AccessibilityPermission.state
    }

    // MARK: - Onboarding

    public func completeOnboarding() {
        preferences.onboardingCompleted = true
        showOnboarding = false
    }

    // MARK: - Diagnostics

    public func diagnosticsReport() -> DiagnosticsReport {
        var report = DiagnosticsReport()
        report.status = status.displayName
        let selected = devices.first { $0.uid == selectedDeviceUID }
        report.deviceName = pipeline.isRunning ? pipeline.currentDeviceName
                                               : (selected?.name ?? "none selected")
        report.deviceUID = selectedDeviceUID ?? "—"
        report.sampleRate = stats.sampleRate > 0 ? stats.sampleRate : (selected?.sampleRate ?? 0)
        report.channelCount = stats.channelCount > 0 ? stats.channelCount
                                                     : (selected?.outputChannelCount ?? 0)
        report.tapFormat = stats.tapFormatDescription.isEmpty ? "—" : stats.tapFormatDescription
        report.outputFormat = stats.outputFormatDescription.isEmpty ? "—" : stats.outputFormatDescription
        report.estimatedLatencyMs = stats.estimatedLatencyMs
        report.underruns = stats.underruns
        report.overruns = stats.overruns
        report.inputCallbacks = stats.inputCallbacks
        report.outputCallbacks = stats.outputCallbacks
        report.nonSilentInputSeen = stats.nonSilentInputSeen
        report.audioPermission = audioPermissionState.rawValue
        report.accessibilityPermission = accessibilityPermissionState.rawValue
        report.lastError = lastErrorTechnicalDetails
        return report
    }

    public func copyDiagnostics() {
        diagnosticsReport().copyToPasteboard()
    }

    private func recordError(userMessage: String, technical: String) {
        lastErrorUserMessage = userMessage
        lastErrorTechnicalDetails = technical
    }

    private func clearError() {
        lastErrorUserMessage = nil
    }

    // MARK: - Polling (stats + health watchdog, 1 Hz, off the audio threads)

    private func startPollTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollTick() {
        refreshStats()

        // Permission inference: real audio flowed through the tap.
        if stats.nonSilentInputSeen, audioPermissionState != .granted {
            audioPermission.noteNonSilentAudioObserved()
        }
        refreshPermissionStates()

        // Keyboard control lifecycle:
        //  - permission revoked while the tap is up → tear it down at once
        //    (a lingering tap across a revocation can wedge session input);
        //  - user enabled the feature, then granted permission later → start.
        if mediaKeys.isRunning, !AccessibilityPermission.isGranted {
            AppLog.keys.warning("Accessibility revoked; removing media-key tap")
            mediaKeys.stop()
        } else if keyboardControlEnabled, !mediaKeys.isRunning,
                  AccessibilityPermission.isGranted {
            try? mediaKeys.start()
        }

        // Watchdog: IO callbacks must keep arriving while active. A stall
        // means the device or aggregate silently died.
        if pipeline.isRunning {
            if stats.inputCallbacks == lastInputCallbackCount {
                stalledTicks += 1
                if stalledTicks >= 4 {
                    AppLog.audio.error("IO stalled (no input callbacks for \(self.stalledTicks)s)")
                    recordError(userMessage: "Audio capture stopped unexpectedly.",
                                technical: "Input IOProc stalled for \(stalledTicks)s; pipeline rebuilt on next device event")
                    stopPipeline(newStatus: .audioError("Audio capture stalled"))
                    stalledTicks = 0
                }
            } else {
                stalledTicks = 0
            }
            lastInputCallbackCount = stats.inputCallbacks
        }
    }

    private func refreshStats() {
        stats = pipeline.stats()
    }

    // MARK: - Sleep / wake

    private func observeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.pipeline.isRunning {
                    AppLog.app.info("System sleeping; stopping pipeline")
                    self.stopPipeline(newStatus: .stopped)
                }
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                AppLog.app.info("System woke; re-evaluating output device")
                // Device object IDs may have changed across sleep — the
                // re-evaluation resolves everything from persistent UIDs
                // and restarts the pipeline only when needed.
                self.nextRetryAllowedAt = .distantPast
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.reevaluateControlMode()
                }
            }
        }
    }
}
