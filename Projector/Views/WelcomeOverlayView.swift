import SwiftUI
import AppKit

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
                VStack(spacing: Spacing.lg) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)

                    Text("Welcome to Projector!")
                        .font(Typography.displayTitle)
                        .foregroundColor(.primary)
                }
                .padding(.top, Spacing.xxl)
                .padding(.bottom, Spacing.xl)

                Divider()
                    .padding(.horizontal, Spacing.xxl)

                // Steps
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    welcomeStep(
                        icon: "square.and.arrow.down.on.square",
                        iconColor: .blue,
                        title: "Drag in your media",
                        description: "Import video and audio files — add multiple video reels to build your show"
                    )

                    welcomeStep(
                        icon: "arrow.down.right.and.arrow.up.left",
                        iconColor: .green,
                        title: "Optimize your files",
                        description: "Save disk space and shrink unwieldy large files with built-in transcoding"
                    )

                    welcomeStep(
                        icon: "pianokeys",
                        iconColor: .purple,
                        title: "Connect your DAW",
                        description: "Send MTC to \"Projector MTC IN\" and MMC to \"Projector MMC IN\" for frame-accurate sync"
                    )

                    welcomeStep(
                        icon: "speaker.wave.3",
                        iconColor: .orange,
                        title: "Configure audio outputs",
                        description: "Choose your audio interface and custom map outputs in Settings"
                    )
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.vertical, Spacing.xxl)

                Divider()
                    .padding(.horizontal, Spacing.xxl)

                // Button
                Button(action: dismissWelcome) {
                    Text("I'm ready!")
                        .font(Typography.title)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
                        .background(
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.xxl)
            }
            .frame(width: 480)
            .background(
                RoundedRectangle(cornerRadius: Spacing.lg)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.lg)
                    .stroke(AppColors.borderSubtle, lineWidth: PanelLayout.borderWidth)
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .scaleEffect(appearAnimation ? 1.0 : 0.9)
            .opacity(appearAnimation ? 1.0 : 0.0)
        }
        .onAppear {
            withAnimation(AppAnimations.smoothSpring) {
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
        HStack(alignment: .top, spacing: Spacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(Typography.iconLarge)
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(Typography.title)
                    .foregroundColor(.primary)

                Text(description)
                    .font(Typography.heading)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func dismissWelcome() {
        withAnimation(AppAnimations.quick) {
            appearAnimation = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + AppAnimations.durationQuick) {
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
