//  SearchField.swift
//  DeskJig
//
//  Created by Marco Freedom on 05.09.2025.
//

import SwiftUI

struct SearchField: View {
    @ObservedObject var navigationManager: NavigationManager
    let onMoveCommand: (MoveCommandDirection) -> Void
    let onExitCommand: () -> Void
    let onKeyPressed: (KeyPress) -> KeyPress.Result
    @FocusState var internalIsFocused: Bool
    private var isPrimaryFocus: Bool {
        navigationManager.focus == .search
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $navigationManager.search)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
                .focused($internalIsFocused)
            
                // These .onKeyPress are processed in reverse order, this is last to be processed.
                .onKeyPress { keyPress in
                    // Lastly handle regular typing input to focus search visually (should already be focused with @FocusState)
                    if keyPress.modifiers.isDisjoint(with: [.command, .control, .shift, .option]) {
                        DispatchQueue.main.async {
                            if !navigationManager.searchIsFocused {
                                navigationManager.searchIsFocused = true
                            }
                            if navigationManager.focus == .tiles {
                                navigationManager.focus = .search
                            }
                        }
                    }
                    return .ignored
                }
                .onKeyPress(.escape) {
                    onExitCommand()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    if navigationManager.focus == .search {
                        DispatchQueue.main.async {
                            navigationManager.focus = .tiles
                        }
                    } else {
                        onMoveCommand(.down)
                    }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    onMoveCommand(.up)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    onMoveCommand(.right)
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    onMoveCommand(.left)
                    return .handled
                }
                .onKeyPress(action: onKeyPressed)

        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.thinMaterial)
                .stroke(
                    Color.white.opacity(isPrimaryFocus ? 0.8 : 0.12),
                    lineWidth: isPrimaryFocus ? 2 : 1
                )
        )
        .opacity(isPrimaryFocus ? 1 : 0.8)
        .animation(.easeInOut(duration: 0.15), value: internalIsFocused)
        .onChange(of: navigationManager.searchIsFocused) { _, isFocused in
            if isFocused != internalIsFocused {
                internalIsFocused = isFocused
            }
        }
        .onChange(of: internalIsFocused) {
            if internalIsFocused != navigationManager.searchIsFocused {
                navigationManager.searchIsFocused = internalIsFocused
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                navigationManager.searchIsFocused = true
                internalIsFocused = true
            }
        }
    }
}
