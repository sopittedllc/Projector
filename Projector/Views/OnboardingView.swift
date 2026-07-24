//
//  OnboardingView.swift
//  Projector
//
//  Sprint 3: Onboarding - Interactive setup wizard for composers.
//  Walks through MTC configuration step-by-step.
//
//  Layer: Views
//

import SwiftUI
import AppKit

// MARK: - DAW Type

/// Supported DAW types for MTC configuration guides
enum DAWType: String, CaseIterable, Identifiable {
    case logicPro = "Logic Pro"
    case proTools = "Pro Tools"
    case cubase = "Cubase"
    case ableton = "Ableton Live"
    case studioOne = "Studio One"
    case reaper = "REAPER"
    case other = "Other DAW"

    var id: String { rawValue }

    /// SF Symbol for each DAW
    var iconName: String {
        switch self {
        case .logicPro: return "apple.logo"
        case .proTools: return "waveform.path.ecg"
        case .cubase: return "c.circle"
        case .ableton: return "a.circle"
        case .studioOne: return "s.circle"
        case .reaper: return "r.circle"
        case .other: return "music.note"
        }
    }

    /// Short description
    var shortDescription: String {
        switch self {
        case .logicPro: return "Apple's professional DAW"
        case .proTools: return "Industry standard for post"
        case .cubase: return "Steinberg's flagship DAW"
        case .ableton: return "Live performance & production"
        case .studioOne: return "PreSonus DAW"
        case .reaper: return "Highly customizable DAW"
        case .other: return "Custom MIDI setup"
        }
    }

    /// Setup steps for this DAW
    var setupSteps: [DAWSetupStep] {
        switch self {
        case .logicPro:
            return [
                DAWSetupStep(
                    step: 1,
                    title: "Open Synchronization Settings",
                    detail: "Go to File → Project Settings → Synchronization (or press Option+P)",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 2,
                    title: "Enable MTC Output",
                    detail: "In the MIDI tab, check \"Transmit MIDI Clock\" and \"Transmit MTC\"",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 3,
                    title: "Select Destination",
                    detail: "Set the destination to \"Projector MIDI IN\"",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 4,
                    title: "Match Frame Rate",
                    detail: "Ensure your project frame rate matches your video (e.g., 23.976 fps)",
                    imageName: nil
                )
            ]
        case .proTools:
            return [
                DAWSetupStep(
                    step: 1,
                    title: "Open Session Setup",
                    detail: "Go to Setup → Session (Shift+N)",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 2,
                    title: "Configure Timecode",
                    detail: "Set your session timecode rate to match your video",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 3,
                    title: "Open Peripherals",
                    detail: "Go to Setup → Peripherals → Synchronization",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 4,
                    title: "Enable MTC Output",
                    detail: "Enable MTC Generation and select \"Projector MIDI IN\" as output",
                    imageName: nil
                )
            ]
        case .cubase:
            return [
                DAWSetupStep(
                    step: 1,
                    title: "Open Transport Settings",
                    detail: "Go to Transport → Project Synchronization Setup",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 2,
                    title: "Enable Timecode Output",
                    detail: "Check \"MIDI Timecode Destination\" and select \"Projector MIDI IN\"",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 3,
                    title: "Set Frame Rate",
                    detail: "Match the project frame rate to your video",
                    imageName: nil
                )
            ]
        case .ableton:
            return [
                DAWSetupStep(
                    step: 1,
                    title: "Open Preferences",
                    detail: "Go to Live → Preferences → Link/Tempo/MIDI",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 2,
                    title: "Enable MIDI Sync",
                    detail: "Enable \"Sync\" output for \"Projector MIDI IN\"",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 3,
                    title: "Note: MTC via Max for Live",
                    detail: "Ableton requires a Max for Live device for MTC output. Search \"MTC\" on maxforlive.com",
                    imageName: nil
                )
            ]
        case .studioOne:
            return [
                DAWSetupStep(
                    step: 1,
                    title: "Open Options",
                    detail: "Go to Studio One → Options → External Devices",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 2,
                    title: "Add New Controller",
                    detail: "Click Add and select \"New Instrument\" with Send MIDI Clock/MTC enabled",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 3,
                    title: "Select Output",
                    detail: "Choose \"Projector MIDI IN\" as the MIDI output",
                    imageName: nil
                )
            ]
        case .reaper:
            return [
                DAWSetupStep(
                    step: 1,
                    title: "Open Preferences",
                    detail: "Go to Options → Preferences → MIDI Devices",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 2,
                    title: "Enable Output",
                    detail: "Right-click \"Projector MIDI IN\" and enable it",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 3,
                    title: "Configure Sync",
                    detail: "Go to Options → Preferences → Synchronization → Output",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 4,
                    title: "Enable MTC",
                    detail: "Check \"Send MTC\" and select \"Projector MIDI IN\" as the output device",
                    imageName: nil
                )
            ]
        case .other:
            return [
                DAWSetupStep(
                    step: 1,
                    title: "Find MIDI/Sync Settings",
                    detail: "Look for \"Synchronization\", \"MIDI Settings\", or \"External Sync\" in your DAW's preferences",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 2,
                    title: "Enable MTC Output",
                    detail: "Enable MIDI Time Code (MTC) output/generation",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 3,
                    title: "Select Projector",
                    detail: "Set the MTC output destination to \"Projector MIDI IN\"",
                    imageName: nil
                ),
                DAWSetupStep(
                    step: 4,
                    title: "Match Frame Rates",
                    detail: "Ensure your DAW's timecode frame rate matches your video (23.976, 24, 25, 29.97, etc.)",
                    imageName: nil
                )
            ]
        }
    }
}

