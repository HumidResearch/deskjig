import SwiftUI
import DeskJigShared

struct URLHandoffChromeToastView: View {
    let message: String
    let subtext: String?
    let actionTitle: String?
    let actionUsesGreenStyle: Bool
    let actionPulses: Bool
    let secondaryActionTitle: String?
    let secondaryActionUsesGreenStyle: Bool
    let secondaryActionPulses: Bool
    let showsCloseControl: Bool
    let onAction: (() -> Void)?
    let onSecondaryAction: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        DSToast(
            icon: "rectangle.split.2x1.fill",
            message: message,
            subtext: subtext,
            iconColor: DesignTokens.Brand.accent,
            forceDarkAppearance: true,
            actionTitle: actionTitle,
            actionUsesGreenStyle: actionUsesGreenStyle,
            actionPulses: actionPulses,
            secondaryActionTitle: secondaryActionTitle,
            secondaryActionUsesGreenStyle: secondaryActionUsesGreenStyle,
            secondaryActionPulses: secondaryActionPulses,
            showsCloseControl: showsCloseControl,
            action: onAction,
            secondaryAction: onSecondaryAction,
            onClose: onClose
        )
        .frame(width: 420)
    }
}
