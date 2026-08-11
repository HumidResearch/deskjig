//  ActionPanelContent.swift
//  DeskJig
//  Created by Jake Sax on 10/21/25.


import SwiftUI
import DeskJigShared
import KeyboardShortcuts
import AppKit

struct ActionPanelContent: View {
    
    @Bindable var manager: ActionPanelManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage("uiScale") var uiScale: UIScale = .regular
    
    var body: some View {
        VStack(alignment: .trailing, spacing: Self.buttonSpacing) {
            panelContent
        }
        .padding(Self.padding)
        .scaleEffect(uiScale.scale, anchor: .bottomTrailing)
        .animation(.bouncy(duration: 0.35), value: uiScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(ActionPanelManager.panelPadding)
        .onChange(of: manager.workspaceVM.workspaceBeingEdited) { oldValue, newValue in
            // When workspace editing starts or ends, show/hide the editor panel
            manager.showWorkspaceEditorIfNeeded()

            // When workspace editing ends (goes from non-nil to nil), refresh the workspace list
            if oldValue != nil && newValue == nil {
                MainActor.async(after: .seconds(0.1)) {
                    manager.updateDynamicContent()
                }
            }
        }
        .onChange(of: manager.workspaceVM.directoryWorkspaceBeingEdited) { oldValue, newValue in
            // When directory workspace editing starts or ends, show/hide the editor panel
            manager.showWorkspaceEditorIfNeeded()

            // When directory workspace editing ends (goes from non-nil to nil), refresh the list
            if oldValue != nil && newValue == nil {
                MainActor.async(after: .seconds(0.1)) {
                    manager.updateDynamicContent()
                }
            }
        }
    }
}

// MARK: - Panel Content
private extension ActionPanelContent {
    var panelContent: some View {
        VStack(alignment: .trailing, spacing: Self.buttonSpacing) {
            let rootItems = Array(manager.visibleRootItems.enumerated().reversed())
            if manager.isExpanded {
                // Render menu items from configuration (in reverse order for stacking)
                ForEach(rootItems, id: \.element.id) { index, item in
                    renderRootMenuItem(item, index: Double(index))
                        .zIndex(Double(rootItems.count - index))
                }
            }
            
            // Toggle button at bottom
            ExpandCloseButton(
                isExpanded: manager.isExpanded,
                toggleExpansion: manager.toggleExpansion,
                deselectSections: manager.deselectAnySection
            )
            .id("expand-close-button")
            .zIndex(Double(manager.visibleRootItems.count + 1))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .transition(.animatedBlur)
    }
    
    @ViewBuilder
    func renderRootMenuItem(_ item: MenuItem, index: Double) -> some View {
        if item.type == .separator {
            // Don't render separators in this UI style
            EmptyView()
        } else if item.type == .branch || item.type == .dynamic {
            // Branch or dynamic item - shows children when selected
            renderBranchItem(item)
                .transition(Self.transition(yOffset: Self.buttonHeight * (index + 1)))
        } else {
            // Leaf item - executes action
            renderLeafItem(item)
                .transition(Self.transition(yOffset: Self.buttonHeight * (index + 1)))
        }
    }
    
    func renderBranchItem(_ item: MenuItem) -> some View {
        let depth = 0
        let parentOffset: CGPoint = .zero
        
        let children = manager.getChildren(for: item)
        let isThisSelected = manager.selectedSection == item.id
        let isDescendantSelected = isAnyDescendantSelected(item.id, selectedSection: manager.selectedSection)
        
        return ZStack {
            // Show children if this section OR any descendant is selected
            if isThisSelected || isDescendantSelected {
                // Recursively render all nested levels that are in the selection path
                renderNestedChildrenRecursively(
                    children: children,
                    currentDepth: depth,
                    parentOffset: parentOffset
                )
                
                // Then show immediate children
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    renderChildButton(child, index: index + 1, depth: depth + 1, parentOffset: parentOffset)
                }
            }
            
            // Main section button
            PanelButton(
                text: item.title,
                icon: item.icon,
                isSelected: isThisSelected || isDescendantSelected,
                isHorizontal: false,
                contextAction: item.contextAction,
                onPressContextAction: {
                    if let contextAction = item.contextAction {
                        return {
                            manager.executeAction(
                                contextAction.action,
                                parameters: contextAction.actionParameters
                            )
                        }
                    } else {
                        return nil
                    }
                }(),
                workspace: item.actionParameters?.workspace,
                onPressShortcutPill: {
                    if let workspace = item.actionParameters?.workspace {
                        return {
                            // Execute the same action as the Edit pill - opens the floating editor panel
                            manager.executeAction(.editWorkspace, parameters: .init(workspace: workspace))
                        }
                    } else {
                        return nil
                    }
                }(),
                onHover: { isHovering in
                    if isHovering {
                        // Immediately select this section (will deselect others)
                        manager.selectSection(item.id)
                        // Cancel any pending submenu close timer
                        manager.cancelSubmenuExitTimer()
                        // Cancel the panel-wide auto-close timer when hovering over items
                        manager.cancelMouseExitTimer()
                    } else {
                        // Start timer to close this submenu when mouse leaves
                        manager.startSubmenuExitTimer()
                        // Start the panel auto-close timer when mouse leaves any item
                        manager.startMouseExitTimer()
                    }
                },
                onPress: {
                    // Only select if not already selected to prevent shimmy
                    if manager.selectedSection != item.id {
                        manager.selectSection(item.id)
                    }
                }
            )
        }
    }
    
