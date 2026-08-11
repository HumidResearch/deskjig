import AppKit
import Combine
import SwiftUI

public final class FolderTabCoordinator {
    private struct MemberState {
        let workspaceWindow: WorkspaceWindow
        var windowInfo: WindowInfo
    }

    private struct GroupState {
        let id: UUID
        var members: [MemberState]
        var activeWorkspaceWindowID: UUID
        var slotFrame: CGRect
        var contentFrame: CGRect
    }

    private final class FolderStripWindow: NSPanel {
        var onDragStarted: (() -> Void)?
        var onDragMove: ((CGRect) -> Void)?
        var onDragEnded: (() -> Void)?

        private var initialMouseScreenLocation: NSPoint?
        private var initialWindowOrigin: NSPoint?
        private var hasDragged = false

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        override func mouseDown(with event: NSEvent) {
            initialMouseScreenLocation = NSEvent.mouseLocation
            initialWindowOrigin = frame.origin
            hasDragged = false
            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let initialMouse = initialMouseScreenLocation,
                  let initialOrigin = initialWindowOrigin else {
                super.mouseDragged(with: event)
                return
            }

            let current = NSEvent.mouseLocation
            let newOrigin = NSPoint(
                x: initialOrigin.x + (current.x - initialMouse.x),
                y: initialOrigin.y + (current.y - initialMouse.y)
            )

            if !hasDragged {
                hasDragged = true
                onDragStarted?()
            }

            setFrameOrigin(newOrigin)
            onDragMove?(frame)
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            if hasDragged {
                onDragEnded?()
            }
            initialMouseScreenLocation = nil
            initialWindowOrigin = nil
            hasDragged = false
        }
    }

    private weak var windowManager: WindowManager?
    private let displayManager: DisplayManager
    private var groups: [UUID: GroupState] = [:]
    private var stripWindows: [UUID: FolderStripWindow] = [:]
    private var windowsSubscription: AnyCancellable?
    private var isApplyingSelection = false
    private var draggingGroupIDs: Set<UUID> = []
    private var dragOriginStripFrames: [UUID: CGRect] = [:]
    private var settleRefreshWorkItems: [DispatchWorkItem] = []
    private var selectionResetWorkItem: DispatchWorkItem?

    private let stripHeight: CGFloat = FolderTabStripView.preferredHeight
    private let stripSpacing: CGFloat = 0
    private let minimumContentHeight: CGFloat = 80
    private let frameTolerance: CGFloat = 2

