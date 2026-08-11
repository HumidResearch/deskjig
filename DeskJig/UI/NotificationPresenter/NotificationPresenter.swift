//
//  NotificationPresenter.swift
//  DeskJig
//
//  Created by Jake Sax on 11/11/25.
//

import SwiftUI
import DeskJigShared
import Combine
import OrderedCollections

// MARK: Public Presenter
public enum NotificationPresenter {

    // MARK: Public Interface

    /// Presentation corner for a toast notification.
    public enum PresentationEdge: Sendable, Hashable, CaseIterable {
        case topTrailing
        case bottomTrailing

        fileprivate var transitionAnchor: UnitPoint {
            switch self {
            case .topTrailing:
                return .top
            case .bottomTrailing:
                return .bottom
            }
        }

        fileprivate var insertionYOffset: CGFloat {
            switch self {
            case .topTrailing:
                return -200
            case .bottomTrailing:
                return 200
            }
        }
    }

    /// Indicates why a toast notification was dismissed.
    public enum DismissReason: Sendable, Hashable {
        case action
        case close
        case swipe
        case timeout
        case programmatic
    }

    /// Presents the provided notification to the user.
    /// - Parameter notification: The notification to send.
    /// - Parameter id: The ID of the notification. May be saved for later manual dismissal of
    /// the notification. If this method is called with the same ID as the currently presented notification,
    /// the second notification will not be updated, nor will it be presented again or enqueued.
    /// - Parameter tapAction: Optional action fired by the notification action button.
    /// - Parameter edge: The corner where this notification should be presented.
    /// - Parameter duration: The duration for presenting the notification, defaults
    /// to dismissing itself after 3 seconds.
    /// - Parameter onDismiss: Optional callback fired once when the toast is dismissed.
    @MainActor public static func present(
        _ notification: NotificationContent,
        withID id: UUID = UUID(),
        tapAction: (@Sendable () -> Void)? = nil,
        edge: PresentationEdge = .topTrailing,
        for duration: PresentationDuration = .seconds(3),
        onDismiss: (@Sendable (DismissReason) -> Void)? = nil
    ) {
        publisher.send(
            .present(
                notification: Notification(
                    id: id,
                    content: notification,
                    action: tapAction,
                    presentationEdge: edge,
                    presentationDuration: duration,
                    onDismiss: onDismiss
                )
            )
        )
    }


    /// Updates the content of the provided notification if it is currently presented. This can be useful
    /// for showing some sort of progress for asynchronous work.
    ///
    /// - Parameter id: The ID of the notification to update. If the provided update
    /// does not match a currently presented notification, it will not be updated.
    /// - Parameter content: The updated content of the notification. This may
    /// also be used to **downgrade** the notification's presentation duration to
    /// `.temporary`, but may **not** be used to upgrade the notification's duration
    /// to `.persistent`.
    /// - Parameter edge: The corner where this notification should be presented.
    /// - Parameter duration: The duration for presenting the notification, defaults
    /// to dismissing itself after 3 seconds.
    @MainActor public static func update(
        notificationWithID id: UUID,
        to content: NotificationContent,
        tapAction: (@Sendable () -> Void)? = nil,
        edge: PresentationEdge = .topTrailing,
        for duration: PresentationDuration = .seconds(3)
    ) {
        publisher.send(
            .update(
                notification: Notification(
                    id: id,
                    content: content,
                    action: tapAction,
                    presentationEdge: edge,
                    presentationDuration: duration,
                    onDismiss: nil
                )
            )
        )
    }

    /// Dismisses the notification with the specified ID across any and all views the notification
    /// exists in. If the notification is not currently presented then it will not be dismissed/dequeued.
    /// - Parameter id: The ID of the notification to dismiss.
    @MainActor public static func dismiss(notificationWithID id: UUID) {
        publisher.send(.dismiss(notificationWithID: id))
    }

    /// The duration for which the notification is presented.
    public enum PresentationDuration: Sendable, Hashable, CustomDebugStringConvertible, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {

        /// The notification will be presented until the user dismisses it.
        case persistent

        /// The notification will be presented for the specified duration and
        /// then will dismiss itself.
        case temporary(_ duration: Duration)

        /// The duration for which the notification should be presented before
        /// dismissing itself.
        var duration: Duration? {
            switch self {
            case .persistent:
                nil
            case .temporary(let duration):
                duration
            }
        }

