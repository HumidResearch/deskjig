//
//  OnLoadModifier.swift
//  DeskJig
//
//  Created by Jake Sax on 10/16/25.
//

import SwiftUI
import DeskJigShared


private struct OnLoadModifier: ViewModifier {
    
    let action: () -> Void
    @State private var viewDidLoad = false
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                if !viewDidLoad {
                    viewDidLoad = true
                    action()
                }
            }
    }
}

extension View {
    /// Adds an action to perform only when the view first loads.
    ///
    /// This modifier provides behavior similar to UIKit's `viewDidLoad()`.
    /// The action will execute only once when the view is first displayed,
    /// and won't repeat when the view reappears after being covered by another view.
    /// However, if the view is completely removed and recreated, the action will
    /// execute again.
    ///
    /// - Parameter action: The action to perform when the view loads. This closure
    ///   executes exactly once during the initial appearance of the view.
    /// - Returns: A view that triggers the given action upon its initial appearance.
    ///
    /// - Note: Unlike `onAppear`, this modifier only triggers its action the first
    ///   time the view appears, not on subsequent appearances.
    ///
    /// Example:
    /// ```swift
    /// MyView()
    ///     .onLoad {
    ///         // Perform one-time setup
    ///         loadInitialData()
    ///     }
    /// ```
    func onLoad(perform action: @escaping () -> Void) -> some View {
        self.modifier(OnLoadModifier(action: action))
    }
    
}

#Preview("Calls Every Presentation") {
    @Previewable @State var isPresented: Bool = false
    Color.white
        .overlay {
            VStack {
                Button("toggle") {
                    isPresented.toggle()
                }
                
                if isPresented {
                    Text("Hello, World!")
                        .foregroundStyle(.black)
                        .onLoad {
                            DeskJigLog.debug(.app, "OnLoadModifier: did load - will call every presentation")
                        }
                        .onAppear {
                            DeskJigLog.debug(.app, "OnLoadModifier: did appear - will call every presentation")
                        }
                }
                
            }
        }
}

#Preview("Calls Once") {
    @Previewable @State var isPresented: Bool = false
    NavigationStack {
        Color.white
            .overlay {
                VStack {
                    Button("toggle") {
                        isPresented.toggle()
                    }
                }
                
            }
            .navigationDestination(isPresented: $isPresented) {
                DesignTokens.Brand.accent
            }
            .onLoad {
                DeskJigLog.debug(.app, "OnLoadModifier: did load - will only call once")
            }
            .onAppear {
                DeskJigLog.debug(.app, "OnLoadModifier: did appear - will call every navigate back")
            }
    }
}