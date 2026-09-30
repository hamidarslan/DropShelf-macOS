import SwiftUI

struct MenuBarOrganizerSettingsView: View {
    @ObservedObject private var organizer = MenuBarOrganizerController.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var palette: ClassicPalette { ClassicPalette(light: colorScheme == .light) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Menu Bar").font(.system(size: 20, weight: .semibold))
                    Text("Keep everyday icons close. Tuck the rest away.")
                        .font(.system(size: 11)).foregroundColor(palette.muted)
                }

                card {
                    switchRow("Manage menu bar icons", detail: organizer.enabled ? "Starts with DropShelf whenever enabled." : "Off stays off each time DropShelf starts.", binding: Binding(
                        get: { organizer.enabled }, set: { organizer.setEnabled($0) }
                    ), status: organizer.enabled ? "On" : "Off")
                }

                if organizer.conflictingOrganizerRunning {
                    HStack(alignment: .center, spacing: 12) {
                        Label("Hidebar is also running. Use one organizer at a time.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Quit Hidebar") { organizer.quitConflictingOrganizer() }
                            .controlSize(.small)
                    }
                    .padding(12)
                    .foregroundColor(palette.warm)
                    .background(RoundedRectangle(cornerRadius: 10).fill(palette.warm.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.warm.opacity(0.2), lineWidth: 1))
                }