        public var debugDescription: String {
            switch self {
            case .persistent:
                "Persistent"
            case .temporary(let tempDuration):
                "Temporary: \(tempDuration.seconds) seconds"
            }
        }

        /// The notification will be presented for the specified number of seconds and then
        /// will dismiss itself.
        public static func seconds(_ seconds: Double) -> PresentationDuration {
            .temporary(.seconds(seconds))
        }

        public init(integerLiteral value: IntegerLiteralType) {
            self = .seconds(Double(value))
        }

        public init(floatLiteral value: FloatLiteralType) {
            self = .seconds(value)
        }
    }

    public struct NotificationContent: Equatable, Sendable {
        let title: String
        let text: String?
        let detailLines: [ToastDetailLine]
        let icon: String
        let iconColor: IconColor?
        let appIconPath: String?
        let appIconName: String?
        let actionTitle: String?
        let actionContext: String?
        let forceDarkAppearance: Bool
        let actionUsesGreenStyle: Bool
        let actionPulses: Bool
        let showsCloseControl: Bool

        /// Icon color options for notification icons
        public enum IconColor: Equatable, Sendable {
            case yellow
            case red
            case green
            case blue

            var color: Color {
                switch self {
                case .yellow: return .yellow
                case .red: return .red
                case .green: return .green
                case .blue: return .blue
                }
            }
        }

        public init(
            _ title: String,
            text: String? = nil,
            detailLines: [ToastDetailLine] = [],
            icon: String = "bell.circle.fill",
            iconColor: IconColor? = nil,
            appIconPath: String? = nil,
            appIconName: String? = nil,
            actionTitle: String? = nil,
            actionContext: String? = nil,
            forceDarkAppearance: Bool = false,
            actionUsesGreenStyle: Bool = false,
            actionPulses: Bool = false,
            showsCloseControl: Bool = true
        ) {
            self.title = title
            self.text = (text?.isEmpty == true) ? nil : text
            self.detailLines = detailLines
            self.icon = icon
            self.iconColor = iconColor
            let trimmedAppIconPath = appIconPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.appIconPath = (trimmedAppIconPath?.isEmpty == false) ? trimmedAppIconPath : nil
            let trimmedAppIconName = appIconName?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.appIconName = (trimmedAppIconName?.isEmpty == false) ? trimmedAppIconName : nil
            self.forceDarkAppearance = forceDarkAppearance
            self.actionUsesGreenStyle = actionUsesGreenStyle
            self.actionPulses = actionPulses
            self.showsCloseControl = showsCloseControl

            if let actionTitle, !actionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.actionTitle = actionTitle
            } else {
                self.actionTitle = nil
            }

            if let actionContext, !actionContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.actionContext = actionContext
            } else {
                self.actionContext = nil
            }
        }
    }

    // MARK: Private Interface
    @MainActor fileprivate static let publisher = PassthroughSubject<Action, Never>()

    fileprivate struct Notification: Identifiable, Hashable, Sendable, CustomDebugStringConvertible {
        let id: UUID
        var content: NotificationContent
        var action: (@Sendable () -> Void)?
        var presentationEdge: PresentationEdge
        var presentationDuration: PresentationDuration
        var onDismiss: (@Sendable (DismissReason) -> Void)?

        static func == (
            lhs: NotificationPresenter.Notification,
            rhs: NotificationPresenter.Notification
        ) -> Bool {
            lhs.id == rhs.id &&
            lhs.content == rhs.content &&
            lhs.presentationDuration == rhs.presentationDuration &&
            lhs.presentationEdge == rhs.presentationEdge
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        var debugDescription: String {
            "\(id), text: \(content.title.prefix(15)), duration: \(presentationDuration.debugDescription), edge: \(presentationEdge)"
        }
    }

    fileprivate enum Action: Sendable, Equatable, CustomDebugStringConvertible {
        case present(notification: Notification)
        case update(notification: Notification)
        case dismiss(notificationWithID: Notification.ID)

        var debugDescription: String {
            switch self {
            case .present(let notification):
                "Present notification: \(notification.debugDescription)"
            case .update(let notification):
                "Update notification: \(notification.debugDescription)"
            case .dismiss(let notificationID):
                "Dismiss notification: \(notificationID)"
            }
        }
    }

}

// MARK: Public ViewModifier
extension View {
    /// Registers this view as a recipient to display toast notifications.
    public func presentsNotifications() -> some View {
        self.modifier(NotificationPresenterModifier())
    }
}


