//  HintView.swift
//  DeskJig
//
//  Created by Jake Sax on 9/24/25.
//

import SwiftUI
import DeskJigShared

struct HintView: View {

    let hint: Hint.Content
    let closeHint: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(hint.title)
                    .font(brand: .h4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: closeHint){
                    Image(systemName: "xmark")
                        .font(brand: Font.brandBody(size: 18))
                        .padding(12) // expand tappable region
                }
                .buttonStyle(.plain)
                .padding(-12)
            }

            ForEach(hint.body, id: \.self) { textElement in
                Group {
                    switch textElement {
                    case .bullet(let string):
                        HStack(alignment: .top, spacing: 4) {
                            Text("•")
                            Text(string)
                        }
                        .padding(.leading, 8)
                    case .plain(let string):
                        Text(string)
                    }
                }
                .font(brand: .body3)
                .opacity(0.7)
            }
        }
        .padding(32)
        .foregroundStyle(DesignTokens.Text.primary)
        .frame(width: 500, height: 325, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.brandDarkGray)
        }
        .transition(.blurReplace.animation(.smooth(duration: 0.35)))

    }
}

// MARK: Previews
#Preview {
    @Previewable @State var isPresented: Bool = true
    ZStack {
        Button("Present Hint") { isPresented = true }
            .foregroundStyle(.black)
        if isPresented {
            HintView(
                hint: Hint.workspaceCreation.content,
                closeHint: { isPresented = false }
            )
            .padding(20)
        }
    }
    .background(Color.white)
}
