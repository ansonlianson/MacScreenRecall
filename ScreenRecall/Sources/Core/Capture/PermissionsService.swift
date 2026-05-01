import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import UserNotifications

@MainActor
final class PermissionsService {
    static let shared = PermissionsService()
    private init() {}

    func refresh() async {
        let screen = await checkScreenCapture()
        let notif = await checkNotifications()
        AppState.shared.screenRecordingAuthorized = screen
        AppState.shared.notificationAuthorized = notif
        AppLogger.permissions.info("permissions screen=\(screen) notif=\(notif)")
    }

    func checkScreenCapture() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return CGPreflightScreenCaptureAccess()
        } catch {
            return false
        }
    }

    @discardableResult
    func requestScreenCapture() async -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                AppLogger.permissions.error("SCShareableContent failed: \(error.localizedDescription)")
            }
        }
        let final = CGPreflightScreenCaptureAccess()
        AppState.shared.screenRecordingAuthorized = final
        return final
    }

    func openScreenRecordingPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func checkNotifications() async -> Bool {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationSettings { s in
                cont.resume(returning: s.authorizationStatus == .authorized || s.authorizationStatus == .provisional)
            }
        }
    }

    @discardableResult
    func requestNotifications() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            AppState.shared.notificationAuthorized = granted
            return granted
        } catch {
            AppLogger.permissions.error("notif request failed: \(error.localizedDescription)")
            return false
        }
    }
}
