//
//  AppsUpdaterView.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 10/13/25.
//

import SwiftUI
import AlinFoundation

struct AppsUpdaterView: View {
    @EnvironmentObject var updateManager: UpdateManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var brewManager: HomebrewManager
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var consoleManager = GlobalConsoleManager.shared
    @State private var searchText = ""
    @State private var hiddenSidebar: Bool = false
    @State private var selectedItemID: String?
    @AppStorage("settings.interface.scrollIndicators") private var scrollIndicators: Bool = false
    @AppStorage("settings.interface.animationEnabled") private var animationEnabled: Bool = true
    @AppStorage("settings.updater.sources") private var sourcesData: Data = UpdaterSourcesSettings.defaultEncoded()
    @AppStorage("settings.updater.display") private var displayData: Data = UpdaterDisplaySettings.defaultEncoded()

    // Computed properties for convenient access
    private var sources: UpdaterSourcesSettings {
        get {
            UpdaterSourcesSettings.decode(from: sourcesData)
        }
        set {
            sourcesData = newValue.encode()
        }
    }

    private var display: UpdaterDisplaySettings {
        get {
            UpdaterDisplaySettings.decode(from: displayData)
        }
        set {
            displayData = newValue.encode()
        }
    }

    private var allItems: [UpdaterListItem] {
        updateManager.appCentricItems.filter { item in
            switch item.section {
            case .current: return display.showCurrent
            case .managed: return display.showManaged
            case .unsupported: return display.showUnsupported
            default: return true
            }
        }
    }

    private var selectedItem: UpdaterListItem? {
        allItems.first { $0.id == selectedItemID }
    }

    private var directItems: [UpdaterListItem] {
        allItems.filter { $0.section == .available }
    }

    private var selectedDirectItems: [UpdaterListItem] {
        directItems.filter { $0.primaryApp?.isSelectedForUpdate == true }
    }

    private var externalItems: [UpdaterListItem] {
        allItems.filter { $0.section == .external }
    }

    private var attentionItems: [UpdaterListItem] {
        allItems.filter { $0.section == .attention }
    }

    private var unverifiedItems: [UpdaterListItem] {
        allItems.filter { $0.section == .unverified }
    }

    private var sidebarCategories: [(String, (UpdaterListItem) -> Bool, Bool, Bool)] {
        var cats: [(String, (UpdaterListItem) -> Bool, Bool, Bool)] = [
            (String(localized: "Update Available"), { $0.section == .available }, true, updateManager.scanningSources.contains(.homebrew) || updateManager.scanningSources.contains(.sparkle)),
            (String(localized: "External Update"), { $0.section == .external }, true, [UpdateSource.appStore, .electron, .official, .catalog].contains { updateManager.scanningSources.contains($0) }),
            (String(localized: "Error"), { $0.section == .attention }, true, false),
            (String(localized: "Check in App"), { $0.section == .unverified }, true, false)
        ]
        if display.showCurrent {
            cats.append((String(localized: "Current"), { $0.section == .current }, false, false))
        }
        if display.showManaged {
            cats.append((String(localized: "Self-Updating"), { $0.section == .managed }, false, false))
        }
        if display.showUnsupported {
            cats.append((String(localized: "Unsupported"), { $0.section == .unsupported }, false, false))
        }
        return cats
    }

