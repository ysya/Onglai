//
//  FileListView.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 7/31/25.
//

import AlinFoundation
import Foundation
import SwiftUI

enum FileListViewMode: String {
    case simple = "Simple"
    case categorized = "Categorized"
}

struct FileSelectionSummary {
    let selected: Set<URL>
    let visible: Set<URL>

    init(selected: Set<URL>, visible: [URL]) {
        self.selected = selected
        self.visible = Set(visible)
    }

    var visibleSelectedCount: Int { selected.intersection(visible).count }
    var hiddenSelectedCount: Int { selected.subtracting(visible).count }
    var allVisibleSelected: Bool { !visible.isEmpty && visible.isSubset(of: selected) }

    func togglingVisibleSelection() -> Set<URL> {
        allVisibleSelected ? selected.subtracting(visible) : selected.union(visible)
    }

    func selectingOnlyVisible() -> Set<URL> { visible }
}

struct FileListView: View {
    @AppStorage("settings.interface.scrollIndicators") private var scrollIndicators: Bool = false
    @AppStorage("settings.general.brew") private var brew: Bool = false
    @AppStorage("settings.interface.animationEnabled") private var animationEnabled: Bool = true
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @Binding var sortedFiles: [URL]
    @Binding var infoSidebar: Bool
    @Binding var selectedSort: SortOptionList
    @Binding var viewMode: FileListViewMode
    private var searchText: String {
        get { appState.fileSearchText }
        nonmutating set { appState.fileSearchText = newValue }
    }
    private var selectedFileItemsLocal: Set<URL> {
        get { appState.selectedItems }
        nonmutating set { appState.selectedItems = newValue }
    }
    private var selection: FileSelectionSummary {
        FileSelectionSummary(
            selected: appState.selectedItems,
            visible: filteredFiles.filter { appState.verifiedUninstallItems.contains($0) }
        )
    }
    @State private var memoizedFiles: [URL] = []
    @State private var lastRefreshDate: Date?
    @State private var collapsedCategories: Set<FileCategory> = []
    let locations: Locations
    let windowController: WindowManager
    let handleUninstallAction: (Bool) -> Void
    let displaySizeTotal: String
    let totalSelectedSize: String
    let updateSortedFiles: () -> Void
    let removeSingleZombieAssociation: (URL) -> Void
    let removePath: (URL) -> Void