    /// Recursively renders nested children for all branches in the selection path
    private func renderNestedChildrenRecursively(
        children: [MenuItem],
        currentDepth: Int,
        parentOffset: CGPoint
    ) -> some View {
        return ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
            Group {
                // Check if this child or any of its descendants are selected
                if (child.type == .branch || child.type == .dynamic) &&
                    (manager.selectedSection == child.id || hasDescendant(child, withId: manager.selectedSection ?? "")) {
                    
                    let childChildren = manager.getChildren(for: child)
                    
                    // Calculate this child's position
                    let childIsHorizontal = (currentDepth + 1) % 2 == 1
                    let childXOffset = childIsHorizontal ? Self.buttonOffset(count: index + 1) : 0
                    let childYOffset = childIsHorizontal ? 0 : -(Self.buttonHeight + Self.buttonSpacing) * CGFloat(index + 1)
                    let childOffset = CGPoint(x: parentOffset.x + childXOffset, y: parentOffset.y + childYOffset)
                    
                    // Recursively render nested children (type erased)
                    AnyView(
                        renderNestedChildrenRecursively(
                            children: childChildren,
                            currentDepth: currentDepth + 1,
                            parentOffset: childOffset
                        )
                    )
                    
                    // Then render this child's immediate children
                    ForEach(Array(childChildren.enumerated()), id: \.element.id) { nestedIndex, nestedChild in
                        renderChildButton(
                            nestedChild,
                            index: nestedIndex + 1,
                            depth: currentDepth + 2,
                            parentOffset: childOffset
                        )
                    }
                }
            }
        }
    }
    
    private func isAnyDescendantSelected(_ parentId: String, selectedSection: String?) -> Bool {
        guard let selectedSection = selectedSection else {
            return false
        }
        
        if selectedSection == parentId {
            return true
        }
        
        guard let parentItem = findMenuItem(parentId, in: manager.configuration.rootItems) else {
            return false
        }
        
        return hasDescendant(parentItem, withId: selectedSection)
    }
    
    /// Recursively searches for a descendant with the given ID
    private func hasDescendant(_ item: MenuItem, withId targetId: String) -> Bool {
        let children = manager.getChildren(for: item)
        
        for child in children {
            // Check if this child matches
            if child.id == targetId {
                return true
            }
            
            // Recursively check this child's descendants
            if hasDescendant(child, withId: targetId) {
                return true
            }
        }
        
        return false
    }
    
    /// Finds a menu item by ID in the menu tree
    private func findMenuItem(_ id: String, in items: [MenuItem]) -> MenuItem? {
        for item in items {
            if item.id == id {
                return item
            }
            
            if let children = item.children {
                if let found = findMenuItem(id, in: children) {
                    return found
                }
            }
        }
        return nil
    }
    