    public init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    public func setWindowManager(_ windowManager: WindowManager) {
        self.windowManager = windowManager
        windowsSubscription = windowManager.$windows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windows in
                Task { @MainActor [weak self] in
                    self?.handleWindowSnapshot(windows)
                }
            }
    }

    @MainActor
    public func clear() {
        stopMonitoring()
        for window in stripWindows.values {
            window.orderOut(nil)
        }
        stripWindows.removeAll()
        groups.removeAll()
        draggingGroupIDs.removeAll()
        dragOriginStripFrames.removeAll()
    }

    public func managesLiveWindow(_ windowID: Int) -> Bool {
        MainActor.assumeIsolated {
            groupID(containingLiveWindowID: windowID) != nil
        }
    }

    @discardableResult
    public func beginMemberDrag(windowID: Int) -> Bool {
        MainActor.assumeIsolated {
            guard let groupID = groupID(containingLiveWindowID: windowID),
                  var group = groups[groupID],
                  let workspaceWindowID = workspaceWindowID(forLiveWindowID: windowID, in: group) else {
                return false
            }

            group.activeWorkspaceWindowID = workspaceWindowID
            groups[groupID] = group
            beginGroupDrag(groupID: groupID, captureStripOrigin: false)
            updateStripWindow(for: groupID)
            return true
        }
    }

    public func updateMemberDrag(windowID: Int, frame: CGRect) {
        MainActor.assumeIsolated {
            guard let groupID = groupID(containingLiveWindowID: windowID),
                  var group = groups[groupID],
                  let workspaceWindowID = workspaceWindowID(forLiveWindowID: windowID, in: group) else {
                return
            }

            if !draggingGroupIDs.contains(groupID) {
                _ = beginMemberDrag(windowID: windowID)
                guard let refreshedGroup = groups[groupID] else { return }
                group = refreshedGroup
            }

            group.activeWorkspaceWindowID = workspaceWindowID
            group.contentFrame = frame
            group.slotFrame = slotFrame(for: frame)
            DeskJigLog.info(.workspace, "FOLDER-DIAG: member drag update", fields: [
                "groupID": groupID.uuidString,
                "windowID": windowID,
                "workspaceWindowID": workspaceWindowID.uuidString,
                "frame": frame.debugDescription,
                "slotFrame": group.slotFrame.debugDescription
            ])
            updateMemberFrames(in: &group, targetContentFrame: frame)
            groups[groupID] = group
            updateStripWindow(for: groupID)
        }
    }

    public func endMemberDrag(windowID: Int, finalFrame: CGRect? = nil) {
        MainActor.assumeIsolated {
            if let finalFrame {
                updateMemberDrag(windowID: windowID, frame: finalFrame)
            }

            guard let groupID = groupID(containingLiveWindowID: windowID) else {
                return
            }

            endGroupDrag(groupID: groupID, refreshDelays: [0.05, 0.2])
        }
    }

    @MainActor
    public func configure(
        workspace: Workspace,
        result: FluentRestorationResult
    ) async {
        clear()

        guard workspace.windows.contains(where: { $0.folderGroupID != nil }),
              let windowManager else {
            return
        }

        await refreshWindows()

        let currentWindowsByID = Dictionary(uniqueKeysWithValues: windowManager.windows.map { ($0.id, $0) })
        let tasksByID = Dictionary(uniqueKeysWithValues: result.plan.tasks.map { ($0.id, $0) })
        var groupedMembers: [UUID: [MemberState]] = [:]
        var groupedSlotFrames: [UUID: CGRect] = [:]

        for taskResult in result.taskResults where taskResult.success {
            guard let task = tasksByID[taskResult.taskId],
                  let folderGroupID = task.workspaceWindow.folderGroupID else {
                continue
            }

            DeskJigLog.debug(.workspace, "FOLDER-DIAG: evaluating restored member", fields: [
                "groupID": folderGroupID.uuidString,
                "taskId": taskResult.taskId,
                "workspaceWindowID": task.workspaceWindow.id.uuidString,
                "appName": task.workspaceWindow.appName,
                "windowTitle": task.workspaceWindow.windowTitle,
                "folderOrder": task.workspaceWindow.folderOrder ?? -1,
                "targetFrame": "\(task.decision.targetFrame?.debugDescription ?? "nil")",
                "windowId": taskResult.windowId.map(String.init) ?? "nil",
                "plannedWindowId": taskResult.plannedWindowId.map(String.init) ?? "nil",
                "existingWindowId": task.decision.existingWindowId.map(String.init) ?? "nil"
            ], runId: result.runId)

            guard let resolvedWindowInfo = resolvedWindowInfo(
                for: task,
                taskResult: taskResult,
                currentWindowsByID: currentWindowsByID,
                allCurrentWindows: windowManager.windows
            ) else {
                continue
            }

            let resolvedDisplayID = displayManager.getBestScreen(for: resolvedWindowInfo.frame)?.displayID ?? -1
            DeskJigLog.info(.workspace, "FOLDER-DIAG: resolved live member", fields: [
                "groupID": folderGroupID.uuidString,
                "workspaceWindowID": task.workspaceWindow.id.uuidString,
                "resolvedWindowID": resolvedWindowInfo.id,
                "resolvedDisplayID": resolvedDisplayID,
                "resolvedFrame": resolvedWindowInfo.frame.debugDescription,
                "resolvedTitle": resolvedWindowInfo.windowTitle
            ], runId: result.runId)

            groupedMembers[folderGroupID, default: []].append(
                MemberState(
                    workspaceWindow: task.workspaceWindow,
                    windowInfo: resolvedWindowInfo
                )
            )
            if groupedSlotFrames[folderGroupID] == nil {
                groupedSlotFrames[folderGroupID] = task.decision.targetFrame ?? slotFrame(for: resolvedWindowInfo.frame)
            }
        }

        for (groupID, members) in groupedMembers {
            let orderedMembers = members
                .uniqued(by: \.workspaceWindow.id)
                .sorted { lhs, rhs in
                    let lhsOrder = lhs.workspaceWindow.folderOrder ?? Int.max
                    let rhsOrder = rhs.workspaceWindow.folderOrder ?? Int.max
                    if lhsOrder != rhsOrder {
                        return lhsOrder < rhsOrder
                    }
                    return lhs.workspaceWindow.id.uuidString < rhs.workspaceWindow.id.uuidString
                }

            guard orderedMembers.count > 1,
                  let firstMember = orderedMembers.first else {
                continue
            }

            let slotFrame = groupedSlotFrames[groupID] ?? slotFrame(for: firstMember.windowInfo.frame)
            guard let contentFrame = contentFrame(for: slotFrame) else {
                continue
            }

            DeskJigLog.info(.workspace, "FOLDER-DIAG: configured folder group", fields: [
                "groupID": groupID.uuidString,
                "memberCount": orderedMembers.count,
                "slotFrame": slotFrame.debugDescription,
                "contentFrame": contentFrame.debugDescription,
                "slotDisplayID": displayManager.getBestScreen(for: slotFrame)?.displayID ?? -1,
                "activeWorkspaceWindowID": firstMember.workspaceWindow.id.uuidString
            ], runId: result.runId)

            groups[groupID] = GroupState(
                id: groupID,
                members: orderedMembers,
                activeWorkspaceWindowID: firstMember.workspaceWindow.id,
                slotFrame: slotFrame,
                contentFrame: contentFrame
            )
            ensureStripWindow(for: groupID)
        }

        guard !groups.isEmpty else { return }

        for (groupID, group) in groups {
            applySelection(
                groupID: groupID,
                workspaceWindowID: group.activeWorkspaceWindowID,
                contentFrame: group.contentFrame
            )
        }

        startMonitoring()
    }

    @MainActor
    private func handleWindowSnapshot(_ currentWindows: [WindowInfo]) {
        guard !groups.isEmpty, !isApplyingSelection else { return }

        let currentWindowsByID = Dictionary(uniqueKeysWithValues: currentWindows.map { ($0.id, $0) })
        var dissolvedGroupIDs: [UUID] = []

        for groupID in groups.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var group = groups[groupID] else { continue }

            group.members = group.members.compactMap { member in
                guard let updatedWindowInfo = currentWindowsByID[member.windowInfo.id] else {
                    return nil
                }

                var updatedMember = member
                updatedMember.windowInfo = updatedWindowInfo
                return updatedMember
            }

            guard group.members.count > 1 else {
                groups[groupID] = group
                dissolvedGroupIDs.append(groupID)
                continue
            }

            if draggingGroupIDs.contains(groupID) {
                groups[groupID] = group
                continue
            }

            if !group.members.contains(where: { $0.workspaceWindow.id == group.activeWorkspaceWindowID }),
               let fallbackMember = group.members.first {
                group.activeWorkspaceWindowID = fallbackMember.workspaceWindow.id
                let normalizedContentFrame = canonicalContentFrame(
                    observedFrame: fallbackMember.windowInfo.frame,
                    slotFrame: group.slotFrame
                ) ?? group.contentFrame
                group.contentFrame = normalizedContentFrame
                DeskJigLog.info(.workspace, "FOLDER-DIAG: active member missing, falling back", fields: [
                    "groupID": groupID.uuidString,
                    "fallbackWorkspaceWindowID": fallbackMember.workspaceWindow.id.uuidString,
                    "fallbackFrame": fallbackMember.windowInfo.frame.debugDescription,
                    "normalizedContentFrame": normalizedContentFrame.debugDescription
                ])
            }

            let activeMember = group.members.first(where: { $0.workspaceWindow.id == group.activeWorkspaceWindowID })
            let isActiveMemberVisible = activeMember.map { !$0.windowInfo.isHidden && !$0.windowInfo.isMinimized } ?? false

            if !isActiveMemberVisible,
               let frontmostVisibleMember = group.members
                .filter({ !$0.windowInfo.isHidden && !$0.windowInfo.isMinimized })
                .min(by: { $0.windowInfo.windowLevel < $1.windowInfo.windowLevel }),
               frontmostVisibleMember.workspaceWindow.id != group.activeWorkspaceWindowID {
                DeskJigLog.info(.workspace, "FOLDER-DIAG: switching active member from frontmost visible window", fields: [
                    "groupID": groupID.uuidString,
                    "workspaceWindowID": frontmostVisibleMember.workspaceWindow.id.uuidString,
                    "frame": frontmostVisibleMember.windowInfo.frame.debugDescription,
                    "displayID": displayManager.getBestScreen(for: frontmostVisibleMember.windowInfo.frame)?.displayID ?? -1
                ])
                let selectedContentFrame = canonicalContentFrame(
                    observedFrame: frontmostVisibleMember.windowInfo.frame,
                    slotFrame: group.slotFrame
                ) ?? group.contentFrame
                groups[groupID] = group
                applySelection(
                    groupID: groupID,
                    workspaceWindowID: frontmostVisibleMember.workspaceWindow.id,
                    contentFrame: selectedContentFrame
                )
                continue
            }

            if let activeMember,
               activeMember.windowInfo.frame != group.contentFrame {
                if let canonicalFrame = canonicalContentFrame(
                    observedFrame: activeMember.windowInfo.frame,
                    slotFrame: group.slotFrame
                ) {
                    if !frameMatches(activeMember.windowInfo.frame, canonicalFrame) {
                        DeskJigLog.warn(.workspace, "FOLDER-DIAG: active member lost folder inset, reapplying content frame", fields: [
                            "groupID": groupID.uuidString,
                            "workspaceWindowID": group.activeWorkspaceWindowID.uuidString,
                            "slotFrame": group.slotFrame.debugDescription,
                            "observedFrame": activeMember.windowInfo.frame.debugDescription,
                            "canonicalFrame": canonicalFrame.debugDescription
                        ])
                        groups[groupID] = group
                        applySelection(
                            groupID: groupID,
                            workspaceWindowID: group.activeWorkspaceWindowID,
                            contentFrame: canonicalFrame
                        )
                        continue
                    }
                    group.contentFrame = canonicalFrame
                    groups[groupID] = group
                } else {
                    DeskJigLog.info(.workspace, "FOLDER-DIAG: active member frame changed, adopting new content frame", fields: [
                        "groupID": groupID.uuidString,
                        "workspaceWindowID": group.activeWorkspaceWindowID.uuidString,
                        "oldContentFrame": group.contentFrame.debugDescription,
                        "newContentFrame": activeMember.windowInfo.frame.debugDescription,
                        "newDisplayID": displayManager.getBestScreen(for: activeMember.windowInfo.frame)?.displayID ?? -1
                    ])
                    group.contentFrame = activeMember.windowInfo.frame
                    group.slotFrame = slotFrame(for: activeMember.windowInfo.frame)
                    updateMemberFrames(in: &group, targetContentFrame: group.contentFrame)
                    groups[groupID] = group
                    syncLiveMembers(
                        for: groupID,
                        contentFrame: group.contentFrame,
                        activeWorkspaceWindowID: group.activeWorkspaceWindowID,
                        moveActiveWindow: false,
                        activateActiveWindow: false
                    )
                }
            } else {
                if group.members.contains(where: { !frameMatches($0.windowInfo.frame, group.contentFrame) }) {
                    updateMemberFrames(in: &group, targetContentFrame: group.contentFrame)
                    groups[groupID] = group
                    syncLiveMembers(
                        for: groupID,
                        contentFrame: group.contentFrame,
                        activeWorkspaceWindowID: group.activeWorkspaceWindowID,
                        moveActiveWindow: false,
                        activateActiveWindow: false
                    )
                }
                groups[groupID] = group
            }

            updateStripWindow(for: groupID)
        }

        for groupID in dissolvedGroupIDs {
            dissolveGroup(groupID, showRemainingWindow: true)
        }
    }

    @MainActor
    private func applySelection(
        groupID: UUID,
        workspaceWindowID: UUID,
        contentFrame: CGRect
    ) {
        guard var group = groups[groupID],
              let windowManager,
              group.members.contains(where: { $0.workspaceWindow.id == workspaceWindowID }) else {
            return
        }

        isApplyingSelection = true
        defer {
            scheduleSelectionSettleRefreshes()
        }

        group.activeWorkspaceWindowID = workspaceWindowID
        let targetSlotFrame = group.slotFrame
        let targetContentFrame = canonicalContentFrame(
            observedFrame: contentFrame,
            slotFrame: targetSlotFrame
        ) ?? contentFrame
        group.contentFrame = targetContentFrame
        group.slotFrame = targetSlotFrame
        updateMemberFrames(in: &group, targetContentFrame: targetContentFrame)
        groups[groupID] = group

        DeskJigLog.info(.workspace, "FOLDER-DIAG: apply selection", fields: [
            "groupID": groupID.uuidString,
            "workspaceWindowID": workspaceWindowID.uuidString,
            "contentFrame": targetContentFrame.debugDescription,
            "slotFrame": group.slotFrame.debugDescription,
            "contentDisplayID": displayManager.getBestScreen(for: targetContentFrame)?.displayID ?? -1
        ])

        groups[groupID] = group
        syncLiveMembers(
            for: groupID,
            contentFrame: targetContentFrame,
            activeWorkspaceWindowID: workspaceWindowID,
            moveActiveWindow: true,
            activateActiveWindow: true
        )
        updateStripWindow(for: groupID)
        stripWindows[groupID]?.orderFrontRegardless()
    }

    @MainActor
    private func syncLiveMembers(
        for groupID: UUID,
        contentFrame: CGRect,
        activeWorkspaceWindowID: UUID,
        moveActiveWindow: Bool,
        activateActiveWindow: Bool
    ) {
        guard var group = groups[groupID],
              let windowManager else {
            return
        }

        let commands = FolderTabPlanner.makeLiveStackCommands(
            members: group.members.map {
                FolderTabPlanner.MemberCommandInput(
                    workspaceWindowID: $0.workspaceWindow.id,
                    liveWindowID: $0.windowInfo.id,
                    folderOrder: $0.workspaceWindow.folderOrder
                )
            },
            activeWorkspaceWindowID: activeWorkspaceWindowID,
            targetFrame: contentFrame,
            moveActiveWindow: moveActiveWindow,
            activateActiveWindow: activateActiveWindow
        )

        for command in commands {
            guard let member = group.members.first(where: { $0.workspaceWindow.id == command.workspaceWindowID }) else {
                continue
            }

            DeskJigLog.debug(.workspace, "FOLDER-DIAG: syncing live member", fields: [
                "groupID": groupID.uuidString,
                "workspaceWindowID": member.workspaceWindow.id.uuidString,
                "liveWindowID": member.windowInfo.id,
                "targetFrame": contentFrame.debugDescription,
                "isActive": member.workspaceWindow.id == activeWorkspaceWindowID,
                "moveActiveWindow": moveActiveWindow,
                "activateActiveWindow": activateActiveWindow,
                "shouldHideWindow": command.shouldHideWindow
            ])

            if !command.shouldHideWindow {
                let _ = windowManager.unhideWindow(windowInfo: member.windowInfo)
                let _ = windowManager.restoreWindow(windowInfo: member.windowInfo)
            }

            if command.shouldMoveWindow {
                let _ = windowManager.moveWindowToFrame(windowInfo: member.windowInfo, targetFrame: contentFrame)
            }

            if command.shouldHideWindow {
                let _ = windowManager.hideWindow(windowInfo: member.windowInfo)
            }

            if command.shouldActivateWindow {
                let _ = windowManager.activateWindow(windowInfo: member.windowInfo)
            }
        }

        updateMemberFrames(in: &group, targetContentFrame: contentFrame)
        groups[groupID] = group
    }

    @MainActor
    private func dissolveGroup(_ groupID: UUID, showRemainingWindow: Bool) {
        guard let group = groups[groupID] else { return }

        if showRemainingWindow,
           let remainingMember = group.members.first,
           let windowManager {
            let _ = windowManager.moveWindowToFrame(windowInfo: remainingMember.windowInfo, targetFrame: group.slotFrame)
            let _ = windowManager.restoreWindow(windowInfo: remainingMember.windowInfo)
        }

        if let stripWindow = stripWindows[groupID] {
            stripWindow.orderOut(nil)
            stripWindows.removeValue(forKey: groupID)
        }
        groups.removeValue(forKey: groupID)

        if groups.isEmpty {
            stopMonitoring()
        }
    }

    @MainActor
    private func ensureStripWindow(for groupID: UUID) {
        guard stripWindows[groupID] == nil else {
            updateStripWindow(for: groupID)
            return
        }

        let window = FolderStripWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: stripHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = false
        window.onDragStarted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.beginStripDrag(groupID: groupID)
            }
        }
        window.onDragMove = { [weak self] stripFrame in
            Task { @MainActor [weak self] in
                self?.handleStripDrag(groupID: groupID, stripFrame: stripFrame)
            }
        }
        window.onDragEnded = { [weak self] in
            Task { @MainActor [weak self] in
                self?.endStripDrag(groupID: groupID)
            }
        }
        stripWindows[groupID] = window
        updateStripWindow(for: groupID)
        window.orderFrontRegardless()
    }

    @MainActor
    private func updateStripWindow(for groupID: UUID) {
        guard let group = groups[groupID],
              let stripWindow = stripWindows[groupID] else {
            return
        }

        let frame = stripFrame(for: group.slotFrame)
        DeskJigLog.debug(.workspace, "FOLDER-DIAG: update strip window", fields: [
            "groupID": groupID.uuidString,
            "slotFrame": group.slotFrame.debugDescription,
            "contentFrame": group.contentFrame.debugDescription,
            "stripFrame": frame.debugDescription,
            "anchorY": displayManager.windowCoordinateAnchorY
        ])
        stripWindow.setFrame(frame, display: true)
        stripWindow.contentView = NSHostingView(
            rootView: FolderTabStripView(
                members: group.members.map {
                    FolderTabStripView.MemberPresentation(
                        id: $0.workspaceWindow.id,
                        displayName: stripLabel(
                            appName: $0.workspaceWindow.appName,
                            title: $0.workspaceWindow.windowTitle
                        ),
                        icon: appIcon(for: $0.workspaceWindow.bundleIdentifier)
                    )
                },
                activeID: group.activeWorkspaceWindowID,
                onSelect: { [weak self] workspaceWindowID in
                    guard let self else { return }
                    let contentFrame = self.groups[groupID]?.contentFrame ?? .zero
                    DeskJigLog.info(.workspace, "FOLDER-DIAG: strip tab selected", fields: [
                        "groupID": groupID.uuidString,
                        "workspaceWindowID": workspaceWindowID.uuidString,
                        "contentFrame": contentFrame.debugDescription
                    ])
                    self.applySelection(
                        groupID: groupID,
                        workspaceWindowID: workspaceWindowID,
                        contentFrame: contentFrame
                    )
                }
            )
        )
    }

    @MainActor
    private func stripFrame(for slotFrame: CGRect) -> CGRect {
        displayManager.refreshScreens()
        let cocoaY = displayManager.windowCoordinateAnchorY - slotFrame.origin.y - stripHeight
        return CGRect(
            x: slotFrame.origin.x,
            y: cocoaY,
            width: max(220, slotFrame.width),
            height: stripHeight
        )
    }

    @MainActor
    private func beginGroupDrag(groupID: UUID, captureStripOrigin: Bool) {
        let isFreshDrag = !draggingGroupIDs.contains(groupID)
        draggingGroupIDs.insert(groupID)
        cancelScheduledRefreshes()

        if captureStripOrigin,
           dragOriginStripFrames[groupID] == nil,
           let stripFrame = stripWindows[groupID]?.frame {
            dragOriginStripFrames[groupID] = stripFrame
        }

        if isFreshDrag, let group = groups[groupID] {
            hideInactiveMembers(in: group)
        }
    }

    @MainActor
    private func hideInactiveMembers(in group: GroupState) {
        guard let windowManager else { return }
        for member in group.members where member.workspaceWindow.id != group.activeWorkspaceWindowID {
            let _ = windowManager.hideWindow(windowInfo: member.windowInfo)
        }
    }

    @MainActor
    private func moveActiveMember(in group: inout GroupState, to contentFrame: CGRect) {
        guard let windowManager,
              let activeMember = group.members.first(where: { $0.workspaceWindow.id == group.activeWorkspaceWindowID }) else {
            return
        }
        let _ = windowManager.moveWindowToFrame(windowInfo: activeMember.windowInfo, targetFrame: contentFrame)
    }

    @MainActor
    private func endGroupDrag(groupID: UUID, refreshDelays: [TimeInterval]) {
        draggingGroupIDs.remove(groupID)
        dragOriginStripFrames.removeValue(forKey: groupID)
        scheduleRefreshes(after: refreshDelays)
    }

    @MainActor
    private func updateMemberFrames(in group: inout GroupState, targetContentFrame: CGRect) {
        for index in group.members.indices {
            group.members[index].windowInfo.frame = targetContentFrame
        }
    }

    private func groupID(containingLiveWindowID windowID: Int) -> UUID? {
        groups.first { _, group in
            group.members.contains(where: { $0.windowInfo.id == windowID })
        }?.key
    }

    private func workspaceWindowID(forLiveWindowID windowID: Int, in group: GroupState) -> UUID? {
        group.members.first(where: { $0.windowInfo.id == windowID })?.workspaceWindow.id
    }

    @MainActor
    private func beginStripDrag(groupID: UUID) {
        beginGroupDrag(groupID: groupID, captureStripOrigin: true)
    }

    @MainActor
    private func handleStripDrag(groupID: UUID, stripFrame: CGRect) {
        guard var group = groups[groupID] else {
            return
        }

        let nextSlotFrame = slotFrame(fromStripFrame: stripFrame, preserving: group.slotFrame)
        guard let nextContentFrame = contentFrame(for: nextSlotFrame) else {
            return
        }

        DeskJigLog.info(.workspace, "FOLDER-DIAG: strip drag frame conversion", fields: [
            "groupID": groupID.uuidString,
            "incomingStripFrame": stripFrame.debugDescription,
            "previousSlotFrame": group.slotFrame.debugDescription,
            "nextSlotFrame": nextSlotFrame.debugDescription,
            "nextContentFrame": nextContentFrame.debugDescription,
            "anchorY": displayManager.windowCoordinateAnchorY
        ])

        group.slotFrame = nextSlotFrame
        group.contentFrame = nextContentFrame
        updateMemberFrames(in: &group, targetContentFrame: nextContentFrame)
        moveActiveMember(in: &group, to: nextContentFrame)
        groups[groupID] = group
    }

    @MainActor
    private func endStripDrag(groupID: UUID) {
        if let group = groups[groupID] {
            syncLiveMembers(
                for: groupID,
                contentFrame: group.contentFrame,
                activeWorkspaceWindowID: group.activeWorkspaceWindowID,
                moveActiveWindow: false,
                activateActiveWindow: true
            )
        }
        endGroupDrag(groupID: groupID, refreshDelays: [0.05, 0.2])
    }

    @MainActor
    private func contentFrame(for slotFrame: CGRect) -> CGRect? {
        let inset = stripHeight + stripSpacing
        let nextHeight = slotFrame.height - inset
        guard nextHeight >= minimumContentHeight else {
            return nil
        }
        return CGRect(
            x: slotFrame.origin.x,
            y: slotFrame.origin.y + inset,
            width: slotFrame.width,
            height: nextHeight
        )
    }

    @MainActor
    private func canonicalContentFrame(
        observedFrame: CGRect,
        slotFrame: CGRect
    ) -> CGRect? {
        FolderTabPlanner.canonicalContentFrame(
            observedFrame: observedFrame,
            slotFrame: slotFrame,
            stripHeight: stripHeight,
            stripSpacing: stripSpacing,
            minimumContentHeight: minimumContentHeight,
            frameTolerance: frameTolerance
        )
    }

    @MainActor
    private func slotFrame(for contentFrame: CGRect) -> CGRect {
        FolderTabPlanner.slotFrame(
            for: contentFrame,
            stripHeight: stripHeight,
            stripSpacing: stripSpacing
        )
    }

    @MainActor
    private func slotFrame(fromStripFrame stripFrame: CGRect, preserving slotFrame: CGRect) -> CGRect {
        displayManager.refreshScreens()
        return FolderTabPlanner.slotFrame(
            fromStripFrame: stripFrame,
            preserving: slotFrame,
            anchorY: displayManager.windowCoordinateAnchorY,
            stripHeight: stripHeight,
            stripSpacing: stripSpacing
        )
    }

    @MainActor
    private func resolvedWindowInfo(
        for task: RestorationTask,
        taskResult: TaskResult,
        currentWindowsByID: [Int: WindowInfo],
        allCurrentWindows: [WindowInfo]
    ) -> WindowInfo? {
        let candidateWindowIDs = [
            taskResult.windowId,
            taskResult.plannedWindowId,
            task.decision.existingWindowId,
        ].compactMap { $0 }

        let directCandidates = candidateWindowIDs.compactMap { currentWindowsByID[Int($0)] }
        guard let targetFrame = task.decision.targetFrame else {
            if let fallback = directCandidates.first {
                DeskJigLog.warn(.workspace, "FOLDER-DIAG: no target frame for task, using first direct candidate", fields: [
                    "workspaceWindowID": task.workspaceWindow.id.uuidString,
                    "candidateWindowID": fallback.id,
                    "candidateFrame": fallback.frame.debugDescription
                ])
            }
            return directCandidates.first
        }

        let expectedDisplayID = displayManager.getBestScreen(for: targetFrame)?.displayID

        DeskJigLog.debug(.workspace, "FOLDER-DIAG: resolving candidate window", fields: [
            "workspaceWindowID": task.workspaceWindow.id.uuidString,
            "bundleIdentifier": task.workspaceWindow.bundleIdentifier,
            "expectedTitle": task.workspaceWindow.windowTitle,
            "targetFrame": targetFrame.debugDescription,
            "expectedDisplayID": expectedDisplayID ?? -1,
            "directCandidates": directCandidates.map { "\($0.id):\($0.frame.debugDescription)" }.joined(separator: " | ")
        ])

        if let matchingDirectCandidate = bestCandidate(
            within: directCandidates,
            expectedDisplayID: expectedDisplayID,
            bundleIdentifier: task.workspaceWindow.bundleIdentifier,
            windowTitle: task.workspaceWindow.windowTitle,
            targetFrame: targetFrame
        ) {
            return matchingDirectCandidate
        }

        let bundleCandidates = allCurrentWindows.filter { windowInfo in
            windowInfo.bundleIdentifier == task.workspaceWindow.bundleIdentifier
        }

        if let matchingBundleCandidate = bestCandidate(
            within: bundleCandidates,
            expectedDisplayID: expectedDisplayID,
            bundleIdentifier: task.workspaceWindow.bundleIdentifier,
            windowTitle: task.workspaceWindow.windowTitle,
            targetFrame: targetFrame
        ) {
            return matchingBundleCandidate
        }

        DeskJigLog.warn(.workspace, "FOLDER-DIAG: falling back to first direct candidate after resolution failure", fields: [
            "workspaceWindowID": task.workspaceWindow.id.uuidString,
            "expectedDisplayID": expectedDisplayID ?? -1
        ])
        return directCandidates.first
    }

    @MainActor
    private func bestCandidate(
        within candidates: [WindowInfo],
        expectedDisplayID: Int?,
        bundleIdentifier: String,
        windowTitle: String,
        targetFrame: CGRect
    ) -> WindowInfo? {
        let ranked = candidates
            .filter { candidate in
                guard let expectedDisplayID else { return true }
                return displayManager.getBestScreen(for: candidate.frame)?.displayID == expectedDisplayID
            }
            .sorted { lhs, rhs in
                let lhsScore = candidateScore(lhs, expectedTitle: windowTitle, targetFrame: targetFrame)
                let rhsScore = candidateScore(rhs, expectedTitle: windowTitle, targetFrame: targetFrame)
                if lhsScore != rhsScore {
                    return lhsScore < rhsScore
                }
                return lhs.id < rhs.id
            }

        if !ranked.isEmpty {
            DeskJigLog.debug(.workspace, "FOLDER-DIAG: ranked candidates", fields: [
                "bundleIdentifier": bundleIdentifier,
                "expectedTitle": windowTitle,
                "targetFrame": targetFrame.debugDescription,
                "ranked": ranked.map {
                    "id=\($0.id) display=\(displayManager.getBestScreen(for: $0.frame)?.displayID ?? -1) title=\($0.windowTitle) frame=\($0.frame.debugDescription) score=\(candidateScore($0, expectedTitle: windowTitle, targetFrame: targetFrame))"
                }.joined(separator: " || ")
            ])
        } else {
            DeskJigLog.warn(.workspace, "FOLDER-DIAG: no candidates remained after display filtering", fields: [
                "bundleIdentifier": bundleIdentifier,
                "expectedTitle": windowTitle,
                "expectedDisplayID": expectedDisplayID ?? -1
            ])
        }

        return ranked.first
    }

    private func candidateScore(
        _ candidate: WindowInfo,
        expectedTitle: String,
        targetFrame: CGRect
    ) -> CGFloat {
        let titlePenalty: CGFloat = expectedTitle.isEmpty || candidate.windowTitle == expectedTitle ? 0 : 10_000
        let dx = candidate.frame.origin.x - targetFrame.origin.x
        let dy = candidate.frame.origin.y - targetFrame.origin.y
        let dw = candidate.frame.width - targetFrame.width
        let dh = candidate.frame.height - targetFrame.height
        return titlePenalty + abs(dx) + abs(dy) + abs(dw) + abs(dh)
    }

    private func frameMatches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameTolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= frameTolerance &&
        abs(lhs.width - rhs.width) <= frameTolerance &&
        abs(lhs.height - rhs.height) <= frameTolerance
    }

    @MainActor
    private func appIcon(for bundleIdentifier: String) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    private func stripLabel(appName: String, title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              trimmedTitle.caseInsensitiveCompare(appName) != .orderedSame else {
            return appName
        }

        return "\(appName)  \(trimmedTitle)"
    }

    @MainActor
    private func startMonitoring() {
        stopMonitoring()
        scheduleRefreshes(after: [0.05, 0.2, 0.45])
    }

    @MainActor
    private func stopMonitoring() {
        cancelScheduledRefreshes()
    }

    @MainActor
    private func scheduleSelectionSettleRefreshes() {
        isApplyingSelection = true
        selectionResetWorkItem?.cancel()
        let resetWorkItem = DispatchWorkItem { [weak self] in
            self?.isApplyingSelection = false
        }
        selectionResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: resetWorkItem)
        scheduleRefreshes(after: [0.15, 0.4])
    }

    @MainActor
    private func scheduleRefreshes(after delays: [TimeInterval]) {
        cancelRefreshWorkItems()
        for delay in delays {
            let workItem = DispatchWorkItem { [weak self] in
                self?.windowManager?.refreshWindows()
            }
            settleRefreshWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    @MainActor
    private func cancelScheduledRefreshes() {
        selectionResetWorkItem?.cancel()
        selectionResetWorkItem = nil
        cancelRefreshWorkItems()
    }

    @MainActor
    private func cancelRefreshWorkItems() {
        for workItem in settleRefreshWorkItems {
            workItem.cancel()
        }
        settleRefreshWorkItems.removeAll()
    }

    @MainActor
    private func refreshWindows() async {
        guard let windowManager else { return }
        await withCheckedContinuation { continuation in
            windowManager.refreshWindows {
                continuation.resume()
            }
        }
    }
}

private extension Array {
    func uniqued<Value: Hashable>(by keyPath: KeyPath<Element, Value>) -> [Element] {
        var seen: Set<Value> = []
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

enum FolderTabPlanner {
    struct MemberCommandInput: Equatable {
        let workspaceWindowID: UUID
        let liveWindowID: Int
        let folderOrder: Int?
    }

    struct LiveStackCommand: Equatable {
        let workspaceWindowID: UUID
        let liveWindowID: Int
        let targetFrame: CGRect
        let shouldMoveWindow: Bool
        let shouldActivateWindow: Bool
        let shouldHideWindow: Bool
    }

    static func makeLiveStackCommands(
        members: [MemberCommandInput],
        activeWorkspaceWindowID: UUID,
        targetFrame: CGRect,
        moveActiveWindow: Bool,
        activateActiveWindow: Bool
    ) -> [LiveStackCommand] {
        members
            .sorted { lhs, rhs in
                if lhs.workspaceWindowID == activeWorkspaceWindowID { return false }
                if rhs.workspaceWindowID == activeWorkspaceWindowID { return true }

                let lhsOrder = lhs.folderOrder ?? Int.max
                let rhsOrder = rhs.folderOrder ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.workspaceWindowID.uuidString < rhs.workspaceWindowID.uuidString
            }
            .map { member in
                let isActive = member.workspaceWindowID == activeWorkspaceWindowID
                return LiveStackCommand(
                    workspaceWindowID: member.workspaceWindowID,
                    liveWindowID: member.liveWindowID,
                    targetFrame: targetFrame,
                    shouldMoveWindow: moveActiveWindow || !isActive,
                    shouldActivateWindow: activateActiveWindow && isActive,
                    shouldHideWindow: activateActiveWindow && !isActive
                )
            }
    }

    static func slotFrame(for contentFrame: CGRect, stripHeight: CGFloat, stripSpacing: CGFloat) -> CGRect {
        let inset = stripHeight + stripSpacing
        return CGRect(
            x: contentFrame.origin.x,
            y: contentFrame.origin.y - inset,
            width: contentFrame.width,
            height: contentFrame.height + inset
        )
    }

    static func slotFrame(
        fromStripFrame stripFrame: CGRect,
        preserving slotFrame: CGRect,
        anchorY: CGFloat,
        stripHeight: CGFloat,
        stripSpacing: CGFloat
    ) -> CGRect {
        let _ = stripSpacing
        return CGRect(
            x: stripFrame.origin.x,
            y: anchorY - stripFrame.origin.y - stripHeight,
            width: slotFrame.width,
            height: slotFrame.height
        )
    }

    static func contentFrame(
        for slotFrame: CGRect,
        stripHeight: CGFloat,
        stripSpacing: CGFloat
    ) -> CGRect {
        let inset = stripHeight + stripSpacing
        return CGRect(
            x: slotFrame.origin.x,
            y: slotFrame.origin.y + inset,
            width: slotFrame.width,
            height: max(0, slotFrame.height - inset)
        )
    }

    static func canonicalContentFrame(
        observedFrame: CGRect,
        slotFrame: CGRect,
        stripHeight: CGFloat,
        stripSpacing: CGFloat,
        minimumContentHeight: CGFloat,
        frameTolerance: CGFloat
    ) -> CGRect? {
        let inset = stripHeight + stripSpacing
        guard slotFrame.height - inset >= minimumContentHeight else {
            return nil
        }
        let expectedContentFrame = contentFrame(
            for: slotFrame,
            stripHeight: stripHeight,
            stripSpacing: stripSpacing
        )

        func frameMatches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.origin.x - rhs.origin.x) <= frameTolerance &&
            abs(lhs.origin.y - rhs.origin.y) <= frameTolerance &&
            abs(lhs.width - rhs.width) <= frameTolerance &&
            abs(lhs.height - rhs.height) <= frameTolerance
        }

        if frameMatches(observedFrame, expectedContentFrame) {
            return expectedContentFrame
        }

        if frameMatches(observedFrame, slotFrame) {
            return expectedContentFrame
        }

        let sharesInsetOrigin =
            abs(observedFrame.origin.x - expectedContentFrame.origin.x) <= frameTolerance &&
            abs(observedFrame.origin.y - expectedContentFrame.origin.y) <= frameTolerance &&
            abs(observedFrame.width - expectedContentFrame.width) <= frameTolerance

        if sharesInsetOrigin &&
            abs(observedFrame.height - slotFrame.height) <= frameTolerance {
            return expectedContentFrame
        }

        return nil
    }
}

private struct FolderTabStripView: View {
    static let preferredHeight: CGFloat = 52

    struct MemberPresentation: Identifiable {
        let id: UUID
        let displayName: String
        let icon: NSImage?
    }

    let members: [MemberPresentation]
    let activeID: UUID
    let onSelect: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(members) { member in
                    Button {
                        onSelect(member.id)
                    } label: {
                        HStack(spacing: 8) {
                            if let icon = member.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.8))
                            }

                            Text(member.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(member.id == activeID ? Color.white.opacity(0.22) : Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(member.id == activeID ? Color.white.opacity(0.35) : Color.white.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.84))
        )
        .frame(height: Self.preferredHeight)
    }
}
