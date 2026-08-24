import DisplayVolumeKit
import SwiftUI

/// Settings and permission status, embedded in the menu-bar popover.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Match system output device", isOn: Binding(
                get: { appState.matchSystemOutput },
                set: { appState.setMatchSystemOutput($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Keep the selection in sync with System Settings → Sound: picking a device here also switches the Mac's output, and changing the Mac's output retargets DisplayVolume.")

            Toggle("Start at Login", isOn: Binding(
                get: { appState.startAtLoginEnabled },
                set: { appState.setStartAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)

            Toggle("Control with keyboard volume keys", isOn: Binding(
                get: { appState.keyboardControlEnabled },
                set: { appState.setKeyboardControlEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)

            permissionRow(
                title: "System Audio Recording",
                state: appState.audioPermissionState,
                helpWhenMissing: "Needed to capture audio for volume processing.",
                openSettings: { appState.openAudioPermissionSettings() },
                missingIsProblem: appState.status == .permissionRequired
            )

            permissionRow(
                title: "Accessibility (volume keys)",
                state: appState.accessibilityPermissionState,
                helpWhenMissing: "Needed only for the keyboard volume keys. The slider works without it.",
                openSettings: { appState.openAccessibilityPermissionSettings() },
                missingIsProblem: appState.keyboardControlEnabled
                    && appState.accessibilityPermissionState != .granted
            )
        }
        .font(.callout)
    }

    @ViewBuilder
    private func permissionRow(title: String,
                               state: PermissionState,
                               helpWhenMissing: String,
                               openSettings: @escaping () -> Void,
                               missingIsProblem: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(for: state, warn: missingIsProblem))
                .foregroundStyle(color(for: state, warn: missingIsProblem))
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption)
                Text(state.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state != .granted {
                Button("Open Settings") { openSettings() }
                    .controlSize(.small)
                    .help(helpWhenMissing)
            }
        }
    }

    private func symbol(for state: PermissionState, warn: Bool) -> String {
        switch state {
        case .granted: return "checkmark.circle.fill"
        case .denied: return warn ? "xmark.circle.fill" : "circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(for state: PermissionState, warn: Bool) -> Color {
        switch state {
        case .granted: return .green
        case .denied: return warn ? .red : .secondary
        case .unknown: return .secondary
        }
    }
}
