//
//  AppDrawerView.swift
//  DeskJig
//
//  Created by Marco Freedom on 04.09.2025.
//

import SwiftUI
import AppKit

struct AppDrawerView: View {
    
    let screenInfo: ScreenInfo
    let windowLayoutManager: WindowLayoutManager?
    @State private var isDropTarget = false
    static let height: CGFloat = 144
    
    var body: some View {
        Group {
            if !screenInfo.windowSnapshots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(screenInfo.windowSnapshots, id: \.id) { snapshot in
                            AppThumbnailView(snapshot: snapshot)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.trailing, 16)
                    .padding(.vertical, 12)
                }
            } else {
                emptyStateView
            }
        }
        .frame(height: Self.height)
        .onDrop(of: [.utf8PlainText], isTargeted: $isDropTarget) { providers in
            DeskJigLog.debug(.app, "AppDrawerView: Drop detected on screen indicators")
            
            // Get the dragged snapshot from the global manager
            guard let draggedSnapshot = DragDropManager.shared.draggedSnapshot else {
                DeskJigLog.debug(.app, "AppDrawerView: No dragged snapshot found")
                return false
            }
            
            DeskJigLog.debug(.app, "AppDrawerView: Processing drop for window '\(draggedSnapshot.windowInfo.windowTitle)'")
            
            // Note: Window drop handling is deprecated - zones are now visual helpers only
            // Users should position windows by dragging them into snap-assist zones
            
            return false
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.15))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDropTarget ? DesignTokens.Brand.accent.opacity(0.3) : Color.clear)
                        .animation(.easeInOut(duration: 0.2), value: isDropTarget)
                }
        )
    }
    
    private var emptyStateView: some View {
        VStack {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.5))
            
            Text("Drop windows here")
                .font(.title3)
                .foregroundColor(.white.opacity(0.7))
            
            Text("Drag from layout zones to unassign")
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: 325)
        .padding(24)
    }
}

#Preview {
    EmptyView()
}
