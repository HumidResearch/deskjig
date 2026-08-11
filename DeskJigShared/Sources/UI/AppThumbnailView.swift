//
//  AppThumbnailView.swift
//  DeskJig
//
//  Created by Marco Freedom on 17.09.2025.
//

import SwiftUI

struct AppThumbnailView: View {
    let snapshot: WindowSnapshot

    var body: some View {
        thumbnailView(isCompact: false)
            .frame(width: 100)
            .padding(.vertical, 12)
            .onTapGesture {
                DeskJigLog.debug(.app, "AppThumbnailView: Tapped on window '\(snapshot.windowInfo.windowTitle)'")
            }
            .onDrag {
                DeskJigLog.debug(.app, "AppThumbnailView: Started dragging window '\(snapshot.windowInfo.windowTitle)'")
                // Store the dragged snapshot globally
                DragDropManager.shared.draggedSnapshot = snapshot
                return NSItemProvider(object: NSString(string: "windowSnapshot_\(snapshot.id)"))
            } preview: {
                thumbnailView(isCompact: true)
            }
    }
    
    private func thumbnailView(isCompact: Bool) -> some View {
        VStack(spacing: 2) {
            VStack {
                // App icon overlay in top-left corner
                if let appInfo = snapshot.appInfo,
                   let appIcon = appInfo.icon {
                    Image(nsImage: appIcon)
                        .resizable()
                } else {
                    Image(systemName: "questionmark.app.fill")
                        .resizable()
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(8)
                }
            }
            .frame(width: isCompact ? 20 : 80, height: isCompact ? 20 : 80)
            .shadow(color: .black.opacity(isCompact ? 0 : 0.3), radius: 8, y: 3)
            
            Text(snapshot.windowInfo.appName)
                .font(brand: .body3)
                .lineLimit(1)
        }
    }
}
