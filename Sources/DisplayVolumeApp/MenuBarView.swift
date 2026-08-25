import DisplayVolumeKit
import SwiftUI

/// The minimal left-click popover: status, output picker, volume.
/// Everything else lives in the right-click menu and the Settings window.
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
            deviceSelector
            volumeControls
            if let message = appState.lastErrorUserMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { appState.refreshDevices() }
    }

    // MARK: Status

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(appState.status.displayName)
                .font(.headline)
            Spacer()
            // Compact start/stop for the software pipeline — the slider
            // only has an effect while processing runs.
            if appState.controlMode == .software {
                Button {
                    if appState.isProcessing {
                        appState.stopProcessing()
                    } else {
                        appState.startProcessing()
                    }
                } label: {
                    Image(systemName: appState.isProcessing ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .disabled(appState.selectedDeviceUID == nil)
                .help(appState.isProcessing ? "Stop processing" : "Start processing")
            }
            Text("\(appState.volumePercent)%")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(appState.isMuted ? .secondary : .primary)
        }
    }

    private var statusColor: Color {
        switch appState.status {
        case .active, .nativeVolume: return .green
        case .stopped: return .secondary.opacity(0.6)
        case .permissionRequired: return .yellow
        case .outputDisconnected: return .orange
        case .audioError: return .red
        }
    }

    // MARK: Device

    private var deviceSelector: some View {
        Picker("Output", selection: Binding(
            get: { appState.selectedDeviceUID ?? "" },
            set: { uid in
                if !uid.isEmpty { appState.selectDevice(uid: uid) }
            }
        )) {
            if appState.selectedDeviceUID == nil {
                Text("Select a display…").tag("")
            }
            ForEach(appState.devices) { device in
                Text("\(device.name) (\(device.transportName))").tag(device.uid)
            }
            // Keep a remembered-but-disconnected device visible.
            if let uid = appState.selectedDeviceUID,
               !appState.devices.contains(where: { $0.uid == uid }) {
                Text("Remembered device (disconnected)").tag(uid)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: Volume

    private var volumeControls: some View {
        HStack(spacing: 8) {
            Button {
                appState.toggleMute()
            } label: {
                Image(systemName: appState.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(appState.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { Double(appState.volume) },
                    set: { appState.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .disabled(appState.selectedDeviceUID == nil)

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

/// Collapsible diagnostics: device identity, format, counters, last error.
struct DiagnosticsSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        DisclosureGroup("Diagnostics", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                let report = appState.diagnosticsReport()
                diagRow("Device", report.deviceName)
                diagRow("UID", report.deviceUID)
                diagRow("Sample rate", report.sampleRate > 0
                        ? String(format: "%.0f Hz", report.sampleRate) : "—")
                diagRow("Channels", report.channelCount > 0
                        ? "\(report.channelCount)" : "—")
                diagRow("Tap format", report.tapFormat)
                diagRow("Latency", String(format: "≈%.1f ms", report.estimatedLatencyMs))
                diagRow("Underruns", "\(report.underruns)")
                diagRow("Overruns", "\(report.overruns)")
                diagRow("Last error", report.lastError)

                Button {
                    appState.copyDiagnostics()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Diagnostics",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