    func renderLeafItem(_ item: MenuItem) -> some View {
        PanelButton(
            text: item.title,
            icon: item.icon,
            isSelected: manager.isMenuItemActivelySelected(item),
            usesAccentSelectedStyle: false,
            isHorizontal: false,
            contextAction: item.contextAction,
            onPressContextAction: {
                if let contextAction = item.contextAction {
                    return {
                        manager.executeAction(
                            contextAction.action,
                            parameters: contextAction.actionParameters
                        )
                    }
                } else {
                    return nil
                }
            }(),
            workspace: item.actionParameters?.workspace,
            workspaceIconPreview: item.actionParameters?.workspace.flatMap { workspaceIconPreviewData(for: $0) },
            onPressShortcutPill: {
                if let workspace = item.actionParameters?.workspace {
                    return {
                        // Execute the same action as the Edit pill - opens the floating editor panel
                        manager.executeAction(.editWorkspace, parameters: .init(workspace: workspace))
                    }
                } else {
                    return nil
                }
            }(),
            onHover: { isHovering in
                if isHovering {
                    // Immediately close any open submenu when hovering over a leaf item
                    manager.deselectAnySection()
                    // Cancel any pending timer since we're immediately closing
                    manager.cancelSubmenuExitTimer()
                    // Cancel the panel-wide auto-close timer when hovering over items
                    manager.cancelMouseExitTimer()
                } else {
                    // Start the panel auto-close timer when mouse leaves any item
                    manager.startMouseExitTimer()
                }
            },
            onPress: {
                if let action = item.action {
                    logWorkspaceAction(action, parameters: item.actionParameters)
                    manager.executeAction(action, parameters: item.actionParameters)
                }
            }
        )
    }
    
    private func workspaceIconPreviewData(for workspace: Workspace) -> WorkspaceIconPreviewData? {
        let appManager = manager.workspaceVM.applicationManager
        var seenKeys: Set<String> = []
        var icons: [WorkspaceIconModel] = []
        
        for window in workspace.windows {
            let key = window.bundleIdentifier
            guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
            
            let appInfo = appManager.findApplication(by: key)
            let fallbackName = appInfo?.name ?? window.appName
            icons.append(
                WorkspaceIconModel(
                    id: key,
                    image: appInfo?.icon,
                    fallbackName: fallbackName
                )
            )
        }
        
        guard !icons.isEmpty else { return nil }
        
        icons.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        
        let shouldShowAll = icons.count <= 4
        let visibleCount = shouldShowAll ? icons.count : min(3, icons.count)
        let extraCount = max(0, icons.count - visibleCount)
        
        let displayedIcons = Array(icons.prefix(visibleCount))
        return WorkspaceIconPreviewData(icons: displayedIcons, extraCount: extraCount)
    }
    
    
    func renderChildButton(
        _ item: MenuItem,
        index: Int,
        depth: Int,
        parentOffset: CGPoint = .zero
    ) -> some View {
        let isHorizontal = depth % 2 == 1
        let localXOffset = isHorizontal ? Self.buttonOffset(count: index) : 0
        let localYOffset = isHorizontal ? 0 : -(Self.buttonHeight + Self.buttonSpacing) * CGFloat(index)
        
        let totalXOffset = parentOffset.x + localXOffset
        let totalYOffset = parentOffset.y + localYOffset
        let parentXIndex = Self.indexFromXOffset(totalXOffset)
        
        return PanelButton(
            text: item.title,
            icon: item.icon,
            isSelected: manager.isMenuItemActivelySelected(item),
            usesAccentSelectedStyle: false,
            isHorizontal: isHorizontal,
            contextAction: item.contextAction,
            onPressContextAction: {
                if let contextAction = item.contextAction {
                    return {
                        manager.executeAction(
                            contextAction.action,
                            parameters: contextAction.actionParameters
                        )
                    }
                } else {
                    return nil
                }
            }(),
            workspace: item.actionParameters?.workspace,
            workspaceIconPreview: item.actionParameters?.workspace.flatMap { workspaceIconPreviewData(for: $0) },
            onPressShortcutPill: {
                if let workspace = item.actionParameters?.workspace {
                    return {
                        // Execute the same action as the Edit pill - opens the floating editor panel
                        manager.executeAction(.editWorkspace, parameters: .init(workspace: workspace))
                    }
                } else {
                    return nil
                }
            }(),
            onHover: { isHovering in
                // Disable child buttons when there is no selected section
                guard manager.selectedSection != nil else {
                    return
                }
                
                if isHovering {
                    // Cancel submenu exit timer when hovering over any child
                    manager.cancelSubmenuExitTimer()
                    // Cancel the panel-wide auto-close timer when hovering over items
                    manager.cancelMouseExitTimer()
                    
                    // If the menu isn't closing, select it
                    manager.selectSection(item.id)
                } else {
                    // Start submenu exit timer when leaving a child button
                    manager.startSubmenuExitTimer()
                    // Start the panel auto-close timer when mouse leaves any item
                    manager.startMouseExitTimer()
                }
            },
            onPress: {
                // If child is a branch, toggle it to show its children
                if item.type == .branch || item.type == .dynamic {
                    manager.selectSection(item.id)
                } else if let action = item.action {
                    // Otherwise execute the action
                    logWorkspaceAction(action, parameters: item.actionParameters)
                    manager.executeAction(action, parameters: item.actionParameters)
                }
            }
        )
        .zIndex(-Double(index))
        .offset(x: totalXOffset, y: totalYOffset)
        .transition(
            .asymmetric(
                insertion: Self.transition(
                    xOffset: 0,
                    yOffset: 0,
                    anchor: isHorizontal ? .trailing : .init(x: 0.25 + parentXIndex, y: 0)
                ),
                removal: Self.transition(
                    xOffset: 0,
                    yOffset: 0,
                    anchor: isHorizontal ? .trailing : .init(x: 0.25 + parentXIndex, y: 0)
                )
            )
        )
        .contextMenu {
            if let childAction = item.action, childAction == .deleteWorkspace {
                Button(role: .destructive) {
                    manager.executeAction(childAction, parameters: item.actionParameters)
                } label: {
                    Label("Delete Workspace", systemImage: "trash")
                }
            }
        }
    }
    
