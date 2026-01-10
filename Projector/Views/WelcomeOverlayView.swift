import SwiftUI

/// Welcome overlay shown to first-time users
struct WelcomeOverlayView: View {
    @ObservedObject var settings = AppSettings.shared
    @Binding var isPresented: Bool

    @State private var appearAnimation = false

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            // Content card
            VStack(spacing: 0) {
                // Logo and title
                VStack(spacing: 16) {
                    Image("TitlebarLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 64)

                    Text("Welcome to Projector!")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                }
                .padding(.top, 32)
                .padding(.bottom, 24)

                Divider()
                    .padding(.horizontal, 24)

                // Steps
                VStack(alignment: .leading, spacing: 20) {
                    welcomeStep(
                        icon: "square.and.arrow.down.on.square",
                        iconColor: .blue,
                        title: "Drag in your media",
                        description: "Import video and audio files by dragging them into the media bin"
                    )

                    welcomeStep(
                        icon: "bolt.badge.checkmark",
                        iconColor: .green,
                        title: "Optimize for performance",
                        description: "Choose to transcode files for smoother playback and smaller file sizes"
                    )

                    welcomeStep(
                        icon: "pianokeys",
                        iconColor: .purple,
                        title: "Connect your DAW",
                        description: "Send MTC and MMC to \"Projector MIDI IN\" for frame-accurate sync"
                    )

                    welcomeStep(
                        icon: "speaker.wave.3",
                        iconColor: .orange,
                        title: "Configure audio outputs",
                        description: "Choose your audio interface and custom map outputs in Settings"
                    )
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)

                Divider()
                    .padding(.horizontal, 24)

                // Button
                Button(action: dismissWelcome) {
                    Text("I'm ready!")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
            .frame(width: 480)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .scaleEffect(appearAnimation ? 1.0 : 0.9)
            .opacity(appearAnimation ? 1.0 : 0.0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                appearAnimation = true
            }
        }
    }

    @ViewBuilder
    private func welcomeStep(
        icon: String,
        iconColor: Color,
        title: String,
        description: String
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func dismissWelcome() {
        withAnimation(.easeOut(duration: 0.2)) {
            appearAnimation = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            settings.hasCompletedWelcome = true
            isPresented = false
        }
    }
}

#Preview {
    WelcomeOverlayView(isPresented: .constant(true))
        .frame(width: 800, height: 600)
        .background(Color.gray)
}
