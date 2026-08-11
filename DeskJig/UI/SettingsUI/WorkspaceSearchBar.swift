//
//  WorkspaceSearchBar.swift
//  DeskJig
//
//  Created by Claude Code on 01/30/26.
//

import SwiftUI
import DeskJigShared

/// Search bar for workspaces and settings sections.
struct WorkspaceSearchBar: View {
    @Binding var searchText: String
    var isFocused: FocusState<Bool>.Binding
    /// Placeholder text for the search field
    var placeholder: String = "Search workspaces..."
    /// Called when down arrow is pressed while search is focused - navigate down in list
    var onDownArrow: (() -> Void)? = nil
    /// Called when up arrow is pressed while search is focused - navigate up in list
    var onUpArrow: (() -> Void)? = nil
    /// Called when return is pressed while search is focused - activate selected item
    var onReturn: (() -> Void)? = nil
    private let controlHeight: CGFloat = DesignTokens.Form.inputHeight

    var body: some View {
        HStack(spacing: 16) {
            // Search field
            HStack(spacing: DesignTokens.Spacing.itemPaddingVertical) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DesignTokens.IconSize.medium))
                    .foregroundStyle(DesignTokens.Text.tertiary)

                TextField(placeholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .focused(isFocused)
                    .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
                        onDownArrow?()
                        return .handled
                    }
                    .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
                        onUpArrow?()
                        return .handled
                    }
                    .onSubmit {
                        onReturn?()
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: DesignTokens.IconSize.medium))
                            .foregroundStyle(DesignTokens.Text.muted)
                    }
                    .buttonStyle(.plain)
                    .brightenOnHover(0.2)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: controlHeight)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(DesignTokens.Surface.input)
                    .stroke(isFocused.wrappedValue ? DesignTokens.Border.prominent : DesignTokens.Border.subtle, lineWidth: 1)
            }

        }
    }
}

#Preview {
    @Previewable @State var searchText = ""
    @Previewable @FocusState var isFocused: Bool

    VStack(spacing: 20) {
        // With AI button (workspace mode)
        WorkspaceSearchBar(searchText: $searchText, isFocused: $isFocused, onDownArrow: {}, onUpArrow: {}, onReturn: {})

        // Without AI button (settings mode)
        WorkspaceSearchBar(
            searchText: $searchText,
            isFocused: $isFocused,
            placeholder: "Search settings..."
        )
    }
    .padding(20)
    .background(Color.black.opacity(0.8))
}