/// A single step in a DAW setup guide
struct DAWSetupStep: Identifiable {
    let id = UUID()
    let step: Int
    let title: String
    let detail: String
    let imageName: String?
}

// MARK: - Onboarding Step

/// The steps in the onboarding wizard
enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case selectDAW = 1
    case dawSetup = 2
    case audioSetup = 3
    case complete = 4

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .selectDAW: return "Select Your DAW"
        case .dawSetup: return "Configure MTC"
        case .audioSetup: return "Audio Setup"
        case .complete: return "Ready!"
        }
    }
}

// MARK: - OnboardingView

/// Interactive onboarding wizard for new Projector users.
///
/// Walks composers through:
/// 1. Welcome introduction
/// 2. DAW selection
/// 3. MTC configuration steps for their specific DAW
/// 4. Audio output configuration
/// 5. Completion
///
/// ## Usage
/// ```swift
/// .sheet(isPresented: $showOnboarding) {
///     OnboardingView(
///         audioManager: audioManager,
///         onComplete: {
///             settings.hasCompletedWelcome = true
///         }
///     )
/// }
/// ```
struct OnboardingView: View {
    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings = AppSettings.shared

    // MARK: - Properties

    @ObservedObject var audioManager: AudioOutputManager

    /// Called when onboarding is complete
    let onComplete: () -> Void

    // MARK: - State

    @State private var currentStep: OnboardingStep = .welcome
    @State private var selectedDAW: DAWType = .logicPro
    @State private var appearAnimation = false