    static func transition(
        xOffset: CGFloat = .zero,
        yOffset: CGFloat = .zero,
        anchor: UnitPoint = .bottom
    ) -> AnyTransition {
        .blurTransition(blurRadius: 3, xOffset: xOffset, yOffset: yOffset, scale: 0.2, anchor: anchor)
        .animation(.bouncy(duration: 0.3, extraBounce: 0.00))
    }
    
    static func buttonOffset(count: Int = 1) -> CGFloat {
        (-buttonWidth - buttonSpacing) * CGFloat(count)
    }
    
    static func indexFromXOffset(_ offset: CGFloat) -> CGFloat {
        offset / (buttonWidth + buttonSpacing)
    }

    private func logWorkspaceAction(_ action: MenuAction, parameters: ActionParameters?) {
        switch action {
        case .openWorkspace, .restoreWorkspace, .restoreWorkspaceWithMapping:
            let workspaceName = parameters?.workspace?.name ?? parameters?.workspaceName ?? "unknown"
            let workspaceId = parameters?.workspace?.id.uuidString ?? parameters?.workspaceID?.uuidString ?? "unknown"
            DeskJigLog.info(.app, "ACTION-PANEL: workspace button pressed", fields: ["action": action.rawValue, "name": workspaceName, "id": workspaceId])
        default:
            return
        }
    }
}

// MARK: - Panel Sub Button
private extension ActionPanelContent {
    struct PanelSubButton: View {
        
        let text: String
        let systemIcon: String?
        let icon: String?
        let index: Int
        let onHover: ((Bool) -> Void)?
        let onPress: () -> Void
        @State private var isHovering: Bool = false
        
        static let hoverScale: CGFloat = (ActionPanelContent.buttonWidth + 8) / ActionPanelContent.buttonWidth
        
