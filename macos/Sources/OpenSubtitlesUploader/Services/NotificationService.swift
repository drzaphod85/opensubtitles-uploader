import Foundation
import AppKit
import UserNotifications

/// Notification Center banners for finished uploads. Only used when the app is in the
/// background; in the foreground the result alert is enough.
enum NotificationService {
    private static var authorizationRequested = false

    /// UNUserNotificationCenter needs a real app bundle; skip when run from `swift run`.
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func post(title: String, body: String, url: URL? = nil) {
        guard isAvailable, !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let url { content.userInfo = ["url": url.absoluteString] }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
        if authorizationRequested {
            deliver()
        } else {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { deliver() }
            }
        }
    }
}