    // MARK: - Body

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            // Content card
            VStack(spacing: 0) {
                // Progress indicator
                progressIndicator
                    .padding(.top, Spacing.lg)
                    .padding(.horizontal, Spacing.lg)

                // Step content
                stepContent
                    .frame(maxHeight: .infinity)

                Divider()

                // Navigation buttons
                navigationButtons
                    .padding(Spacing.lg)
            }
            .frame(width: 560, height: 520)
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

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                if step.rawValue > 0 && step.rawValue < OnboardingStep.allCases.count - 1 {
                    Capsule()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : AppColors.borderLight)
                        .frame(height: 4)
                }
            }
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
        case .selectDAW:
            selectDAWStep
        case .dawSetup:
            dawSetupStep
        case .audioSetup:
            audioSetupStep
        case .complete:
            completeStep
        }
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)

            VStack(spacing: Spacing.sm) {
                Text("Welcome to Projector")
                    .font(Typography.displayTitle)

                Text("Let's get you set up for video playback synced to your DAW")
                    .font(Typography.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                featureRow(icon: "film.stack", color: .blue, text: "Multiple video reels on a single timeline")
                featureRow(icon: "waveform", color: .green, text: "Multiple audio lanes with flexible routing")
                featureRow(icon: "clock.badge.checkmark", color: .purple, text: "Frame-accurate MTC synchronization")
            }
            .padding(.horizontal, Spacing.xl)

            Spacer()
        }
        .padding(Spacing.lg)
    }

    private func featureRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(Typography.displayBody)
                .foregroundColor(color)
                .frame(width: 24)

            Text(text)
                .font(Typography.body)
                .foregroundColor(.primary)

            Spacer()
        }
    }

    // MARK: - Select DAW Step

    private var selectDAWStep: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Which DAW do you use?")
                    .font(Typography.title)

                Text("We'll show you exactly how to configure MTC output")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)

            ScrollView {
                VStack(spacing: Spacing.sm) {
                    ForEach(DAWType.allCases) { daw in
                        dawSelectionRow(daw)
                    }
                }
                .padding(.horizontal, Spacing.lg)
            }
        }
    }

    private func dawSelectionRow(_ daw: DAWType) -> some View {
        let isSelected = selectedDAW == daw

        return Button(action: { selectedDAW = daw }) {
            HStack(spacing: Spacing.md) {
                // Radio indicator
                Circle()
                    .strokeBorder(isSelected ? Color.accentColor : AppColors.borderMedium, lineWidth: 2)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.clear)
                            .padding(3)
                    )
                    .frame(width: 18, height: 18)

                // Icon
                Image(systemName: daw.iconName)
                    .font(Typography.iconLarge)
                    .foregroundColor(.secondary)
                    .frame(width: 28)

                // Label
                VStack(alignment: .leading, spacing: 2) {
                    Text(daw.rawValue)
                        .font(Typography.body)
                        .foregroundColor(.primary)

                    Text(daw.shortDescription)
                        .font(Typography.captionSmall)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? AppColors.surfaceLight : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - DAW Setup Step

    private var dawSetupStep: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Image(systemName: selectedDAW.iconName)
                        .font(Typography.iconLarge)
                        .foregroundColor(.accentColor)

                    Text("\(selectedDAW.rawValue) MTC Setup")
                        .font(Typography.title)
                }

                Text("Follow these steps in your DAW")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(selectedDAW.setupSteps) { step in
                        setupStepRow(step)
                    }

                    // Projector MIDI Port note
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "info.circle")
                            .font(Typography.title)
                            .foregroundColor(.blue)

                        Text("Projector creates a virtual MIDI port called \"Projector MIDI IN\" automatically. It should appear in your DAW's MIDI output list.")
                            .font(Typography.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(Spacing.md)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding(.horizontal, Spacing.lg)
            }
        }
    }

    private func setupStepRow(_ step: DAWSetupStep) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            // Step number
            Text("\(step.step)")
                .font(Typography.badge)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())

            // Content
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(step.title)
                    .font(Typography.body.bold())
                    .foregroundColor(.primary)

                Text(step.detail)
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }

    // MARK: - Audio Setup Step

    private var audioSetupStep: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Audio Output")
                    .font(Typography.title)

                Text("Select your audio interface for playback")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)

            VStack(alignment: .leading, spacing: Spacing.md) {
                // Device picker
                Picker("Output Device", selection: $audioManager.selectedDeviceUID) {
                    Text("System Default").tag(nil as String?)
                    ForEach(audioManager.availableDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, Spacing.lg)

                // Channel info
                if let device = audioManager.selectedDevice {
                    HStack {
                        Image(systemName: "hifispeaker.2")
                            .foregroundColor(.secondary)

                        Text("\(device.outputChannelCount) output channels available")
                            .font(Typography.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, Spacing.lg)
                }

                // Note about audio routing
                HStack(spacing: Spacing.md) {
                    Image(systemName: "info.circle")
                        .font(Typography.title)
                        .foregroundColor(.blue)

                    Text("You can configure detailed audio routing later from the timeline header or Settings.")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                }
                .padding(Spacing.md)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, Spacing.lg)
            }

            Spacer()
        }
    }

    // MARK: - Complete Step

    private var completeStep: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(Typography.displayIcon)
                .foregroundColor(.green)

            VStack(spacing: Spacing.sm) {
                Text("You're all set!")
                    .font(Typography.displayTitle)

                Text("Drag in your video and audio files to get started")
                    .font(Typography.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                tipRow(icon: "doc.on.doc", text: "Drop multiple video files to create reels")
                tipRow(icon: "clock", text: "Files with embedded timecode will be auto-spotted")
                tipRow(icon: "play.fill", text: "Press Play in your DAW to start sync")
            }
            .padding(.horizontal, Spacing.xl)

            Spacer()
        }
        .padding(Spacing.lg)
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(Typography.title)
                .foregroundColor(.accentColor)
                .frame(width: 24)

            Text(text)
                .font(Typography.body)
                .foregroundColor(.primary)

            Spacer()
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            // Back button
            if currentStep != .welcome {
                Button("Back") {
                    withAnimation {
                        if let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) {
                            currentStep = prev
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Skip button
            if currentStep != .complete {
                Button("Skip Setup") {
                    completeOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            // Next/Done button
            Button(currentStep == .complete ? "Get Started" : "Next") {
                withAnimation {
                    if currentStep == .complete {
                        completeOnboarding()
                    } else if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
                        currentStep = next
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func completeOnboarding() {
        withAnimation(AppAnimations.quick) {
            appearAnimation = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + AppAnimations.durationQuick) {
            settings.hasCompletedWelcome = true
            onComplete()
            dismiss()
        }
    }
}

// MARK: - Preview

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(
            audioManager: AudioOutputManager(),
            onComplete: { }
        )
    }
}
#endif