// MARK: Private ViewModifier
/// Adds an overlay to present notifications. Notifications can be presented using
/// `NotificationPresenter` and its `present()` method. Notifications
/// will automatically dismiss themselves if requested. If a notification has reached its
/// time to dismiss but the user is interacting with the notification, the notification will not be
/// dismissed and will no longer dismiss itself until the user swipes it away.
private struct NotificationPresenterModifier: ViewModifier {
    typealias Notification = NotificationPresenter.Notification

    // MARK: Data
    @State private var presentedNotifications: OrderedSet<Notification> = []

    // MARK: UI
    @State private var isInteracting: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                edgeNotificationView(for: .topTrailing)
            }
            .overlay(alignment: .bottomTrailing) {
                edgeNotificationView(for: .bottomTrailing)
            }
            .animation(.smooth, value: presentedNotifications)
            .onReceive(NotificationPresenter.publisher) { action in
                handleAction(action)
            }
    }

    @ViewBuilder
    private func edgeNotificationView(for edge: NotificationPresenter.PresentationEdge) -> some View {
        let notifications = notificationsForEdge(edge)
        if !notifications.isEmpty {
            let anchor: UnitPoint = edge == .topTrailing ? .topTrailing : .bottomTrailing
            // Top-edge stacks should layer upward (behind the active toast),
            // while bottom-edge stacks layer downward.
            let verticalDirection: CGFloat = edge == .topTrailing ? -1 : 1
            let verticalLayerOffset: CGFloat = 30
            let horizontalLayerOffset: CGFloat = 12
            let layerScaleStep: CGFloat = 0.022
            let stackSpread = CGFloat(max(notifications.count - 1, 0)) * verticalLayerOffset
            let baseEdgeInset: CGFloat = edge == .topTrailing ? 24 : 16

            ZStack(alignment: edge == .topTrailing ? .topTrailing : .bottomTrailing) {
                ForEach(Array(notifications.enumerated()), id: \.element.id) { index, notification in
                    let depth = CGFloat(index)
                    let scale = max(0.9, 1.0 - (depth * layerScaleStep))
                    let xOffset = -depth * horizontalLayerOffset
                    let yOffset = depth * verticalDirection * verticalLayerOffset

                    notificationView(notification)
                        .offset(x: xOffset, y: yOffset)
                        .scaleEffect(scale, anchor: anchor)
                        .opacity(index == 0 ? 1.0 : 0.92)
                        .zIndex(Double(notifications.count - index))
                        .allowsHitTesting(index == 0)
                        .transition(transition(for: edge))
                }
            }
            .padding(.horizontal, 16)
            // Add extra inset so "behind" cards aren't clipped at the screen edge.
            .safeAreaPadding(edge == .topTrailing ? .top : .bottom, baseEdgeInset + stackSpread)
            .allowsHitTesting(true)
        }
    }

    private func notificationsForEdge(_ edge: NotificationPresenter.PresentationEdge) -> [Notification] {
        let filtered = presentedNotifications.filter { $0.presentationEdge == edge }
        switch edge {
        case .topTrailing:
            return Array(filtered.reversed())
        case .bottomTrailing:
            return Array(filtered)
        }
    }

    private func transition(for edge: NotificationPresenter.PresentationEdge) -> AnyTransition {
        .asymmetric(
            insertion: .offset(y: edge.insertionYOffset)
                .combined(with: .scale(scale: 0.4, anchor: edge.transitionAnchor))
                .animation(.bouncy(extraBounce: 0.1)),
            removal: .blurTransition(blurRadius: 5, scale: 0.94)
                .animation(.smooth(duration: 0.25))
        )
    }

    private func notificationView(_ notification: Notification) -> some View {
        NotificationView(
            notification: notification.content,
            isInteracting: $isInteracting,
            action: notification.action,
            dismiss: { reason in
                dismissNotification(notification: notification, reason: reason)
            }
        )
        .id(notification.id)
    }

    // MARK: Methods
    private func handleAction(_ action: NotificationPresenter.Action) {
        switch action {

        case .present(notification: let newNotification):
            // Ignore duplicate IDs to preserve "present once" semantics.
            guard !presentedNotifications.contains(where: { $0.id == newNotification.id }) else {
                return
            }
            presentNotification(notification: newNotification)

        case .update(notification: let notification):

            if let index = presentedNotifications.firstIndex(where: { $0.id == notification.id }) {
                let existing = presentedNotifications[index]
                var updated = existing
                updated.content = notification.content
                if let action = notification.action {
                    updated.action = action
                }
                updated.presentationEdge = notification.presentationEdge
                updated.presentationDuration = notification.presentationDuration
                presentedNotifications.remove(at: index)
                presentedNotifications.insert(updated, at: index)

                // schedule dismissal if the old notification was persistent and the new is not
                if existing.presentationDuration == .persistent && notification.presentationDuration != .persistent {
                    scheduleNotificationDismissal(updated)
                }
            }

        case .dismiss(notificationWithID: let notificationID):
            if let presentedNotification = presentedNotifications.first(where: { $0.id == notificationID }) {
                dismissNotification(
                    notification: presentedNotification,
                    reason: .programmatic,
                    shouldBroadcast: false
                )
            }
        }
    }

    /// Presents the provided notification and schedules its dismissal if it has one. Enqueues the next
    /// notification to present after dismissal.
    /// - Parameter notification: The notification to present.
    private func presentNotification(notification: Notification) {
        self.presentedNotifications.append(notification)

        // schedule its dismissal
        scheduleNotificationDismissal(notification)
    }

    private func scheduleNotificationDismissal(_ notification: Notification) {
        if let duration = notification.presentationDuration.duration {
            MainActor.async(after: duration) {
                dismissNotification(notification: notification, reason: .timeout)
            }
        }
    }

    /// Dismisses this notification locally and emits a message to dismiss the notification anywhere
    /// else it is presented.
    /// - Parameter notification: The notification to dismiss.
    private func dismissNotification(
        notification: Notification,
        reason: NotificationPresenter.DismissReason,
        shouldBroadcast: Bool = true
    ) {
        // only continue if this view is presenting the notification
        guard presentedNotifications.contains(where: { $0.id == notification.id }), !isInteracting else {
            return
        }

        presentedNotifications.removeAll(where: { $0.id == notification.id })
        notification.onDismiss?(reason)

        if shouldBroadcast {
            // inform any other view presenting this notification that it
            // should be dismissed
            NotificationPresenter.dismiss(notificationWithID: notification.id)
        }
    }

    // MARK: Supporting Views
    fileprivate struct NotificationView: View {

        // MARK: Data
        let notification: NotificationPresenter.NotificationContent
        @Binding var isInteracting: Bool
        let action: (() -> Void)?
        let dismiss: (NotificationPresenter.DismissReason) -> Void

        // MARK: UI
        @State private var offset: CGFloat = .zero

        private var shouldShowAction: Bool {
            notification.actionTitle != nil && action != nil
        }

        var body: some View {
            DSToast(
                icon: notification.icon,
                message: notification.title,
                subtext: notification.text,
                detailLines: notification.detailLines,
                iconColor: notification.iconColor?.color ?? DesignTokens.Brand.accent,
                appIconPath: notification.appIconPath,
                appIconName: notification.appIconName,
                forceDarkAppearance: notification.forceDarkAppearance,
                actionTitle: notification.actionTitle,
                actionContext: notification.actionContext,
                actionUsesGreenStyle: notification.actionUsesGreenStyle,
                actionPulses: notification.actionPulses,
                showsCloseControl: notification.showsCloseControl,
                action: shouldShowAction ? {
                    action?()
                    isInteracting = false
                    dismiss(.action)
                } : nil,
                onClose: {
                    isInteracting = false
                    dismiss(.close)
                }
            )
            .offset(x: offset)
            .onScrollGesture(
                onChanged: { value in
                    guard !value.isMomentum else {
                        return
                    }

                    if !isInteracting {
                        isInteracting = true
                    }

                    if value.translation.width > 0 {
                        offset = value.translation.width
                    } else {
                        offset = -pow(abs(value.translation.width), 0.5)
                    }
                },
                onEnded: { value in
                    isInteracting = false
                    guard !value.isMomentum else {
                        return
                    }

                    if value.predictedEndTranslation.width > 200 {
                        dismiss(.swipe)
                        withAnimation(.snappy(duration: 0.35)) {
                            offset = 800
                        }
                    } else {
                        withAnimation(.snappy(duration: 0.35)) {
                            offset = .zero
                        }
                    }
                }
            )
        }

    }
}

#if DEBUG
struct NotificationTestingView: View {
    var body: some View {
        Text("Notification testing view")
            .font(brand: .body2)
            .foregroundStyle(DesignTokens.Text.primary)
            .padding(24)
    }
}
#endif
