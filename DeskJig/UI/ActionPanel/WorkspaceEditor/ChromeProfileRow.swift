//  ChromeProfileRow.swift
//  DeskJig
//
//  Chrome profile row component with selection
//

import SwiftUI
import DeskJigShared

struct ChromeProfileRow: View {
    let profile: ChromeProfile
    let isSelected: Bool
    let onTap: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Profile icon
                ZStack {
                    Circle()
                        .fill(isSelected ? DesignTokens.Brand.accentMuted : DesignTokens.Surface.elevated)
                        .frame(width: 32, height: 32)
                    
                    Text(String(profile.displayName.prefix(1)).uppercased())
                        .font(brand: Font.brandBody(size: 14))
                        .foregroundStyle(isSelected ? DesignTokens.Brand.accent : DesignTokens.Text.primary)
                }
                
                // Profile info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.displayName)
                            .font(brand: .label2)
                            .foregroundStyle(DesignTokens.Text.primary)
                        
                        if isSelected {
                            Text("Current")
                                .font(brand: Font.brandBody(size: 9))
                                .foregroundStyle(DesignTokens.Brand.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background {
                                    Capsule()
                                        .fill(DesignTokens.Brand.accentMuted)
                                }
                        }
                    }
                    
                    HStack(spacing: 4) {
                        if let gaiaName = profile.gaiaName {
                            Text(gaiaName)
                                .font(brand: Font.brandBody(size: 10))
                                .foregroundStyle(DesignTokens.Text.tertiary)
                        }
                        
                        if let hostedDomain = profile.hostedDomain {
                            Text("- \(hostedDomain)")
                                .font(brand: Font.brandBody(size: 10))
                                .foregroundStyle(DesignTokens.Text.tertiary)
                        }
                    }
                }
                
                Spacer()
                
                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(brand: Font.brandBody(size: 16))
                        .foregroundStyle(DesignTokens.Brand.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? DesignTokens.Brand.accentMuted : (isHovering ? DesignTokens.Surface.elevated : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? DesignTokens.Brand.accentLight : Color.clear, lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

/// Row for "Any Chrome Window" option - removes profile restriction
struct AnyWindowRow: View {
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Globe icon for "any"
                ZStack {
                    Circle()
                        .fill(isSelected ? DesignTokens.Status.info.opacity(0.2) : DesignTokens.Surface.elevated)
                        .frame(width: 32, height: 32)

                    Image(systemName: "globe")
                        .font(brand: Font.brandBody(size: 14))
                        .foregroundStyle(isSelected ? DesignTokens.Status.info : DesignTokens.Text.primary)
                }

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Any Window")
                            .font(brand: .label2)
                            .foregroundStyle(DesignTokens.Text.primary)

                        if isSelected {
                            Text("Selected")
                                .font(brand: Font.brandBody(size: 9))
                                .foregroundStyle(DesignTokens.Status.info)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background {
                                    Capsule()
                                        .fill(DesignTokens.Status.info.opacity(0.2))
                                }
                        }
                    }

                    Text("Use any Chrome window, regardless of profile")
                        .font(brand: Font.brandBody(size: 10))
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }

                Spacer()

                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(brand: Font.brandBody(size: 16))
                        .foregroundStyle(DesignTokens.Status.info)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? DesignTokens.Status.info.opacity(0.2) : (isHovering ? DesignTokens.Surface.elevated : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? DesignTokens.Status.info.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
