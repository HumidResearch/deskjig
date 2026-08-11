//
//  WorkspaceActionTileView.swift
//  DeskJigShared
//
//  Created by Jake Sax on 10/15/25.
//

import SwiftUI

struct WorkspaceActionTileView: View {
    
    let screenInfo: ScreenInfo
    let isGridVisible: Bool
    let onToggleGrid: (() -> Void)?
    let windowLayoutManager: WindowLayoutManager?

    static let size: CGSize = .init(width: 500, height: 420)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            templateSelectionView
        }
        .padding(12)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.15))
                }
        )
    }
    
    private var templateSelectionView: some View {
        VStack(spacing: 32) {
            
            Text("Layouts")
                .font(brand: .h3)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(
                        [LayoutTemplate.fullScreen, LayoutTemplate.leftRightHalf, LayoutTemplate.topBottomHalf]
                    ) { template in
                        layoutTemplateButton(template)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    ForEach(
                        [LayoutTemplate.threeVertical, LayoutTemplate.threeHorizontal, LayoutTemplate.fourParts]
                    ) { template in
                        layoutTemplateButton(template)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
        }
    }
    
    private func layoutTemplateButton(_ template: LayoutTemplate) -> some View {
        LayoutTemplateButton(
            template: template,
            isSelected: false, // Layout templates no longer persist
            onTap: {
                // Zone templates are no longer used for persistent layouts
                // Only drag-to-snap preview overlays are supported
                DeskJigLog.debug(.app, "WorkspaceActionTileView: Layout template selection disabled - only drag-to-snap previews are available")
            }
        )
    }
    
    struct LayoutTemplateButton: View {
        let template: LayoutTemplate
        let isSelected: Bool
        let onTap: () -> Void
        @State private var isHovering: Bool = false
        
        var body: some View {
            Button(action: onTap) {
                // Template icon
                Image(systemName: template.iconName)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? .black : .white)
                    .frame(width: 92, height: 92)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(isSelected ? 1 : 0.2))
                    }
            }
            .buttonStyle(.plain)
            .onHover(perform: { isHovering = $0 })
            .scaleEffect(isHovering ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
    }
}
