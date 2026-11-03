import AppKit
import SwiftUI

/// Shown after an encrypted DNS profile is saved: how to approve it in System Settings, and how to remove it.
struct ProfileGuideSheet: View {
    let guide: DNSActionCenter.ProfileGuide

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.purple.gradient))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Install the Encrypted DNS Profile").font(.title3.weight(.bold))
                    Text("Saved as “\(guide.file.lastPathComponent)”. macOS only installs a profile after you approve it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, text: "**Open the file** with the button below, or double-click it in Finder. macOS says the profile was downloaded for review.")
                Step(number: 2, text: "Go to **System Settings › General › Device Management**. On older macOS it's **Privacy & Security › Profiles**.")
                Step(number: 3, text: "Double-click **DNS Pulse – \(guide.serverName)**, click **Install…** and enter your Mac password.")

                VStack(alignment: .leading, spacing: 6) {
                    Label("Good to know", systemImage: "info.circle")
                        .font(.callout.weight(.semibold))
                    Text("While the profile is installed, every app on this Mac uses \(guide.serverName) over \(guide.proto == .dot ? "TLS" : "HTTPS"), on every network. It takes priority over the DNS servers in Network settings; some VPNs override it while they're connected.")
                    Text("**To remove it**, go back to Device Management (or Profiles), select the profile and click the **–** button. Your normal DNS comes back straight away.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            .padding(20)

            Divider()

            HStack(spacing: 10) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([guide.file]) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Profile") { NSWorkspace.shared.open(guide.file) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540)
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.purple.gradient))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
