import AppKit
import SwiftUI

@MainActor
final class URLHandoffChromeToastController {
    static let shared = URLHandoffChromeToastController()

    private let toastWidth: CGFloat = 420
    private let horizontalInset: CGFloat = 12
    private let bottomInset: CGFloat = 16
    private let entryOffset: CGFloat = 20
    private let animationDuration: TimeInterval = 0.22

    private var panel: URLHandoffChromeToastPanel?
    private var closeAction: (@MainActor () -> Void)?
    private var primaryAction: (@MainActor () -> Void)?
    private var secondaryAction: (@MainActor () -> Void)?
    private var isDismissing = false

    private init() {}

    func present(
        message: String,
        subtext: String?,
        chromeBounds: CGRect,
        screenVisibleFrame: CGRect,
        actionTitle: String? = nil,
        actionUsesGreenStyle: Bool = false,
        actionPulses: Bool = false,
        secondaryActionTitle: String? = nil,
        secondaryActionUsesGreenStyle: Bool = false,
        secondaryActionPulses: Bool = false,
        showsCloseControl: Bool = true,
        onAction: (@MainActor () -> Void)? = nil,
        onSecondaryAction: (@MainActor () -> Void)? = nil,
        onClose: @escaping @MainActor () -> Void
    ) {
        dismissWithoutAction()

        closeAction = onClose
        primaryAction = onAction
        secondaryAction = onSecondaryAction
        isDismissing = false

        let contentView = URLHandoffChromeToastView(
            message: message,
            subtext: subtext,
            actionTitle: actionTitle,
            actionUsesGreenStyle: actionUsesGreenStyle,
            actionPulses: actionPulses,
            secondaryActionTitle: secondaryActionTitle,
            secondaryActionUsesGreenStyle: secondaryActionUsesGreenStyle,
            secondaryActionPulses: secondaryActionPulses,
            showsCloseControl: showsCloseControl,
            onAction: { [weak self] in
                Task { @MainActor in
                    self?.dismissAndRunPrimaryAction()
                }
            },
            onSecondaryAction: { [weak self] in
                Task { @MainActor in
                    self?.dismissAndRunSecondaryAction()
                }
            },
            onClose: { [weak self] in
                Task { @MainActor in
                    self?.dismissAndRunCloseAction()
                }
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: toastWidth, height: 1))
        let measuredHeight = max(hostingView.fittingSize.height, 84)
        let panelSize = CGSize(width: toastWidth, height: measuredHeight)

        hostingView.frame = CGRect(origin: .zero, size: panelSize)

        let topLeftTargetFrame = topLeftToastFrame(
            chromeBounds: chromeBounds,
            screenVisibleFrame: screenVisibleFrame,
            panelSize: panelSize
        )
        let cocoaTargetFrame = cocoaFrame(fromTopLeft: topLeftTargetFrame)
        let cocoaStartFrame = cocoaTargetFrame.offsetBy(dx: 0, dy: -entryOffset)

        let panel = URLHandoffChromeToastPanel(
            contentRect: cocoaStartFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.alphaValue = 0

        self.panel = panel
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(cocoaTargetFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func dismissAndRunCloseAction() {
        guard !isDismissing, let panel else { return }
        isDismissing = true

        let closeAction = self.closeAction
        self.closeAction = nil
        self.primaryAction = nil
        self.secondaryAction = nil

        let target = panel.frame.offsetBy(dx: 0, dy: -entryOffset)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                panel.orderOut(nil)
                panel.close()
                if self.panel == panel {
                    self.panel = nil
                }
                self.isDismissing = false
                closeAction?()
            }
        }
    }

    private func dismissAndRunPrimaryAction() {
        guard !isDismissing, let panel else { return }
        isDismissing = true

        let primaryAction = self.primaryAction
        self.primaryAction = nil
        self.closeAction = nil
        self.secondaryAction = nil

        let target = panel.frame.offsetBy(dx: 0, dy: -entryOffset)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                panel.orderOut(nil)
                panel.close()
                if self.panel == panel {
                    self.panel = nil
                }
                self.isDismissing = false
                primaryAction?()
            }
        }
    }

    private func dismissAndRunSecondaryAction() {
        guard !isDismissing, let panel else { return }
        isDismissing = true

        let secondaryAction = self.secondaryAction
        self.secondaryAction = nil
        self.primaryAction = nil
        self.closeAction = nil

        let target = panel.frame.offsetBy(dx: 0, dy: -entryOffset)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                panel.orderOut(nil)
                panel.close()
                if self.panel == panel {
                    self.panel = nil
                }
                self.isDismissing = false
                secondaryAction?()
            }
        }
    }

    private func dismissWithoutAction() {
        primaryAction = nil
        secondaryAction = nil
        closeAction = nil
        isDismissing = false
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func topLeftToastFrame(
        chromeBounds: CGRect,
        screenVisibleFrame: CGRect,
        panelSize: CGSize
    ) -> CGRect {
        let minX = screenVisibleFrame.minX + horizontalInset
        let maxX = screenVisibleFrame.maxX - panelSize.width - horizontalInset
        let preferredX = chromeBounds.midX - (panelSize.width / 2)
        let clampedX = min(max(preferredX, minX), maxX)

        let minY = screenVisibleFrame.minY + horizontalInset
        let maxY = screenVisibleFrame.maxY - panelSize.height - horizontalInset
        let preferredY = chromeBounds.maxY - panelSize.height - bottomInset
        let clampedY = min(max(preferredY, minY), maxY)

        return CGRect(x: clampedX, y: clampedY, width: panelSize.width, height: panelSize.height)
    }

    private func cocoaFrame(fromTopLeft frame: CGRect) -> CGRect {
        let globalMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0
        let cocoaY = globalMaxY - frame.minY - frame.height
        return CGRect(x: frame.minX, y: cocoaY, width: frame.width, height: frame.height)
    }
}

private final class URLHandoffChromeToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
