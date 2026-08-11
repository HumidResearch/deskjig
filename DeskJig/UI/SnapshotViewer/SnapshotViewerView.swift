//
//  SnapshotViewerView.swift
//  DeskJig
//
//  Main view for the System Snapshot Viewer with NavigationSplitView
//  Uses Finder-style sidebar navigation with section-based detail views
//

import SwiftUI
import DeskJigShared

struct SnapshotViewerView: View {
    @Bindable var viewModel: SnapshotViewerViewModel
    @State private var selectedSection: SidebarSection? = .windows

    var body: some View {
        NavigationSplitView {
            // Finder-style sidebar navigation
            SimpleSidebar(selection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            // Section-specific detail content
            detailContent
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Inspector toggle (only for Windows section)
                if selectedSection == .windows {
                    Button {
                        viewModel.isInspectorPresented.toggle()
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help(viewModel.isInspectorPresented ? "Hide Details" : "Show Details")
                }
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .displays:
            DisplaysDetailView(viewModel: viewModel)
        case .workspaces:
            WorkspacesDetailView(viewModel: viewModel)
        case .windows, .none:
            WindowsDetailView(viewModel: viewModel)
        }
    }
}