        var body: some View {
            Button(action: onPress) {
                VStack(spacing: 6) {
                    
                    VStack {
                        if let icon {
                            Text(icon) // emoji
                                .font(brand: Font.brandBody(size: 18))
                        } else if let systemIcon {
                            Image(systemName: systemIcon)
                                .font(brand: Font.brandBody(size: 20))
                        }
                    }
                    .frame(height: 24)
                    
                    Text(text)
                        .font(brand: .label4)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                    
                }
                .foregroundStyle(DesignTokens.Text.primary)
                .frame(
                    width: ActionPanelContent.buttonWidth,
                    height: ActionPanelContent.buttonHeight
                )
                .background {
                    ActionPanelContent.PanelButton.BKGD(isHovering: isHovering)
                        .shadow(color: Color.black.opacity(0.1), radius: 4, y: 1.5)
                        .shadow(color: Color.black.opacity(0.05), radius: 12, y: 4)
                }
                .scaleEffect(isHovering ? Self.hoverScale : 1)
                .onHover { hovering in
                    isHovering = hovering
                    onHover?(hovering)
                }
                .animation(.bouncy(duration: 0.25, extraBounce: 0.1), value: isHovering)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Panel Button
extension ActionPanelContent {
    
    struct PanelButton: View {
        
        let text: String
        let icon: MenuItem.MenuIcon?
        let isSelected: Bool
        let usesAccentSelectedStyle: Bool
        let isHorizontal: Bool
        let contextAction: MenuItem.ContextAction?
        let onPressContextAction: (() -> Void)?
        let workspace: Workspace?  // For workspace shortcuts
        let workspaceIconPreview: WorkspaceIconPreviewData?
        let onPressShortcutPill: (() -> Void)?  // Action when shortcut pill is clicked
        let onHover: ((_ isHovering: Bool) -> Void)?
        let onPress: () -> Void
        @State private var isHovering: Bool = false
        @State private var showIcons: Bool = false
        private var scale: CGFloat {
            isHovering ? Self.hoverScale : 1
        }
        
        var body: some View {
            button
                .buttonStyle(.plain)
                .background(alignment: isHorizontal ? .top : .trailing) { // Align to right/top side, then offset to left/bottom below
                    if isHovering, let contextAction, let onPressContextAction {
                        ContextActionButton(
                            contextAction: contextAction,
                            isHorizontal: isHorizontal,
                            onPress: onPressContextAction
                        )
                    }
                }
                .background(alignment: .top) { // Workspace icon stack overlay when hovering workspace buttons
                    if showIcons, let preview = workspaceIconPreview {
                        WorkspaceCompactIconRow(preview: preview)
                            .frame(width: ActionPanelContent.buttonWidth)
                            .allowsHitTesting(false)
                            .offset(y: -ActionPanelContent.buttonHeight + 36)
                            .transition(.asymmetric(
                                insertion: .opacity.animation(.easeIn(duration: 1.0)),
                                removal: .opacity.animation(.linear(duration: 0))
                            ))
                    }
                }
                .background(alignment: .bottom) { // Keyboard shortcut pill below button
                    if isHovering, let workspace, let onPressShortcutPill {
                        KeyboardShortcutPill(
                            workspaceId: workspace.id,
                            workspace: workspace,
                            onPress: onPressShortcutPill
                        )
                    }
                }
                .scaleEffect(scale)
                .onHover { nowHovering in
                    isHovering = nowHovering
                    onHover?(nowHovering)
                    
                    if nowHovering {
                        // Start 1-second timer, then fade in over 1 second (completes at 2 seconds total)
                        Task {
                            await Task.sleepUnlessCancelled(for: .seconds(1))
                            if isHovering {
                                showIcons = true
                            }
                        }
                    } else {
                        // Hide icons immediately when hover ends
                        showIcons = false
                    }
                }
                .animation(.smooth(duration: 0.25), value: isSelected)
                .animation(.bouncy(duration: 0.25, extraBounce: 0.2), value: scale)
        }
        
        private var button: some View {
            Button(action: onPress) {
                VStack(spacing: 6) {
                    
                    if let icon {
                        MenuIconView(icon: icon, size: 20)
                            .frame(height: 24)
                    }
                    
                    Text(text)
                        .font(brand: .label4)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                    
                }
                .foregroundStyle(DesignTokens.Text.primary)
                    .frame(
                    width: ActionPanelContent.buttonWidth,
                    height: ActionPanelContent.buttonHeight
                )
                .background {
                    BKGD(
                        isHovering: isHovering || isSelected,
                        isAccentSelected: usesAccentSelectedStyle && isSelected
                    )
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 1.5)
                        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
                }
            }
        }
        
        init(
            text: String,
            icon: MenuItem.MenuIcon? = nil,
            isSelected: Bool,
            usesAccentSelectedStyle: Bool = false,
            isHorizontal: Bool,
            contextAction: MenuItem.ContextAction? = nil,
            onPressContextAction: (() -> Void)? = nil,
            workspace: Workspace? = nil,
            workspaceIconPreview: WorkspaceIconPreviewData? = nil,
            onPressShortcutPill: (() -> Void)? = nil,
            onHover: ((_ isHovering: Bool) -> Void)?,
            onPress: @escaping () -> Void
        ) {
            self.text = text
            self.icon = icon
            self.isSelected = isSelected
            self.usesAccentSelectedStyle = usesAccentSelectedStyle
            self.isHorizontal = isHorizontal
            self.contextAction = contextAction
            self.onPressContextAction = onPressContextAction
            self.workspace = workspace
            self.workspaceIconPreview = workspaceIconPreview
            self.onPressShortcutPill = onPressShortcutPill
            self.onHover = onHover
            self.onPress = onPress
        }
        
        struct ContextActionButton: View {
            
            let contextAction: MenuItem.ContextAction
            let isHorizontal: Bool
            let onPress: () -> Void
            @State private var isHovering: Bool = false
            
            var body: some View {
                Button(action: onPress) {
                    HStack(spacing: 4) {
                        MenuIconView(icon: contextAction.icon, size: 12)
                        Text(contextAction.title)
                    }
                    .font(brand: .label4)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .padding(4)
                    .padding(.horizontal, 4)
                    .background {
                        BKGD(isHovering: isHovering)
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 1.5)
                            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
                    }
                    .padding(4)
                    .onHover(perform: { isHovering = $0 })
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .frame(
                    maxWidth: isHorizontal ? .infinity : nil,
                    maxHeight: isHorizontal ? nil : .infinity
                )

                .padding(isHorizontal ? .vertical : .horizontal, 8)
                .contentShape(.rect)
                .animation(.smooth(duration: 0.15), value: isHovering)
                
                // Expand the container of the button to maintain hover state
                .frame(
                    width: isHorizontal ? nil : ActionPanelContent.buttonWidth * 2,
                    height: isHorizontal ? ActionPanelContent.buttonHeight * 2 : nil,
                    alignment: isHorizontal ? .top : .trailing
                )
                // Offset the context action button
                .offset(
                    x: isHorizontal ? 0 : -ActionPanelContent.buttonWidth,
                    y: isHorizontal ? ActionPanelContent.buttonHeight : 0
                )
                .transition(
                    .blurTransition(
                        blurRadius: 4,
                        xOffset: isHorizontal ? 0 : 40,
                        yOffset: isHorizontal ? -32 : 0,
                        anchor: isHorizontal ? .top : .trailing
                    )
                )
            }
        }
        
        struct KeyboardShortcutPill: View {
            let workspaceId: UUID
            let workspace: Workspace
            let onPress: () -> Void
            @State private var isHovering: Bool = false
            
            var body: some View {
                Button(action: onPress) {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard")
                            .font(brand: Font.brandBody(size: 12))
                        
                        if let shortcut = KeyboardShortcuts.getShortcut(for: .workspace(workspaceId)) {
                            Text(shortcut.description)
                        } else {
                            Text("Set")
                        }
                    }
                    .font(brand: .label4)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .padding(4)
                    .padding(.horizontal, 4)
                    .background {
                        BKGD(isHovering: isHovering)
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 1.5)
                            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
                    }
                    .padding(4)
                    .onHover { isHovering = $0 }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .frame(
                    width: ActionPanelContent.buttonWidth * 2,
                    height: ActionPanelContent.buttonHeight * 2,
                    alignment: .bottom
                )
                .padding(.bottom, 4)
                .offset(y: ActionPanelContent.buttonHeight - 8)
                .transition(
                    .blurTransition(
                        blurRadius: 4,
                        yOffset: -32,
                        anchor: .bottom
                    )
                )
                .animation(.smooth(duration: 0.15), value: isHovering)
            }
        }
        
        struct BKGD: View {
            
            let radius: CGFloat = 24
            let isHovering: Bool
            var isAccentSelected: Bool = false
            
            var body: some View {
                VStack {
                    if #available(macOS 26.0, *) {
                        RoundedRectangle(cornerRadius: radius)
                            .glassEffect(.regular, in: .rect(cornerRadius: radius))
                            .overlay {
                                RoundedRectangle(cornerRadius: radius)
                                    .stroke(
                                        isAccentSelected
                                            ? DesignTokens.Brand.accent.opacity(0.9)
                                            : DesignTokens.Border.prominent.opacity(isHovering ? 0.7 : 0.0),
                                        lineWidth: isAccentSelected ? 2 : 1
                                    )
                            }
                            .overlay {
                                if isAccentSelected {
                                    RoundedRectangle(cornerRadius: radius)
                                        .fill(DesignTokens.Brand.accentMuted.opacity(0.9))
                                }
                            }
                            .brightness(isAccentSelected ? -0.05 : (isHovering ? -0.15 : 0.0))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: radius)
                                .fill(.thinMaterial)

                            if isAccentSelected {
                                RoundedRectangle(cornerRadius: radius)
                                    .fill(DesignTokens.Brand.accentMuted)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: radius)
                                .stroke(
                                    isAccentSelected
                                        ? DesignTokens.Brand.accent.opacity(0.9)
                                        : .white.opacity(isHovering ? 0.4 : 0.3),
                                    style: .init(lineWidth: isAccentSelected ? 2 : 1)
                                )
                        }
                        .brightness(isAccentSelected ? -0.02 : (isHovering ? -0.08 : 0.0))
                    }
                }
                .preferredColorScheme(.dark)
                .animation(.smooth(duration: 0.15), value: isHovering)
                .animation(.smooth(duration: 0.15), value: isAccentSelected)
            }
        }
        
    }
    
    struct MenuIconView: View {
        let icon: MenuItem.MenuIcon
        let size: CGFloat
        
        var body: some View {
            VStack {
                switch icon.type {
                case .systemImage: Image(systemName: icon.value)
                case .emoji: Text(icon.value)
                case .custom: Image(icon.value)
                }
            }
            .font(
                .system(
                    size: icon.type == .emoji ? size * 0.9 : size,
                    weight: .light
                )
            )
        }
    }
    
}

