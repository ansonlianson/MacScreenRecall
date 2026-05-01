import Foundation
import UserNotifications

enum AppNotifier {
    /// 推送一条本地通知（已请求过授权）。
    static func post(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err {
                AppLogger.app.error("post notification failed: \(err.localizedDescription)")
            }
        }
    }
}