    var filteredFiles: [URL] {
        if searchText.isEmpty {
            return memoizedFiles
        } else {
            return memoizedFiles.filter { path in
                path.lastPathComponent.localizedCaseInsensitiveContains(searchText)
                    || path.path.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    // Categorized files grouped by category
    var categorizedFiles: [GroupedFiles] {
        // Group files by category
        var grouped: [FileCategory: [URL]] = [:]
        for file in filteredFiles {
            let category = categorizeFile(file)
            grouped[category, default: []].append(file)
        }

        // Convert to GroupedFiles array
        return grouped.map { category, files in
            let totalSize = files.reduce(0) { sum, url in
                sum + (appState.appInfo.fileSize[url] ?? 0)
            }

            let selectable = files.filter { appState.verifiedUninstallItems.contains($0) }
            let selectedCount = selectable.filter { selectedFileItemsLocal.contains($0) }.count

            return GroupedFiles(
                category: category,
                files: files,
                totalSize: totalSize,
                isExpanded: !collapsedCategories.contains(category),
                allSelected: selectedCount == selectable.count && !selectable.isEmpty,
                someSelected: selectedCount > 0 && selectedCount < selectable.count
            )
        }
        .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.appInfo.fileSize.keys.count == 0 && !appState.isBrewCleanupInProgress {
                VStack {
                    Spacer()
                    Text(appState.externalMode ? "Sentinel Monitor found no other files to remove" : "There are no files to remove")
                        .font(.title2)
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if appState.isBrewCleanupInProgress && appState.appInfo.fileSize.keys.count == 0 {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Running homebrew cleanup")
                            .font(.title2)
                            .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {

                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)

                        TextField("Search...", text: $appState.fileSearchText)
                            .textFieldStyle(.plain)
                            .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).accent)
                    .controlGroup(Capsule(style: .continuous), level: .primary)
                    .padding(.top, 5)

                    // Stats header
                    HStack {
                        Text("\(selection.visibleSelectedCount) of \(selection.visible.count) visible items selected")
                            .font(.caption)
                            .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)

                        Spacer()

                        if let lastRefresh = lastRefreshDate {
                            TimelineView(.periodic(from: lastRefresh, by: 1.0)) { _ in
                                Text("Updated \(formatRelativeTime(lastRefresh))")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                            }
                        }
                    }
                    .padding(.vertical)

                    if memoizedFiles.contains(where: { !appState.verifiedUninstallItems.contains($0) }) {
                        Text("Shared files and files with unverified ownership are kept.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 5)
                    }

                    if selection.hiddenSelectedCount > 0 {
                        HStack {
                            Label("\(selection.hiddenSelectedCount) selected items are hidden by search", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                            Spacer()
                            Button("Select Only Results") {
                                appState.selectedItems = selection.selectingOnlyVisible()
                            }
                        }
                        .foregroundStyle(.orange)
                        .padding(.bottom, 8)
                    }

                    // File list (simple or categorized based on viewMode)
                    ScrollView {
                        if viewMode == .simple {
                            // Simple flat list view
                            LazyVStack(spacing: 0) {
                                ForEach(Array(filteredFiles.enumerated()), id: \.element) { index, path in
                                    VStack(spacing: 0) {
                                        FileDetailsItem(
                                            path: path,
                                            removeAssociation: removeSingleZombieAssociation,
                                            isSelected: binding(for: path)
                                        )

                                        if index < filteredFiles.count - 1 {
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .onAppear {
                                updateSortedFiles()
                                updateMemoizedFiles()
                            }
                            .onChange(of: sortedFiles) { _ in
                                updateMemoizedFiles()
                            }
                        } else {
                            // Categorized view
                            LazyVStack(spacing: 8) {
                                ForEach(categorizedFiles, id: \.category) { group in
                                    FileCategoryView(
                                        group: group,
                                        onToggleExpand: {
                                            withAnimation(.easeInOut(duration: animationEnabled ? 0.2 : 0)) {
                                                toggleCategory(group.category)
                                            }
                                        },
                                        onToggleSelection: {
                                            toggleCategorySelection(group)
                                        },
                                        fileItemBinding: binding(for:),
                                        removeAssociation: removeSingleZombieAssociation
                                    )

                                    if group.category != categorizedFiles.last?.category {
                                        Divider()
                                            .padding(.vertical, 4)
                                    }
                                }
                            }
                            .onAppear {
                                updateSortedFiles()
                                updateMemoizedFiles()
                            }
                            .onChange(of: sortedFiles) { _ in
                                updateMemoizedFiles()
                            }
                        }
                    }
                    .scrollIndicators(scrollIndicators ? .automatic : .never)
                    .onAppear {
                        if lastRefreshDate == nil {
                            lastRefreshDate = Date()
                        }
                    }
                    .onChange(of: appState.isScanningApp) { isShowing in
                        // When scan completes (showProgress becomes false), update refresh date
                        if !isShowing && appState.appInfo.fileSize.keys.count > 0 {
                            lastRefreshDate = Date()
                        }
                    }

                    if appState.trashError {
                        HStack {
                            Spacer()
                            InfoButton(
                                text:
                                    "Some files could not be moved. Check permissions and try again. Open details for technical information.",
                                color: .orange, label: "View Error", warning: true,
                                extraView: {
                                    Button("View Debug Window") {
                                        windowController.open(
                                            with: ConsoleView(), width: 600, height: 400)
                                    }
                                }
                            )
                            .onDisappear {
                                appState.trashError = false
                            }
                            .padding(.bottom)
                        }

                    }
                }
                .opacity(infoSidebar ? 0.5 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .safeAreaInset(edge: .bottom) {
                    if !memoizedFiles.isEmpty {
                        HStack {
                            Spacer()

                            HStack(spacing: 10) {
                                Button(selection.allVisibleSelected ? String(localized: "Deselect Results") : String(localized: "Select Results")) {
                                    appState.selectedItems = selection.togglingVisibleSelection()
                                }
                                .disabled(selection.visible.isEmpty)
                                .buttonStyle(ControlGroupButtonStyle(
                                    foregroundColor: ThemeColors.shared(for: colorScheme).accent,
                                    shape: Capsule(style: .continuous),
                                    level: .primary,
                                    skipControlGroup: true
                                ))

                                Divider().frame(height: 10)

                                Button {
                                    handleUninstallAction(selection.hiddenSelectedCount > 0)
                                } label: {
                                    Label {
                                        Text("Trash \(selectedFileItemsLocal.count) Items (\(totalSelectedSize))")
                                    } icon: {
                                        Image(systemName: "trash")
                                    }
                                }
                                .disabled(selectedFileItemsLocal.isEmpty || appState.isDeletingFiles)
                                .buttonStyle(ControlGroupButtonStyle(
                                    foregroundColor: ThemeColors.shared(for: colorScheme).accent,
                                    shape: Capsule(style: .continuous),
                                    level: .primary,
                                    skipControlGroup: true
                                ))
                            }
                            .controlGroup(Capsule(style: .continuous), level: .primary)

                            Spacer()
                        }
                        .padding([.horizontal, .bottom])
                    }
                }
            }

            if !appState.externalPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: scrollIndicators) {
                    HStack(spacing: 10) {
                        ForEach(appState.externalPaths, id: \.self) { path in
                            HStack(spacing: 5) {
                                Button(path.deletingPathExtension().lastPathComponent) {
                                    let newApp = AppInfoFetcher.getAppInfo(atPath: path)!
                                    updateOnMain {
                                        appState.appInfo = newApp
                                    }
                                    showAppInFiles(
                                        appInfo: newApp, appState: appState, locations: locations)
                                }
                                .buttonStyle(.link)
                                Button {
                                    removePath(path)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding()
            }
        }
        .disabled(appState.isDeletingFiles)

    }

    // Helper function to create binding for individual files
    private func binding(for file: URL) -> Binding<Bool> {
        Binding<Bool>(
            get: {
                selectedFileItemsLocal.contains(file) && filteredFiles.contains(file)
            },
            set: { isSelected in
                if isSelected {
                    if selection.visible.contains(file) {
                        selectedFileItemsLocal.insert(file)
                    }
                } else {
                    selectedFileItemsLocal.remove(file)
                }
                // Sync with appState
                appState.selectedItems = selectedFileItemsLocal
            }
        )
    }

    // Helper function to toggle category expansion
    private func toggleCategory(_ category: FileCategory) {
        if collapsedCategories.contains(category) {
            collapsedCategories.remove(category)
        } else {
            collapsedCategories.insert(category)
        }
    }

    // Helper function to toggle category selection
    private func toggleCategorySelection(_ group: GroupedFiles) {
        let selectable = Set(group.files).intersection(selection.visible)
        if group.allSelected {
            selectedFileItemsLocal.subtract(selectable)
        } else {
            selectedFileItemsLocal.formUnion(selectable)
        }
    }

    // Helper function to update memoized files
    private func updateMemoizedFiles() {
        memoizedFiles = sortedFiles
    }
}