struct WorkspaceIconPreviewData {
    let icons: [WorkspaceIconModel]
    let extraCount: Int
}

struct WorkspaceIconModel: Identifiable {
    let id: String
    let image: NSImage?
    let fallbackName: String
    
    var displayName: String {
        fallbackName.isEmpty ? "App" : fallbackName
    }
}

struct WorkspaceCompactIconRow: View {
    let preview: WorkspaceIconPreviewData
    
    private static let spacing: CGFloat = 6
    
    private var slotCount: Int {
        preview.icons.count + (preview.extraCount > 0 ? 1 : 0)
    }
    
    private var iconSize: CGFloat {
        let totalSpacing = CGFloat(max(slotCount - 1, 0)) * Self.spacing
        let availableWidth = ActionPanelContent.buttonWidth - 12
        let calculated = (availableWidth - totalSpacing) / CGFloat(max(slotCount, 1))
        return max(14, min(24, calculated))
    }
    
    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(preview.icons) { icon in
                WorkspaceCompactAppIconView(icon: icon, size: iconSize)
            }
            
            if preview.extraCount > 0 {
                Text("+\(preview.extraCount)")
                    .font(brand: Font.brandHeading(size: Double(iconSize * 0.45)))
                    .foregroundStyle(DesignTokens.Text.primary)
                    .frame(width: iconSize, height: iconSize)
                    .background {
                        RoundedRectangle(cornerRadius: iconSize * 0.3)
                            .fill(Color.white.opacity(0.2))
                    }
            }
        }
        .opacity(0.8)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

