import AppKit
import UserNotifications

/// Maps an approval dialog request onto notification action buttons and back.
/// Pure logic, split out so it's unit-testable without UNUserNotificationCenter.
enum ApprovalActionMapper {
    enum Reply: Equatable {
        case confirm(Bool)
        case select(String)
    }

    /// Action buttons for a dialog request: Approve/Deny for a `confirm`, the
    /// first few options verbatim for a `select`. Empty for input/editor
    /// dialogs — free text can't ride on a notification.
    static func actions(forMethod method: String, options: [String]) -> [(id: String, title: String)] {
        switch method {
        case "confirm":
            return [("confirm:yes", String(localized: "Approve")),
                    ("confirm:no", String(localized: "Deny"))]
        case "select":
            return options.prefix(4).enumerated().map { ("select:\($0.offset)", $0.element) }
        default:
            return []
        }
    }

    /// The dialog reply a tapped action stands for, or nil for unknown ids
    /// (including the system default/dismiss identifiers).
    static func reply(forActionID id: String, options: [String]) -> Reply? {
        switch id {
        case "confirm:yes": return .confirm(true)
        case "confirm:no": return .confirm(false)
        default:
            guard id.hasPrefix("select:"),
                  let index = Int(id.dropFirst("select:".count)),
                  options.indices.contains(index) else { return nil }
            return .select(options[index])
        }
    }
}

/// Posts native macOS notifications for background events — the agent finished a
/// run, or an approval is waiting — but only when the app isn't frontmost, so it
/// never nags a user who's already watching the window. Approval notifications
/// carry action buttons, so a permission dialog can be answered without ever
/// switching to the app. Authorization is asked for once, lazily, on first connect.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    /// The user tapped an action button on an approval notification.
    /// Wired by `SessionManager` to route the reply to the right agent.
    var onApprovalReply: ((_ agentID: String, _ requestID: String, _ reply: ApprovalActionMapper.Reply) -> Void)?
    /// The user clicked a notification's body — foreground that session.
    var onFocusSession: ((_ agentID: String) -> Void)?

    private var requested = false
    /// Registered categories accumulate (set-registration replaces the whole
    /// set, and another agent's approval may still be pending).
    private var categories: Set<UNNotificationCategory> = []

    private override init() { super.init() }

    /// `UNUserNotificationCenter.current()` throws if the process has no bundle
    /// identifier — which happens when the Mach-O binary is run directly (the
    /// dev/headless path) rather than launched as an `.app`. Skip notifications
    /// entirely in that case instead of crashing; a real launch has a bundle id.
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// Request banner + sound permission a single time. Safe to call on every
    /// launch; only the first call prompts.
    func requestAuthorizationIfNeeded() {
        guard isBundled, !requested else { return }
        requested = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// True when the user isn't looking — the app is not the active application.
    private var appIsInBackground: Bool { !NSApp.isActive }

    func notifyAgentFinished(project: String?, summary: String?, agentID: String) {
        let title = project.map { String(localized: "pi finished in \($0)") }
            ?? String(localized: "pi finished")
        post(title: title, body: summary ?? "",
             identifier: "agent-end-\(UUID().uuidString)",
             userInfo: ["agentID": agentID])
    }

    /// Approval notification with Approve/Deny (or the select options) as action
    /// buttons, so the dialog can be answered from the notification itself.
    func notifyApprovalNeeded(_ request: ExtUIRequest, agentID: String) {
        guard isBundled, appIsInBackground else { return }
        let actions = ApprovalActionMapper.actions(forMethod: request.method, options: request.options)
        var categoryID = ""
        if !actions.isEmpty {
            categoryID = "approval-\(request.id)"
            categories.insert(UNNotificationCategory(
                identifier: categoryID,
                actions: actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) },
                intentIdentifiers: [],
                options: []
            ))
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }
        post(
            title: request.title ?? String(localized: "Approval needed"),
            body: request.message ?? String(localized: "pi is waiting for your confirmation."),
            identifier: Self.approvalIdentifier(requestID: request.id),
            categoryID: categoryID,
            userInfo: [
                "agentID": agentID,
                "requestID": request.id,
                "options": request.options,
            ]
        )
    }

    /// Withdraw an approval notification once its dialog was answered (in-app
    /// or from another notification) so a stale Approve button can't linger.
    func clearApprovalNotification(requestID: String) {
        guard isBundled else { return }
        let center = UNUserNotificationCenter.current()
        let id = Self.approvalIdentifier(requestID: requestID)
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
        categories = categories.filter { $0.identifier != "approval-\(requestID)" }
    }

    private static func approvalIdentifier(requestID: String) -> String {
        "approval-\(requestID)"
    }

    private func post(title: String, body: String, identifier: String,
                      categoryID: String = "", userInfo: [String: Any] = [:]) {
        guard isBundled, appIsInBackground else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Route a notification interaction back into the app: action buttons feed
    /// the pending approval dialog; clicking the body foregrounds the session.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier
        let agentID = info["agentID"] as? String
        let requestID = info["requestID"] as? String
        let options = info["options"] as? [String] ?? []
        Task { @MainActor in
            guard let agentID else { return }
            if actionID == UNNotificationDefaultActionIdentifier {
                NSApp.activate(ignoringOtherApps: true)
                NotificationService.shared.onFocusSession?(agentID)
            } else if let requestID,
                      let reply = ApprovalActionMapper.reply(forActionID: actionID, options: options) {
                NotificationService.shared.onApprovalReply?(agentID, requestID, reply)
            }
        }
        completionHandler()
    }
}
