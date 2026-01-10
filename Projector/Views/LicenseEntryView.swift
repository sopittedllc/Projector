import SwiftUI
import AppKit

/// Full-screen license entry view shown when app is not licensed
struct LicenseEntryView: View {
    @ObservedObject var licenseManager = LicenseManager.shared
    @State private var licenseKey = ""
    @State private var showDeactivateConfirm = false

    var body: some View {
        ZStack {
            // Background
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Content
                VStack(spacing: 24) {
                    // App icon
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)

                    // Title
                    Text("Activate Projector")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    // Subtitle
                    Text("Enter your license key to unlock Projector")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    // License key input
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("License Key", text: $licenseKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 400)
                            .disabled(licenseManager.isLoading)

                        if let error = licenseManager.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }

                    // Activate button
                    Button(action: activateLicense) {
                        if licenseManager.isLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 120)
                        } else {
                            Text("Activate")
                                .frame(width: 120)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(licenseKey.isEmpty || licenseManager.isLoading)
                    .keyboardShortcut(.return, modifiers: [])

                    // Purchase link
                    HStack(spacing: 4) {
                        Text("Don't have a license?")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Link("Purchase here", destination: URL(string: "https://projector.app")!)
                            .font(.caption)
                    }
                }
                .padding(40)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                Spacer()

                // Footer
                Text("Projector v1.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func activateLicense() {
        Task {
            _ = await licenseManager.activate(key: licenseKey.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Overlay shown when license check is in progress or license is invalid
struct LicenseOverlayView: View {
    @ObservedObject var licenseManager = LicenseManager.shared
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            LicenseEntryView()
        }
        .onChange(of: licenseManager.isLicensed) { _, isLicensed in
            if isLicensed {
                withAnimation {
                    isPresented = false
                }
            }
        }
    }
}

#Preview("License Entry") {
    LicenseEntryView()
}

#Preview("License Overlay") {
    LicenseOverlayView(isPresented: .constant(true))
        .frame(width: 800, height: 600)
}