struct WorkspaceCompactAppIconView: View {
    let icon: WorkspaceIconModel
    let size: CGFloat
    
    var body: some View {
        Group {
            if let image = icon.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(String(icon.displayName.prefix(1)).uppercased())
                    .font(brand: Font.brandHeading(size: Double(size * 0.45)))
                    .foregroundStyle(DesignTokens.Text.primary)
            }
        }
        .frame(width: size, height: size)
        .background {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(Color.white.opacity(0.18))
        }
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
    }
}

extension ActionPanelContent {
    struct ExpandCloseButton: View {

        let isExpanded: Bool
        let toggleExpansion: () -> Void
        let deselectSections: () -> Void
        @State private var isHovering: Bool = false
        @State private var didExpand: Bool = false

        private var scale: CGFloat {
            isHovering ? (isExpanded ? 1 : Self.hoverScale) : 1
        }

        private var buttonWidth: CGFloat {
            isExpanded ? Self.expandedWidth : Self.compactWidth
        }

        private var buttonHeight: CGFloat {
            isExpanded ? ActionPanelContent.buttonHeight : Self.compactHeight
        }

        var body: some View {
            Button(action: {
                DeskJigLog.info(.app, "ExpandCloseButton pressed")
                toggleExpansion()
            }) {
                PanelButton.BKGD(isHovering: isHovering)
                    .overlay {
                        if didExpand {
                            // Show X when expanded
                            Image(systemName: "xmark")
                                .font(brand: Font.brandBody(size: 20))
                                .foregroundStyle(DesignTokens.Text.primary)
                                .transition(
                                    .blurTransition(blurRadius: 4, yOffset: 0, scale: 0, anchor: .bottom)
                                    .animation(.smooth(duration: 0.2))
                                )
                        }
                    }
            }
            .buttonStyle(.plain)
            .frame(width: buttonWidth, height: buttonHeight)
            .frame(width: Self.expandedWidth)
            .shadow(color: .black.opacity(0.1), radius: 4, y: 1.5)
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
            .scaleEffect(scale)
            .onHover { nowIsHovering in
                isHovering = nowIsHovering
                if nowIsHovering {
                    deselectSections()
                }
            }
            .animation(.bouncy(duration: 0.25, extraBounce: 0.15), value: scale)
            .animation(.bouncy(duration: 0.4), value: buttonWidth)
            .animation(.bouncy(duration: 0.4), value: buttonHeight)
            .onAppear {
                didExpand = isExpanded
            }
            .onChange(of: isExpanded) {
                if isExpanded {
                    MainActor.async(after: .seconds(0.05)) {
                        didExpand = true
                    }
                } else {
                    didExpand = false
                }
            }
        }
    }
}

