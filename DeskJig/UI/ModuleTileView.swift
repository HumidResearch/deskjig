//  ModuleTileView.swift
//  DeskJig
//
//  Created by Marco Freedom on 05.09.2025.
//

import SwiftUI
import DeskJigShared

struct ModuleTileView: View {
    let tile: Tile
    let isSelected: Bool
    /// Whether the navigation focus is on the tiles instead of the search bar
    let tilesAreFocused: Bool
    let shortcutIndex: Int? // 1…9
    let appIcons: [NSImage?]
    private var hasSubmenu: Bool {
        tile.type == .branch
    }
    
    @State private var isHovering: Bool = false
    private let cornerRadius: CGFloat = 12
    
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(isSelected ? 0.2 : 0.1))
            .stroke(
                Color.white.opacity(isSelected ? (tilesAreFocused ? 1 : 0.6) : 0),
                lineWidth: isSelected ? (tilesAreFocused ? 4 : 2) : 1
            )
            .shadow(
                color: Color.black.opacity(isSelected ? 0.25 : 0),
                radius: 4,
                y: 4
            )
            .frame(width: 262.5, height: 240)
            .overlay(alignment: .topLeading) {
                tileContent
            }
            .overlay(alignment: .topTrailing) {
                if !hasSubmenu {
                    forwardNavigationIndicator
                }
            }
//            .onHover { isHovering in
//                self.isHovering = isHovering
//            }
            .animation(.smooth(duration: 0.1), value: isSelected)
            .animation(.smooth(duration: 0.2), value: tilesAreFocused)
    }
    
    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 10) {
        
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 4) {
                    
                    let appsToDisplay: Int = 4
                    let appSize: CGFloat = 36
                    
                    ForEach(Array(appIcons.prefix(appsToDisplay).enumerated()), id: \.offset) { offset, icon in
                        if let icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: appSize, height: appSize)
                        } else {
                            Image(systemName: "questionmark.app.fill")
                                .resizable()
                                .frame(width: appSize, height: appSize)
                                .foregroundStyle(Color.black.opacity(0.7))
                        }
                    }
                    
                    if appIcons.count > appsToDisplay {
                        Text("+\(appIcons.count - appsToDisplay)")
                            .font(brand: .h6)
                            .foregroundStyle(DesignTokens.Text.primary)
                            .frame(width: appSize * 0.85, height: appSize * 0.85) // the app icons are padded so this accounts for that
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black.opacity(0.7))
                            }
                    }
                }
                
                if appIcons.isEmpty, let icon = tile.icon {
                    Image(nsImage: NSImage(resource: icon))
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .frame(width: 32, height: 32)
                }
                
                Text(tile.title)
                    .font(brand: .h4)
                    .lineLimit(2)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            
            HStack {
                if let shortcutIndex {
                    Text("⌘\(shortcutIndex)")
                        .font(brand: .h3)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                
                if hasSubmenu {
                    submenuNavigationIndicator
                }
            }
        }
        .padding(40)
    }
    
    private var forwardNavigationIndicator: some View {
        UnevenRoundedRectangle(
            bottomLeadingRadius: cornerRadius,
            topTrailingRadius: cornerRadius
        )
        .fill(Color.white.opacity(0.1))
        .frame(width: 40, height: 44)
        .overlay {
            Image(nsImage: NSImage(resource: .northEast))
                .resizable()
                .frame(width: 24, height: 24)
                .id("north.east")
                .repeatingAnimation(
                    isActive: isSelected,
                    duration: 0.5,
                    animation: .smooth(duration: 0.5)
                ) { content, didAnimate, isActive in
                    content.offset(!isActive ? .zero : (didAnimate ? .init(width: 3, height: -3) : .init(width: -1.5, height: 1.5)))
                }
        }
    }
    
    private var submenuNavigationIndicator: some View {
        Image(nsImage: NSImage(resource: .chevronRight))
            .resizable()
            .frame(width: 32, height: 32)
            .repeatingAnimation(
                isActive: isSelected,
                duration: 0.5,
                animation: .smooth(duration: 0.5)
            ) { content, didAnimate, isActive in
                content.offset(x: !isActive ? .zero : (didAnimate ? 4 : -2))
            }
    }
}


#Preview {
    @Previewable @State var tile1IsSelected: Bool = true
    @Previewable @State var tile2IsSelected: Bool = true
    @Previewable @State var tile3IsSelected: Bool = true
    
    let tile = Tile(
        title: "Module Title",
        subtitle: nil,
//        systemImage: "arrow.up",
        icon: .northEast,
        type: .leaf
    )
    
    let tile2 = Tile(
        title: "Module Title",
        subtitle: nil,
        //        systemImage: "arrow.up",
        icon: .northEast,
        type: .branch
    )
    
    VStack(alignment: .trailing, spacing: 12) {
        HStack {
            Text("Not selected, not focused")
            ModuleTileView(
                tile: tile,
                isSelected: false,
                tilesAreFocused: false,
                shortcutIndex: 1,
                appIcons: []
            )
        }
        HStack {
            Text("Selected, not focused")
            ModuleTileView(
                tile: tile,
                isSelected: tile1IsSelected,
                tilesAreFocused: false,
                shortcutIndex: 1,
                appIcons: []
            )
            .onTapGesture {
                tile1IsSelected.toggle()
            }
        }
        HStack {
            Text("Selected and focused")
            ModuleTileView(
                tile: tile,
                isSelected: tile1IsSelected,
                tilesAreFocused: true,
                shortcutIndex: 1,
                appIcons: []
            )
            .onTapGesture {
                tile1IsSelected.toggle()
            }
        }
        ModuleTileView(
            tile: tile2,
            isSelected: tile2IsSelected,
            tilesAreFocused: true,
            shortcutIndex: nil,
            appIcons: [NSImage(resource: .chrome), NSImage(resource: .figma), NSImage(resource: .chrome), NSImage(resource: .figma), NSImage(resource: .chrome), NSImage(resource: .figma)]
        )
        .onTapGesture {
            tile2IsSelected.toggle()
        }
        
        ModuleTileView(
            tile: tile,
            isSelected: tile3IsSelected,
            tilesAreFocused: true,
            shortcutIndex: 3,
            appIcons: [NSImage(resource: .chrome), NSImage(resource: .figma), ]
        )
        .onTapGesture {
            tile3IsSelected.toggle()
        }
    }
    .padding(40)
}


#Preview {
    HStack {
        Image(nsImage: NSImage(resource: .addBox))
        
        Image(nsImage: NSImage(resource: .addBox))
            .renderingMode(.template)
            .foregroundStyle(DesignTokens.Text.primary)
//        #7D848B
    }
//        .foregroundStyle(DesignTokens.Status.error)
}
