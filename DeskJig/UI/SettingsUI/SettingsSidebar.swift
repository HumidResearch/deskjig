//  SettingsSidebar.swift
//  DeskJig

import SwiftUI
import DeskJigShared

/// Sidebar section enumeration for the new settings UI.
enum SettingsSidebarSection: String, CaseIterable, Identifiable, Hashable {
    // Workspaces section
    case allWorkspaces
    case favorites

    // Tools section
    case quickSwitch

    // Navigation section
    case tutorials
    case settings
    case helpFeedback
#if DEBUG
    case designSystem
#endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allWorkspaces: return "All"
        case .favorites: return "Favorites"
        case .quickSwitch: return "Quick Switch"
        case .tutorials: return "Tutorials"
        case .settings: return "Settings"
        case .helpFeedback: return "Help & Feedback"
#if DEBUG
        case .designSystem: return "Design System"
#endif
        }
    }

    var icon: String {
        switch self {
        case .allWorkspaces: return "square.grid.2x2"
        case .favorites: return "star"
        case .quickSwitch: return "bolt.fill"
        case .tutorials: return "play.circle"
        case .settings: return "gearshape"
        case .helpFeedback: return "questionmark.circle"
#if DEBUG
        case .designSystem: return "paintbrush.pointed"
#endif
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .allWorkspaces: return "settings.nav.all"
        case .favorites: return "settings.nav.favorites"
        case .quickSwitch: return "settings.nav.quick-switch"
        case .tutorials: return "settings.nav.tutorials"
        case .settings: return "settings.nav.settings"
        case .helpFeedback: return "settings.nav.help-feedback"
#if DEBUG
        case .designSystem: return "settings.nav.design-system"
#endif
        }
    }

    /// Whether this section belongs to the "Workspaces" group
    var isWorkspaceSection: Bool {
        switch self {
        case .allWorkspaces, .favorites:
            return true
        default:
            return false
        }
    }

    /// Workspace sections
    static var workspaceSections: [SettingsSidebarSection] {
        [.allWorkspaces, .favorites]
    }

    /// Tools sections
    static var toolsSections: [SettingsSidebarSection] {
        [.quickSwitch]
    }

    /// Navigation sections
    static var navigationSections: [SettingsSidebarSection] {
        var sections: [SettingsSidebarSection] = [.tutorials, .settings, .helpFeedback]
#if DEBUG
        sections.append(.designSystem)
#endif
        return sections
    }
}

/// The vertical sidebar for the new settings UI.
struct SettingsSidebar: View {
    @Binding var selectedSection: SettingsSidebarSection
    var isNavigationLocked: Bool = false
    @EnvironmentObject var appUpdateController: SparkleController
    @Environment(WorkspaceViewModel.self) private var workspaceVM
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Workspaces section header
            sectionHeader("WORKSPACES")
                .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)

            // Workspace items
            ForEach(SettingsSidebarSection.workspaceSections) { section in
                SidebarItem(
                    icon: section.icon,
                    label: section.title,
                    count: countForSection(section),
                    isSelected: selectedSection == section,
                    action: { selectSection(section) }
                )
                .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)
                .accessibilityIdentifier(section.accessibilityIdentifier)
            }

            Spacer().frame(height: DesignTokens.Spacing.sectionGap)

            // Tools section header
            sectionHeader("TOOLS")
                .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)

            ForEach(SettingsSidebarSection.toolsSections) { section in
                SidebarItem(
                    icon: section.icon,
                    label: section.title,
                    isSelected: selectedSection == section,
                    action: { selectSection(section) }
                )
                .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)
                .accessibilityIdentifier(section.accessibilityIdentifier)
            }

            Spacer().frame(height: DesignTokens.Spacing.sectionGap)

            // Navigation section header
            sectionHeader("NAVIGATION")
                .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)

            // Navigation items
            ForEach(SettingsSidebarSection.navigationSections) { section in
                SidebarItem(
                    icon: section.icon,
                    label: section.title,
                    isSelected: selectedSection == section,
                    action: { selectSection(section) }
                )
                .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)
                .accessibilityIdentifier(section.accessibilityIdentifier)
            }

            Spacer()

            // Update badge at bottom
            updateBadgeSection
        }
        .padding(.top, DesignTokens.Spacing.contentPaddingRegular)
        .padding(.bottom, DesignTokens.Spacing.contentPaddingSmall)
        .frame(width: DesignTokens.Spacing.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.001))
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) {
            // Subtle separator on the right - full height
            Rectangle()
                .fill(DesignTokens.Border.subtle)
                .frame(width: 1)
                .edgesIgnoringSafeArea(.all)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(brand: .label4)
            .foregroundStyle(DesignTokens.Text.muted)
            .padding(.bottom, DesignTokens.Spacing.sectionHeaderBottom)
    }

    private func countForSection(_ section: SettingsSidebarSection) -> Int? {
        switch section {
        case .allWorkspaces:
            return windowManager.savedWorkspaces.count
        case .favorites:
            let count = workspaceVM.favoriteWorkspaces.count
            return count > 0 ? count : nil
        default:
            return nil
        }
    }

    private func selectSection(_ section: SettingsSidebarSection) {
        guard !isNavigationLocked else { return }
        selectedSection = section
    }

    @ViewBuilder
    private var updateBadgeSection: some View {
        if appUpdateController.shouldShowUpdateBadge {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
                Divider()
                    .background(DesignTokens.Border.subtle)

                UpdateBadge(
                    text: "New Update",
                    color: DesignTokens.Status.success,
                    isActive: true
                ) {
                    appUpdateController.checkForUpdates()
                }
                .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)
            }
        }
    }
}

#Preview {
    @Previewable @State var section: SettingsSidebarSection = .allWorkspaces

    SettingsSidebar(selectedSection: $section)
        .background(Color.black.opacity(0.8))
        .environmentObject(SparkleController())
        .environmentObject(WindowManager())
}