// MARK: - Size Constants
extension ActionPanelContent {
    /// Width of button when expanded.
    static let buttonWidth: CGFloat = 100
    /// Height of button when expanded.
    static let buttonHeight: CGFloat = 80
    /// Spacing b/w buttons
    static let buttonSpacing: CGFloat = 8
    /// Number of buttons when expanded - Marco, this will need to be dynamically computed later
    static let buttonCount: CGFloat = 5
    /// The padding between the controls and the panel's frame/bkgd. No bkgd currently.
    static let padding: CGFloat = 6
    static let expandedWidth: CGFloat = (buttonWidth * PanelButton.hoverScale) + (padding * 2)
    static let expandedHeight: CGFloat = buttonCount * (buttonHeight + buttonSpacing) - buttonSpacing + (padding * 2)
    static let compactWidth: CGFloat = (ExpandCloseButton.compactWidth * ExpandCloseButton.hoverScale) + (padding * 2)
    static let compactHeight: CGFloat = (ExpandCloseButton.compactHeight * ExpandCloseButton.hoverScale) + (padding * 2)
}

extension ActionPanelContent.ExpandCloseButton {
    static let compactWidth: CGFloat = 64
    static let expandedWidth: CGFloat = ActionPanelContent.buttonWidth
    static let compactHeight: CGFloat = 12
    static let expandedHeight: CGFloat = ActionPanelContent.buttonHeight
    static let hoverScale: CGFloat = 1.2
}

extension ActionPanelContent.PanelButton {
    static let hoverScale: CGFloat = (ActionPanelContent.buttonWidth + 8) / ActionPanelContent.buttonWidth
}

