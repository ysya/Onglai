//
//  Update.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 11/5/23.
//

import AppKit
import SwiftUI

struct UpdateSettingsTab: View {
    @EnvironmentObject private var updater: OnglaiUpdater
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            PearGroupBox(
                header: {
                    Text("Update")
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                        .font(.title2)
                },
                content: {
                    updateStatus
                }
            )

            PearGroupBox(
                header: {
                    Text("Update Frequency")
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                        .font(.title2)
                },
                content: {
                    frequencyPicker
                }
            )

            Spacer(minLength: 0)
        }
        .task {
            await updater.checkIfNeeded()
        }
    }

    private var updateStatus: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Onglai")
                        .font(.title2.bold())
                    HStack(spacing: 4) {
                        Text("Current")
                        Text(verbatim: "v\(updater.currentVersion)")
                    }
                    .font(.callout)
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                }

                Spacer()

                statusBadge
            }

            Divider()

            stateContent

            HStack(spacing: 10) {
                primaryAction

                Button {
                    NSWorkspace.shared.open(AppLinks.releases)
                } label: {
                    Label("Releases", systemImage: "safari")
                }
                .buttonStyle(.bordered)

                Spacer()

                if let lastChecked = updater.lastChecked {
                    Label(
                        lastChecked.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "clock"
                    )
                        .font(.footnote)
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                }
            }
        }
        .padding(4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch updater.state {
        case .idle:
            badge("Check for Updates", systemImage: "arrow.counterclockwise", color: .secondary)
        case .checking:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking...")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        case .current:
            badge("Current", systemImage: "checkmark.circle.fill", color: .green)
        case .available:
            badge("Update Available", systemImage: "arrow.down.circle.fill", color: .blue)
        case .failed:
            badge("Error", systemImage: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private func badge(_ title: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var stateContent: some View {
        switch updater.state {
        case .idle:
            Text("\(Bundle.main.name) will check for updates")
                .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)

        case .checking:
            Text("Checking...")
                .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)

        case .current:
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text("\(Bundle.main.name) is already on the latest release available")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                    .font(.headline)
                    .foregroundStyle(.green)
                if let latestVersion = updater.latestVersion {
                    Text(verbatim: "v\(latestVersion)")
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                }
            }

        case .available:
            availableRelease

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Error", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(verbatim: message)
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                    .textSelection(.enabled)
            }
        }
    }

    private var availableRelease: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Update Available")
                    Text(verbatim: "v\(updater.latestVersion ?? "")")
                }
                    .font(.headline)
                Text("A new version of Onglai is available for download.")
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
            }

            if let release = updater.latestRelease {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Release Notes")
                        .font(.headline)

                    ScrollView {
                        Text(releaseNotes(for: release))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 230)
                    .padding(12)
                    .background(
                        ThemeColors.shared(for: colorScheme).secondaryBG.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
            }

        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch updater.state {
        case .checking:
            Button(action: {}) {
                Label("Checking...", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)

        case .available:
            Button {
                updater.installLatestRelease()
            } label: {
                Label("Update", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)

        case .failed:
            Button {
                Task { await updater.checkForUpdates() }
            } label: {
                Label("Retry", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderedProminent)

        case .idle, .current:
            Button {
                Task { await updater.checkForUpdates() }
            } label: {
                Label("Check for Updates", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var frequencyPicker: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Bundle.main.name) will check for updates")
                    .font(.callout)
                Text(verbatim: "github.com/ysya/Onglai")
                    .font(.footnote.monospaced())
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
            }

            Spacer()

            Picker("", selection: $updater.frequency) {
                ForEach(OnglaiUpdateFrequency.allCases) { frequency in
                    Text(LocalizedStringKey(frequency.title)).tag(frequency)
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
        .padding(4)
    }

    private func releaseNotes(for release: OnglaiRelease) -> AttributedString {
        guard let body = release.body, !body.isEmpty else {
            return AttributedString(String(localized: "No release notes were found"))
        }

        return (try? AttributedString(markdown: body)) ?? AttributedString(body)
    }
}