                if organizer.enabled && (!organizer.hasCompletedSetup || organizer.isArranging || organizer.requiresVisibilityConfirmation) {
                    setupGuide
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Visibility")
                    card {
                        switchRow("Automatically hide", detail: "Waits while you use the menu bar.", binding: $organizer.autoHide)
                        rule
                        HStack {
                            Text("Hide after").font(.system(size: 13))
                            Spacer()
                            Picker("Hide after", selection: $organizer.delay) {
                                ForEach([5, 10, 15, 30, 60], id: \.self) { seconds in
                                    Text("\(seconds) seconds").tag(Double(seconds))
                                }
                            }
                            .labelsHidden().frame(width: 130)
                            .disabled(!organizer.autoHide)
                        }
                        .padding(.vertical, 10)
                        rule
                        switchRow("Start with icons hidden", detail: "Gives your menu bar 15 seconds to settle.", binding: $organizer.startHidden)
                    }
                }
                .disabled(!organizer.enabled)
                .opacity(organizer.enabled ? 1 : 0.55)

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Access")
                    card {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Reveal shortcut").font(.system(size: 13))
                                Text(organizer.recordingShortcut ? "Press a shortcut. Escape cancels." : "Click the keys to record a new shortcut.")
                                    .font(.system(size: 11)).foregroundColor(palette.muted)
                            }
                            Spacer(minLength: 0)
                            MenuBarShortcutRecorder(organizer: organizer)
                                .frame(width: 125, height: 28)
                        }
                        .padding(.vertical, 12)
                        HStack(spacing: 12) {
                            Text("The shelf keeps ⌘⇧Y.")
                                .font(.system(size: 10)).foregroundColor(palette.muted)
                            Spacer()
                            Button("Reset") { organizer.setShortcut(.standard) }
                            Button("Clear") { organizer.disableShortcut() }
                                .disabled(!organizer.shortcutEnabled)
                        }
                        .font(.system(size: 11))
                        .padding(.bottom, 12)
                        if !organizer.shortcutMessage.isEmpty {
                            Text(organizer.shortcutMessage)
                                .font(.system(size: 11))
                                .foregroundColor(organizer.shortcutAvailable ? palette.muted : palette.warm)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 12)
                                .accessibilityLabel("Shortcut status: \(organizer.shortcutMessage)")
                        }
                        rule
                        switchRow("Separate reveal button", detail: "Adds a small chevron beside DropShelf.", binding: $organizer.showSeparateToggle)
                    }
                }
                .disabled(!organizer.enabled)
                .opacity(organizer.enabled ? 1 : 0.55)

                if organizer.enabled {
                    controls
                }

                VStack(alignment: .leading, spacing: 8) {
                    if organizer.enabled && !organizer.statusMessage.isEmpty {
                        Label(organizer.statusMessage, systemImage: organizer.isPaused ? "pause.circle" : "info.circle")
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(organizer.enabled ? "Option-click DropShelf to show or hide icons. Its regular click still opens the shelf." : "Turn on to arrange your menu bar. Your choice and settings are remembered across launches.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Works locally. No additional permissions.", systemImage: "lock.shield")
                        .font(.system(size: 10))
                }
                .foregroundColor(palette.muted)
            }
            .padding(22)
        }
        .tint(palette.accent)
        .onAppear {
            if organizer.enabled && !organizer.hasCompletedSetup { organizer.beginArranging() }
        }
        .onChange(of: organizer.enabled) { enabled in
            if enabled && !organizer.hasCompletedSetup { organizer.beginArranging() }
        }
        .onDisappear {
            organizer.endArranging()
            organizer.cancelShortcutRecording()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: organizer.enabled)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    organizer.toggleHiddenItems()
                } label: {
                    Label(organizer.hidden ? "Show icons" : "Hide icons", systemImage: organizer.hidden ? "eye" : "eye.slash")
                        .foregroundColor(palette.onAccent)
                }
                .buttonStyle(.borderedProminent)
                Button("Arrange icons…") { organizer.beginArranging() }
                    .disabled(organizer.isArranging)
                Spacer(minLength: 0)
                Menu {
                    Button("5 minutes") { organizer.pauseHiding(seconds: 300) }
                    Button("1 hour") { organizer.pauseHiding(seconds: 3600) }
                    Button("Until resumed") { organizer.pauseHiding(seconds: nil) }
                } label: {
                    Label("Keep visible", systemImage: "pause")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(organizer.isArranging)
                .help("Pause hiding and keep your icons visible")
            }
            .controlSize(.small)
            if organizer.isPaused {
                HStack {
                    Label(organizer.pauseDescription, systemImage: "pause.circle.fill")
                        .foregroundColor(palette.warm)
                    Spacer()
                    Button("Resume hiding") { organizer.resumeHiding() }
                }
                .font(.system(size: 11))
            }
        }
    }

    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(organizer.hasCompletedSetup ? "Arrange your icons" : "Set up your menu bar", systemImage: "hand.draw")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if organizer.isArranging {
                    Text("Icons held visible").font(.system(size: 10, weight: .medium))
                        .foregroundColor(palette.accent)
                }
            }
            guideStep(1, "Hold Command (⌘) and drag less-used icons to the left of the divider in your real menu bar.")
            guideStep(2, "Keep DropShelf and the icons you use every day on the right.")
            guideStep(3, "Try hiding. Check the result before showing icons again.")
            if organizer.requiresVisibilityConfirmation {
                Text("While icons are hidden, a Show icons tab stays below the menu bar. Check that your chosen icons disappear, then click the tab to bring them back. If needed, reopen DropShelf from Applications to reveal all icons.")
                    .font(.system(size: 11)).foregroundColor(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Try hiding") {
                    organizer.endArranging()
                    organizer.hide()
                }
                Button("Show icons") {
                    organizer.reveal()
                    organizer.beginArranging()
                }
                Spacer(minLength: 0)
                Button { organizer.completeSetup() } label: {
                    Text(organizer.requiresVisibilityConfirmation ? "Hiding works" : "Done")
                        .foregroundColor(palette.onAccent)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(organizer.requiresVisibilityConfirmation && !organizer.hasVisibilityTrial)
                    .accessibilityLabel(organizer.requiresVisibilityConfirmation ? "Confirm icons hide and the Show icons tab restores them" : "Done")
                    .help(organizer.requiresVisibilityConfirmation ? "Confirm your chosen icons hide and the Show icons tab brings them back." : "Finish arranging icons")
            }
            .controlSize(.small)
            Text("Some system icons cannot move. A display notch can limit space when icons are revealed.")
                .font(.system(size: 10)).foregroundColor(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.selected))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.accent.opacity(0.2), lineWidth: 1))
    }

    private func guideStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)").font(.system(size: 10, weight: .semibold))
                .foregroundColor(palette.accent)
                .frame(width: 19, height: 19)
                .background(Circle().fill(palette.card))
                .accessibilityHidden(true)
            Text(text).font(.system(size: 11)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 11, weight: .medium)).foregroundColor(palette.muted)
    }

    private var rule: some View { Rectangle().fill(palette.border).frame(height: 1) }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
    }

    private func switchRow(_ title: String, detail: String, binding: Binding<Bool>, status: String? = nil) -> some View {
        Button {
            binding.wrappedValue.toggle()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(title).font(.system(size: 13, weight: status == nil ? .regular : .medium))
                        if let status {
                            Text(status).font(.system(size: 10, weight: .semibold))
                                .foregroundColor(binding.wrappedValue ? palette.accent : palette.muted)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(binding.wrappedValue ? palette.selected : palette.subtle))
                        }
                    }
                    Text(detail).font(.system(size: 11)).foregroundColor(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle(title, isOn: binding)
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(binding.wrappedValue ? "On" : "Off")
        .accessibilityHint(detail)
    }
}
