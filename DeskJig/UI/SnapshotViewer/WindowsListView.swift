//
//  WindowsListView.swift
//  DeskJig
//
//  Table view showing windows with clickable sortable column headers
//

import SwiftUI
import AppKit
import DeskJigShared

struct WindowsListView: View {
    @Bindable var viewModel: SnapshotViewerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerView

            // Windows table with native sorting via sortOrder binding
            Table(viewModel.sortedWindows, selection: $viewModel.selectedWindowId, sortOrder: $viewModel.sortOrder) {
                // Pin column (not sortable)
                TableColumn("") { window in
                    pinCell(window)
                }
                .width(min: 24, ideal: 28, max: 32)

                // Sortable columns using KeyPathComparator-compatible key paths
                TableColumn("ID", value: \.windowId) { window in
                    windowIdCell(window)
                }
                .width(min: 40, ideal: 55, max: 70)

                TableColumn("Z", value: \.sortableZOrder) { window in
                    zOrderCell(window)
                }
                .width(min: 30, ideal: 40, max: 50)

                TableColumn("PID", value: \.pid) { window in
                    Text("\(window.pid)")
                        .font(brand: Font.brandBody(size: 12))
                        .foregroundStyle(.secondary)
                }
                .width(min: 40, ideal: 55, max: 70)

                TableColumn("App", value: \.sortableAppName) { window in
                    Text(window.appName ?? "?")
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 120, max: 160)

                TableColumn("Title", value: \.sortableTitle) { window in
                    Text(window.title ?? "")
                        .lineLimit(1)
                        .foregroundStyle(window.title?.isEmpty ?? true ? .tertiary : .primary)
                }
                .width(min: 150, ideal: 220)

                TableColumn("Display", value: \.sortableDisplayIndex) { window in
                    displayCell(window)
                }
                .width(min: 45, ideal: 55, max: 70)

                // Frame column (not sortable - no value: parameter)
                TableColumn("Frame") { window in
                    Text("\(Int(window.frame.width))×\(Int(window.frame.height))")
                        .font(brand: Font.brandBody(size: 12))
                }
                .width(min: 65, ideal: 80, max: 100)

                // State column (not sortable)
                TableColumn("State") { window in
                    stateCell(window)
                }
                .width(min: 55, ideal: 70, max: 90)
            }
            .contextMenu(forSelectionType: String.self) { selectedIds in
                contextMenuContent(for: selectedIds)
            } primaryAction: { selectedIds in
                // Double-click highlights the window
                if let windowId = selectedIds.first,
                   let window = viewModel.snapshot?.windows.first(where: { $0.id == windowId }) {
                    WindowHighlightOverlay.shared.showHighlight(
                        around: window.frame,
                        duration: 2.5,
                        color: DesignTokens.Brand.accent,
                        lineWidth: 4.0
                    )
                }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuContent(for selectedIds: Set<String>) -> some View {
        if let windowId = selectedIds.first,
           let window = viewModel.snapshot?.windows.first(where: { $0.id == windowId }) {

            // Filter actions
            Section("Filter by") {
                Button {
                    viewModel.addPidFilter(window.pid)
                } label: {
                    Label("PID: \(window.pid)", systemImage: "number")
                }

                if let bundleId = window.bundleId {
                    let shortName = bundleId.split(separator: ".").last ?? Substring(bundleId)
                    Button {
                        viewModel.addBundleIdFilter(bundleId)
                    } label: {
                        Label("App: \(shortName)", systemImage: "app.badge")
                    }
                }

                if let displayIndex = window.displayIndex {
                    Button {
                        viewModel.addDisplayFilter(displayIndex)
                    } label: {
                        Label("Display: \(displayIndex)", systemImage: "display")
                    }
                }

                if let title = window.title, !title.isEmpty {
                    let truncatedTitle = title.prefix(30)
                    Button {
                        viewModel.addTitleFilter(title)
                    } label: {
                        Label("Title: \"\(truncatedTitle)\(title.count > 30 ? "..." : "")\"", systemImage: "textformat")
                    }
                }
            }

            Divider()

            // Copy actions
            Section("Copy") {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(window.windowId)", forType: .string)
                } label: {
                    Label("Window ID", systemImage: "doc.on.doc")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(window.pid)", forType: .string)
                } label: {
                    Label("PID", systemImage: "doc.on.doc")
                }

                if let bundleId = window.bundleId {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bundleId, forType: .string)
                    } label: {
                        Label("Bundle ID", systemImage: "doc.on.doc")
                    }
                }

                if let title = window.title, !title.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(title, forType: .string)
                    } label: {
                        Label("Title", systemImage: "doc.on.doc")
                    }
                }
            }

            Divider()

            // Pin action
            Button {
                viewModel.togglePin(windowId: window.id)
            } label: {
                if viewModel.isPinned(window.id) {
                    Label("Unpin", systemImage: "pin.slash")
                } else {
                    Label("Pin to Top", systemImage: "pin")
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Windows")
                .font(.headline)
            Text("(\(viewModel.filteredWindows.count))")
                .foregroundStyle(.secondary)

            // Pinned windows indicator
            if !viewModel.pinnedWindowIds.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(DesignTokens.Brand.accent)
                        .font(.caption2)
                    Text("\(viewModel.pinnedWindowIds.count) pinned")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Changed windows indicator
            if viewModel.isLiveUpdating && !viewModel.changedWindowIds.isEmpty {
                HStack(spacing: 2) {
                    Circle()
                        .fill(DesignTokens.Brand.accent)
                        .frame(width: 8, height: 8)
                    Text("\(viewModel.changedWindowIds.count) changed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Sort hint
            Text("Click column headers to sort")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Cell Views

    private func pinCell(_ window: SnapshotWindow) -> some View {
        Button(action: {
            viewModel.togglePin(windowId: window.id)
        }) {
            Image(systemName: viewModel.isPinned(window.id) ? "pin.fill" : "pin")
                .font(.caption)
                .foregroundStyle(viewModel.isPinned(window.id) ? DesignTokens.Brand.accent : .secondary)
        }
        .buttonStyle(.plain)
        .help(viewModel.isPinned(window.id) ? "Unpin window" : "Pin to top")
    }

    private func windowIdCell(_ window: SnapshotWindow) -> some View {
        HStack(spacing: 4) {
            // Delta indicator for changed windows
            if viewModel.changedWindowIds.contains(window.id) {
                Circle()
                    .fill(DesignTokens.Brand.accent)
                    .frame(width: 6, height: 6)
            }

            Text("\(window.windowId)")
                .font(brand: Font.brandBody(size: 16))
        }
    }

    private func zOrderCell(_ window: SnapshotWindow) -> some View {
        Group {
            if let z = window.zOrderIndex {
                Text("\(z)")
                    .font(brand: Font.brandBody(size: 12))
                    .foregroundStyle(z == 0 ? DesignTokens.Brand.accent : .secondary)
            } else {
                Text("-")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func displayCell(_ window: SnapshotWindow) -> some View {
        Group {
            if let idx = window.displayIndex {
                Text("\(idx)")
            } else {
                Text("-")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func stateCell(_ window: SnapshotWindow) -> some View {
        HStack(spacing: 4) {
            // Space indicator (heuristic: might be on different Space)
            if window.mightBeOnDifferentSpace {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(DesignTokens.Brand.accent)
                    .font(.caption2)
                    .help("Possibly on different Space")
            }

            // Visibility indicator
            if window.isOnScreen {
                Image(systemName: "eye.fill")
                    .foregroundStyle(DesignTokens.Brand.accent)
                    .font(.caption2)
            } else {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
            }

            // Minimized indicator
            if window.isMinimized == true {
                Image(systemName: "minus.circle")
                    .foregroundStyle(DesignTokens.Brand.accent)
                    .font(.caption2)
            }

            // Document indicator
            if window.documentPath != nil {
                Image(systemName: "doc.fill")
                    .foregroundStyle(DesignTokens.Brand.accent)
                    .font(.caption2)
            }
        }
    }
}