    var body: some View {
        ZStack {
            SidebarDetailLayout {
                GenericSidebarListView(
                    items: allItems,
                    categories: sidebarCategories,
                    searchText: $searchText,
                    emptyMessage: "No apps to update",
                    noResultsMessage: "No matching apps",
                    isLoading: updateManager.isScanning,
                    loadingMessage: "Loading.."
                ) { item in
                    UpdateRowViewSidebar(
                        item: item,
                        isSelected: selectedItemID == item.id,
                        onTap: {
                            if selectedItemID == item.id {
                                selectedItemID = nil
                            } else {
                                selectedItemID = item.id
                            }
                        }
                    )
                }
            } detail: {
                VStack(spacing: 0) {
                    Group {
                        if let item = selectedItem, !item.issues.isEmpty {
                            UpdateFailureDetailView(item: item) {
                                Task {
                                    await updateManager.scanIfNeeded(
                                        forceReload: false,
                                        sources: Set(item.issues.map(\.source))
                                    )
                                }
                            }
                        } else if let app = selectedItem?.primaryApp {
                            UpdateDetailView(appId: app.id)
                        } else {
                            UpdaterOverviewView(
                                directUpdateCount: directItems.count,
                                externalUpdateCount: externalItems.count,
                                issueCount: attentionItems.count,
                                unverifiedCount: unverifiedItems.count,
                                installedBrewCount: brewManager.allPackages.count,
                                outdatedBrewCount: brewManager.outdatedPackagesMap.count,
                                isLoadingBrew: brewManager.isLoadingPackages || brewManager.isLoadingOutdated,
                                openHomebrew: { appState.currentPage = .homebrew }
                            )
                        }
                    }

                    batchActionBar
                }
            }
            .onChange(of: allItems.map(\.id)) { itemIDs in
                if let selectedItemID, !itemIDs.contains(selectedItemID) {
                    self.selectedItemID = nil
                }
            }
            .opacity(hiddenSidebar ? 0.5 : 1)

            UpdaterDetailsSidebar(
                hiddenSidebar: $hiddenSidebar,
                sources: Binding(
                    get: { self.sources },
                    set: { newValue in
                        self.sourcesData = newValue.encode()
                    }
                ),
                display: Binding(
                    get: { self.display },
                    set: { newValue in
                        self.displayData = newValue.encode()
                    }
                )
            )
        }
        .animation(animationEnabled ? .spring(response: 0.35, dampingFraction: 0.8) : .none, value: hiddenSidebar)
        .transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("UpdaterViewShouldRefresh"))) { _ in
            Task {
                let task = Task { await updateManager.scanIfNeeded(forceReload: true) }
                updateManager.currentScanTask = task
                await task.value
            }
        }
        .toolbar {
//            TahoeToolbarItem(placement: .navigation) {
//                HStack {
//                    VStack(alignment: .leading) {
//                        Text("Updater")
//                            .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
//                            .font(.title2)
//                            .fontWeight(.bold)
//                        Text("Check for app updates from App Store, Homebrew and Sparkle")
//                            .font(.callout)
//                            .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
//                    }
//                    BetaBadge()
//                }
//            }

            ToolbarItem { Spacer() }

            TahoeToolbarItem(isGroup: true) {

                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        consoleManager.showConsole.toggle()
                    }
                } label: {
                    Label("Console", systemImage: consoleManager.showConsole ? "terminal.fill" : "terminal")
                }
                .help("Toggle console output")

                if updateManager.isScanning {
                    // Show stop button during scan
                    Button {
                        updateManager.cancelScan()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .help("Stop checking for updates")
                } else {
                    // Show refresh button when not scanning
                    Button {
                        GlobalConsoleManager.shared.appendOutput("Refreshing app updates...\n", source: CurrentPage.updater.title)
                        Task {
                            let task = Task { await updateManager.scanIfNeeded(forceReload: true) }
                            updateManager.currentScanTask = task
                            await task.value
                            GlobalConsoleManager.shared.appendOutput("✓ Completed update scan\n", source: CurrentPage.updater.title)
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.counterclockwise")
                    }
                    .help("Scan for app updates")
                }

                Button {
                    hiddenSidebar.toggle()
                } label: {
                    Label("Hidden", systemImage: "sidebar.trailing")
                }
                .help("Show hidden updates")


            }
        }
        .task {
            if sources.homebrew.enabled, !brewManager.hasLoadedInstalledPackages {
                Task { await brewManager.loadInstalledPackages() }
            }

            // Skip scan if background scan already completed
            guard updateManager.lastScanDate == nil else {
                GlobalConsoleManager.shared.appendOutput("Using cached updates from background scan\n", source: CurrentPage.updater.title)
                return
            }

            GlobalConsoleManager.shared.appendOutput("Loading app updates...\n", source: CurrentPage.updater.title)
            let task = Task { await updateManager.scanIfNeeded() }
            updateManager.currentScanTask = task
            await task.value
            GlobalConsoleManager.shared.appendOutput("✓ Loaded app updates\n", source: CurrentPage.updater.title)
        }
        .onDisappear {
            UpdaterDebugLogger.shared.clearLogs()
        }
    }

    private func updateSelectedApps() {
        GlobalConsoleManager.shared.appendOutput("Starting update of \(selectedDirectItems.count) selected app(s)...\n", source: CurrentPage.updater.title)
        Task {
            await updateManager.updateSelectedApps()
            GlobalConsoleManager.shared.appendOutput("✓ Completed update operation\n", source: CurrentPage.updater.title)
        }
    }

    @ViewBuilder
    private var batchActionBar: some View {
        if !directItems.isEmpty || !externalItems.isEmpty {
            Divider()
            HStack(spacing: 12) {
                if updateManager.isUpdatingAll {
                    ProgressView(value: updateManager.updateAllProgress)
                        .frame(maxWidth: 180)
                    Text(verbatim: "\(updateManager.completedAppsCount)/\(updateManager.totalAppsToUpdate)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update all available apps")
                            .font(.callout.weight(.medium))
                    }
                }

                Spacer()

                Button {
                    updateSelectedApps()
                } label: {
                    Label(
                        String(localized: "Update All"),
                        systemImage: "arrow.down.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedDirectItems.isEmpty || updateManager.isScanning || updateManager.isUpdatingAll)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

private struct UpdaterOverviewView: View {
    let directUpdateCount: Int
    let externalUpdateCount: Int
    let issueCount: Int
    let unverifiedCount: Int
    let installedBrewCount: Int
    let outdatedBrewCount: Int
    let isLoadingBrew: Bool
    let openHomebrew: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Updater")
                        .font(.largeTitle.bold())
                    Text("Perform updates on 3rd party apps, and more")
                        .font(.callout)
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                }

                HStack(spacing: 12) {
                    UpdaterSummaryCard(
                        title: "Update Available",
                        count: directUpdateCount,
                        systemImage: "arrow.down.circle.fill",
                        tint: .blue
                    )
                    UpdaterSummaryCard(
                        title: "External",
                        count: externalUpdateCount,
                        systemImage: "macwindow",
                        tint: .purple
                    )
                    UpdaterSummaryCard(
                        title: "Check in App",
                        count: unverifiedCount,
                        systemImage: "questionmark.circle",
                        tint: .secondary
                    )
                    UpdaterSummaryCard(
                        title: "Error",
                        count: issueCount,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "mug.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text("Homebrew Manager")
                                    .font(.headline)
                                if isLoadingBrew {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            Text("Manage Homebrew packages, taps, and maintenance")
                                .font(.callout)
                                .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                        }

                        Spacer()

                        Button("Homebrew Manager", action: openHomebrew)
                            .buttonStyle(.bordered)
                    }

                    Divider()

                    HStack(spacing: 20) {
                        Label {
                            Text(verbatim: "\(installedBrewCount) ") + Text("Installed")
                        } icon: {
                            Image(systemName: "shippingbox")
                        }
                        Label {
                            Text(verbatim: "\(outdatedBrewCount) ") + Text("Outdated")
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .foregroundStyle(outdatedBrewCount > 0 ? .orange : ThemeColors.shared(for: colorScheme).secondaryText)
                    }
                    .font(.callout.monospacedDigit())
                }
                .padding(18)
                .background(ThemeColors.shared(for: colorScheme).secondaryBG.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 10) {
                    Label("From source", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    HStack(spacing: 18) {
                        Label("App Store", systemImage: "macwindow")
                        Label("Homebrew", systemImage: "terminal")
                        Label("Sparkle", systemImage: "sparkles")
                        Label("Electron", systemImage: "bolt.fill")
                    }
                }
                .font(.callout)
                .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct UpdaterSummaryCard: View {
    let title: LocalizedStringKey
    let count: Int
    let systemImage: String
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(count)")
                    .font(.title2.bold().monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(ThemeColors.shared(for: colorScheme).secondaryBG.opacity(0.62), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct UpdateFailureDetailView: View {
    let item: UpdaterListItem
    let retry: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var updateManager: UpdateManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    if let icon = item.appInfo?.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(.orange)
                            .frame(width: 64, height: 64)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: item.appName)
                            .font(.title.bold())
                        Text("Check for Updates")
                            .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(item.issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(issue.source.title, systemImage: sourceSymbol(issue.source))
                                .font(.headline)
                            Text(verbatim: issue.message)
                                .font(.callout)
                                .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                                .textSelection(.enabled)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((item.section == .unverified ? Color.gray : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                if item.section == .unverified {
                    Text("This app's update version cannot be verified automatically. Open the app to check for updates.")
                        .font(.callout)
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                    if let app = item.appInfo {
                        Button { NSWorkspace.shared.open(app.path) } label: {
                            Label("Open App", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(action: retry) {
                        Label("Check Again", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(updateManager.isScanning)
                } else {
                    Button(action: retry) {
                        Label("Retry", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updateManager.isScanning)
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .top)
        }
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
}
