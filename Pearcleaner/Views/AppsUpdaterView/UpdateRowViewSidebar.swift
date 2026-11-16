//
//  UpdateRowViewSidebar.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 11/19/25.
//

import SwiftUI
import AlinFoundation

struct UpdateRowViewSidebar: View {
    let item: UpdaterListItem
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var updateManager: UpdateManager
    @AppStorage("settings.general.glass") private var glass: Bool = true
    @AppStorage("settings.interface.animationEnabled") private var animationEnabled: Bool = true
    @State private var isHovered = false

    private var appInfo: AppInfo? {
        item.appInfo ?? item.primaryApp?.appInfo
    }

    private var isDirectUpdate: Bool {
        item.section == .available && item.primaryApp?.canUpdate == true
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    appIcon

                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: item.appName)
                            .font(.system(size: isSelected ? 14 : 12, weight: isSelected ? .medium : .regular))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        subtitle
                            .font(.footnote)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isDirectUpdate, let app = item.primaryApp {
                Button {
                    updateManager.setSelection(
                        forAppAt: app.appInfo.path,
                        selected: !app.isSelectedForUpdate
                    )
                } label: {
                    Image(systemName: app.isSelectedForUpdate ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(app.isSelectedForUpdate ? ThemeColors.shared(for: colorScheme).accent : ThemeColors.shared(for: colorScheme).secondaryText)
                }
                .buttonStyle(.plain)
                .help("Update All")
            } else {
                sourceBadge
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected && !glass ? ThemeColors.shared(for: colorScheme).secondaryBG : (isHovered ? ThemeColors.shared(for: colorScheme).secondaryBG.opacity(0.45) : .clear))
        }
        .overlay(alignment: .trailing) {
            if isSelected {
                Capsule()
                    .fill(ThemeColors.shared(for: colorScheme).accent)
                    .frame(width: 3, height: 26)
                    .padding(.trailing, 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: animationEnabled ? 0.18 : 0)) {
                isHovered = hovering
            }
        }
        .task(id: "\(item.primaryApp?.id.uuidString ?? "none"):\(isSelected)") {
            guard let app = item.primaryApp,
                  isSelected,
                  let notesLink = app.releaseNotesLink,
                  let notesURL = URL(string: notesLink),
                  !ReleaseNotesProcessor.hasContent(app.releaseDescription),
                  app.fetchedReleaseNotes == nil else { return }
            await fetchReleaseNotes(for: app, from: notesURL)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = appInfo?.appIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(!item.issues.isEmpty ? Color.orange.opacity(0.16) : Color.gray.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: !item.issues.isEmpty ? "exclamationmark.triangle" : "app")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(!item.issues.isEmpty ? .orange : .secondary)
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if !item.issues.isEmpty {
            Text("Error")
                .foregroundStyle(.orange)
        } else if let app = item.primaryApp {
            if app.source == .current || app.source == .managed || app.source == .unsupported {
                Text(verbatim: app.appInfo.appVersion)
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
            } else if let availableVersion = app.availableVersion {
                versionText(installed: app.appInfo.appVersion, available: availableVersion, source: app.source)
            } else {
                Text(app.source.title)
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
            }
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        let source = item.primaryApp?.source ?? item.sources.first
        if let source {
            Image(systemName: sourceSymbol(source))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sourceColor(source))
                .frame(width: 18, height: 18)
                .help(source.title)
        }
    }

    private func versionText(installed: String, available: String, source: UpdateSource) -> Text {
        let installedVersion = source == .homebrew ? installed.stripBrewRevisionSuffix() : installed
        let availableVersion = source == .homebrew ? available.stripBrewRevisionSuffix() : available
        return Text(verbatim: installedVersion).foregroundColor(.orange)
            + Text(verbatim: " → ").foregroundColor(ThemeColors.shared(for: colorScheme).secondaryText)
            + Text(verbatim: availableVersion).foregroundColor(.green)
    }

    private func sourceSymbol(_ source: UpdateSource) -> String {
        switch source {
        case .homebrew: return "terminal"
        case .appStore: return "macwindow"
        case .sparkle: return "sparkles"
        case .electron: return "bolt.fill"
        case .official: return "globe"
        case .catalog: return "books.vertical"
        case .managed: return "arrow.up.forward.app"
        case .unsupported: return "questionmark.circle"
        case .current: return "checkmark.circle"
        }
    }

    private func sourceColor(_ source: UpdateSource) -> Color {
        switch source {
        case .homebrew: return .green
        case .appStore: return .purple
        case .sparkle: return .orange
        case .electron: return .yellow
        case .official: return .blue
        case .catalog: return .orange
        case .managed: return .blue
        case .unsupported, .current: return .gray
        }
    }

    private func fetchReleaseNotes(for app: UpdateableApp, from url: URL) async {
        do {
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
            request.httpMethod = "GET"

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  isSupportedReleaseNotesResponse(httpResponse),
                  httpResponse.expectedContentLength <= Int64(ReleaseNotesProcessor.externalNotesSizeLimit) else {
                return
            }

            var data = Data()
            data.reserveCapacity(min(
                max(Int(httpResponse.expectedContentLength), 0),
                ReleaseNotesProcessor.externalNotesSizeLimit
            ))
            for try await byte in bytes {
                guard data.count < ReleaseNotesProcessor.externalNotesSizeLimit else { return }
                data.append(byte)
            }

            guard let rawContent = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  let content = ReleaseNotesProcessor.normalizeExternalDocument(
                      rawContent,
                      installedVersion: app.appInfo.appVersion,
                      availableVersion: app.availableVersion
                  ) else {
                return
            }

            await MainActor.run {
                updateManager.updateFetchedReleaseNotes(for: app.id, content: content)
            }
        } catch {
            // Release notes are optional; the detail view will use inline notes.
        }
    }

    private func isSupportedReleaseNotesResponse(_ response: HTTPURLResponse) -> Bool {
        guard let mimeType = response.mimeType?.lowercased() else { return true }
        return mimeType.hasPrefix("text/") ||
            mimeType == "application/xhtml+xml" ||
            mimeType == "application/xml"
    }
}
