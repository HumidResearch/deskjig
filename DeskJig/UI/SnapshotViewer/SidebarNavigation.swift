//
//  SidebarNavigation.swift
//  DeskJig
//
//  Sidebar navigation for System Snapshot Viewer - Finder-style navigation
//

import SwiftUI

/// Primary navigation sections for the System Snapshot Viewer
enum SidebarSection: String, CaseIterable, Identifiable {
    case displays = "Displays"
    case workspaces = "Workspaces"
    case windows = "Windows"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .displays: return "display"
        case .workspaces: return "square.stack.3d.up"
        case .windows: return "macwindow.on.rectangle"
        }
    }
}

/// Simple Finder-style sidebar with navigation items
struct SimpleSidebar: View {
    @Binding var selection: SidebarSection?

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarSection.allCases) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("System Snapshot")
    }
}

// MARK: - Shared Components

/// Reusable detail row for displaying label-value pairs
struct SidebarDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}