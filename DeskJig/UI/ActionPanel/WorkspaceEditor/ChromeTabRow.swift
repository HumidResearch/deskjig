//  ChromeTabRow.swift
//  DeskJig
//
//  Chrome tab row component with URL editing
//

import SwiftUI
import DeskJigShared

// MARK: - URL Helpers

/// Normalizes a URL by prepending "https://" if no scheme is present
private func normalizeURL(_ urlString: String) -> String {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }

    // Check if it already has a scheme (contains "://")
    if trimmed.contains("://") {
        return trimmed
    }

    // Check for other valid scheme prefixes without "://" (like "about:" or "javascript:")
    let schemePrefixes = ["about:", "javascript:", "data:", "chrome:"]
    for prefix in schemePrefixes {
        if trimmed.lowercased().hasPrefix(prefix) {
            return trimmed
        }
    }

    // No scheme found, prepend https://
    return "https://\(trimmed)"
}

struct ChromeTabRow: View {
    let index: Int
    @Binding var url: String
    let onDelete: () -> Void
    
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editedURL: String = ""
    @FocusState private var isFocused: Bool
    
    /// Validates if a string is a valid URL (after normalization)
    private var isValidURL: Bool {
        validateURL(normalizeURL(editedURL))
    }
    
    private func validateURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        // Try to create a URL object
        guard let url = URL(string: trimmed) else { return false }
        
        // Check for valid scheme (http, https, file, etc.)
        guard let scheme = url.scheme?.lowercased() else { return false }
        let validSchemes = ["http", "https", "file", "chrome", "about", "javascript", "data"]
        guard validSchemes.contains(scheme) else { return false }
        
        // For http/https, require a host
        if scheme == "http" || scheme == "https" {
            guard url.host != nil && !url.host!.isEmpty else { return false }
        }
        
        return true
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Tab index
            Text("\(index + 1)")
                .font(brand: .label4)
                .foregroundStyle(DesignTokens.Text.tertiary)
                .frame(width: 24)
            
            // URL TextField
            TextField("https://example.com", text: $editedURL)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isValidURL || editedURL.isEmpty ? DesignTokens.Text.primary : DesignTokens.Status.error)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    commitEdit()
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        commitEdit()
                    }
                }
            
            // Validation indicator
            if !editedURL.isEmpty {
                Image(systemName: isValidURL ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(brand: Font.brandBody(size: 12))
                    .foregroundStyle(isValidURL ? DesignTokens.Status.success : DesignTokens.Status.error)
            }
            
            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(brand: Font.brandBody(size: 12))
                    .foregroundStyle(isHovering ? DesignTokens.Text.primary : DesignTokens.Text.muted)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isFocused ? DesignTokens.Surface.elevated : (isHovering ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            !editedURL.isEmpty && !isValidURL ? DesignTokens.Status.error.opacity(0.6) : DesignTokens.Brand.accentLight,
                            lineWidth: 1
                        )
                )
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onAppear {
            editedURL = url
        }
        .onChange(of: url) { _, newValue in
            if !isFocused {
                editedURL = newValue
            }
        }
    }
    
    private func commitEdit() {
        let trimmed = editedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Auto-prepend https:// if no scheme is present
        let normalized = normalizeURL(trimmed)
        DeskJigLog.info(.chrome, "ChromeTabRow commitEdit called", fields: ["index": "\(index)", "editedURL": trimmed, "normalized": normalized, "originalURL": url])
        if validateURL(normalized) {
            if normalized != url {
                DeskJigLog.info(.chrome, "ChromeTabRow URL changed", fields: ["index": "\(index)", "from": url, "to": normalized])
                url = normalized
                editedURL = normalized // Update the text field to show the normalized URL
            } else {
                DeskJigLog.info(.chrome, "ChromeTabRow URL unchanged", fields: ["index": "\(index)", "url": normalized])
            }
        } else if trimmed.isEmpty {
            // Revert to original if empty
            DeskJigLog.warn(.chrome, "ChromeTabRow empty URL, reverting", fields: ["index": "\(index)", "url": url])
            editedURL = url
        } else {
            // Invalid URL - revert to original
            DeskJigLog.warn(.chrome, "ChromeTabRow invalid URL, reverting", fields: ["index": "\(index)", "invalid": normalized, "url": url])
            editedURL = url
        }
    }
}

// MARK: - Add New Tab Row

struct AddNewTabRow: View {
    let nextIndex: Int
    let onAdd: (String) -> Void
    
    @State private var newURL: String = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    
    private var isValidURL: Bool {
        validateURL(normalizeURL(newURL))
    }
    
    private func validateURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        // Try to create a URL object
        guard let url = URL(string: trimmed) else { return false }
        
        // Check for valid scheme
        guard let scheme = url.scheme?.lowercased() else { return false }
        let validSchemes = ["http", "https", "file", "chrome", "about", "javascript", "data"]
        guard validSchemes.contains(scheme) else { return false }
        
        // For http/https, require a host
        if scheme == "http" || scheme == "https" {
            guard url.host != nil && !url.host!.isEmpty else { return false }
        }
        
        return true
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Plus icon or next index
            Image(systemName: "plus.circle.fill")
                .font(brand: Font.brandBody(size: 14))
                .foregroundStyle(DesignTokens.Brand.accent.opacity(0.7))
                .frame(width: 24)
            
            // URL TextField
            TextField("Add new URL (https://...)", text: $newURL)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isValidURL || newURL.isEmpty ? DesignTokens.Text.primary : DesignTokens.Status.error)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    addURL()
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        addURL()
                    }
                }
            
            // Validation indicator
            if !newURL.isEmpty {
                Image(systemName: isValidURL ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(brand: Font.brandBody(size: 12))
                    .foregroundStyle(isValidURL ? DesignTokens.Status.success : DesignTokens.Status.error)
            }
            
            // Add button
            Button(action: addURL) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(brand: Font.brandBody(size: 14))
                    .foregroundStyle(isValidURL ? DesignTokens.Brand.accent : DesignTokens.Text.muted)
            }
            .buttonStyle(.plain)
            .disabled(!isValidURL)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isFocused ? DesignTokens.Brand.accentMuted : (isHovering ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            !newURL.isEmpty && !isValidURL ? DesignTokens.Status.error.opacity(0.6) :
                            (isFocused ? DesignTokens.Brand.accentLight : DesignTokens.Border.subtle),
                            lineWidth: 1
                        )
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: isFocused ? [] : [4, 4]))
                )
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
    
    private func addURL() {
        let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Auto-prepend https:// if no scheme is present
        let normalized = normalizeURL(trimmed)
        guard validateURL(normalized) else { return }
        
        onAdd(normalized)
        newURL = ""
    }
}
