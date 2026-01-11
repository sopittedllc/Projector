import SwiftUI
import AppKit

/// Full-screen license entry view shown when app is not licensed
struct LicenseEntryView: View {
    @ObservedObject var licenseManager = LicenseManager.shared
    @State private var licenseKey = ""
    @State private var trialEmail = ""
    @State private var showTrialMode = false

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
                    Text(showTrialMode ? "Start Your Free Trial" : "Activate Projector")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    // Subtitle
                    if showTrialMode {
                        Text("Try Projector free for 7 days")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Enter your license key to unlock Projector")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Mode toggle (only show if trial not used)
                    if !licenseManager.trialUsed {
                        Picker("", selection: $showTrialMode) {
                            Text("License Key").tag(false)
                            Text("Free Trial").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                    }

                    // Input section
                    if showTrialMode && !licenseManager.trialUsed {
                        trialInputSection
                    } else {
                        licenseInputSection
                    }

                    // Trial expired message
                    if licenseManager.trialUsed && !licenseManager.isTrialActive && !licenseManager.hasFullLicense {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.badge.exclamationmark")
                                .foregroundColor(.orange)
                            Text("Your 7-day trial has ended")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.1))
                        )
                    }

                    // Purchase link
                    HStack(spacing: 4) {
                        Text("Don't have a license?")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Link("Purchase here", destination: URL(string: "https://musiquela.com/projector")!)
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

    // MARK: - License Key Input Section

    @ViewBuilder
    private var licenseInputSection: some View {
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
    }

    // MARK: - Trial Input Section

    @ViewBuilder
    private var trialInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Email Address", text: $trialEmail)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
                .disabled(licenseManager.isLoading)

            Text("We'll send you tips and updates. Unsubscribe anytime.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let error = licenseManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }

        Button(action: startTrial) {
            Text("Start 7-Day Trial")
                .frame(width: 160)
        }
        .buttonStyle(.borderedProminent)
        .disabled(trialEmail.isEmpty || licenseManager.isLoading)
        .keyboardShortcut(.return, modifiers: [])
    }

    // MARK: - Actions

    private func activateLicense() {
        Task {
            _ = await licenseManager.activate(key: licenseKey.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func startTrial() {
        Task {
            _ = await licenseManager.startTrial(email: trialEmail)
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
