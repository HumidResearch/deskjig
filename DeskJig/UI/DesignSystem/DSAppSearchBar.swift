//
//  DSAppSearchBar.swift
//  DeskJig
//
//  Created by Codex on 02/03/26.
//

import SwiftUI
import AppKit
import DeskJigShared

struct DSAppSearchResult: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let bundleId: String
    let supportsMultipleInstances: Bool
}

struct DSAppSearchBar: View {
    @Binding var query: String
    let results: [DSAppSearchResult]
    var onClear: (() -> Void)? = nil
    var onSelectApp: ((DSAppSearchResult) -> Void)? = nil

    /// Constant height for the results strip (#597): the app list scrolls
    /// internally and never drives the creator's row-height calculation, so
    /// toggling between empty and populated results can't reflow the canvas.
    private let resultsStripHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DesignTokens.IconSize.medium))
                    .foregroundStyle(DesignTokens.Text.tertiary)

                TextField("Search apps...", text: $query)
                    .textFieldStyle(.plain)
                    .font(brand: .body2)
                    .foregroundStyle(DesignTokens.Text.primary)

                if !query.isEmpty {
                    Button {
                        query = ""
                        onClear?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: DesignTokens.IconSize.medium))
                            .foregroundStyle(DesignTokens.Text.muted)
                    }
                    .buttonStyle(.plain)
                    .brightenOnHover()
                }
            }
            .padding(.horizontal, DesignTokens.Form.inputPaddingHorizontal)
            .frame(height: DesignTokens.Form.inputHeight)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                    .fill(DesignTokens.Surface.input)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
            }

            Group {
                if results.isEmpty {
                    Text(query.isEmpty ? "Search for apps to add" : "No apps match your search")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: DesignTokens.Spacing.gapSmall) {
                            ForEach(results) { app in
                                DSAppChip(app: app, onSelect: {
                                    onSelectApp?(app)
                                })
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .frame(height: resultsStripHeight)
        }
    }
}

struct DSAppChip: View {
    let app: DSAppSearchResult
    var onSelect: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "app.fill")
                    .font(brand: Font.brandBody(size: 14))
                    .foregroundStyle(DesignTokens.Text.muted)
            }

            Text(app.name)
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.primary)
                .lineLimit(1)

            if app.supportsMultipleInstances {
                Image(systemName: "plus.circle")
                    .font(brand: Font.brandBody(size: 10))
                    .foregroundStyle(DesignTokens.Text.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .fill(isHovering ? DesignTokens.WorkspaceBuilder.appChipHover : DesignTokens.WorkspaceBuilder.appChipFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .stroke(DesignTokens.Border.subtle, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
        .draggable("app:\(app.bundleId)")
        .onTapGesture {
            onSelect?()
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        DSAppSearchBar(
            query: .constant(""),
            results: [
                DSAppSearchResult(id: "com.apple.Terminal", name: "Terminal", icon: nil, bundleId: "com.apple.Terminal", supportsMultipleInstances: true),
                DSAppSearchResult(id: "com.apple.Safari", name: "Safari", icon: nil, bundleId: "com.apple.Safari", supportsMultipleInstances: false)
            ],
            onSelectApp: { _ in }
        )
    }
    .padding(24)
    .background(Color.black.opacity(0.9))
}
