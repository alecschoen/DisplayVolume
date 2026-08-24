import SwiftUI

/// One-time welcome window: what the app does and its privacy properties.
struct OnboardingView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("DisplayVolume").font(.title2).bold()
                    Text("Volume control for fixed-volume displays")
                        .foregroundStyle(.secondary)
                }
            }

            Text("""
            Some USB-C, DisplayPort, and HDMI displays ignore the Mac's \
            volume keys. DisplayVolume fixes this in software: it captures \
            the audio heading to your display, adjusts the level, and plays \
            the result on the same display.
            """)

            VStack(alignment: .leading, spacing: 6) {
                step("1", "Open the speaker icon in the menu bar.")
                step("2", "Select your display (for example \u{201C}32X3A\u{201D}).")
                step("3", "Press Start Processing. macOS will ask once for System Audio Recording permission.")
                step("4", "Use the slider — or enable the keyboard volume keys in settings.")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    privacyRow("Audio is processed locally, in memory only.")
                    privacyRow("Nothing is ever recorded to disk or transmitted.")
                    privacyRow("No microphone access, analytics, or network use.")
                    privacyRow("Quitting the app instantly restores normal audio.")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Privacy", systemImage: "lock.shield")
                    .font(.caption.bold())
            }

            HStack {
                Spacer()
                Button("Get Started") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption.bold())
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).font(.callout)
        }
    }

    private func privacyRow(_ text: String) -> some View {
        Label(text, systemImage: "checkmark")
            .labelStyle(.titleAndIcon)
    }
}
