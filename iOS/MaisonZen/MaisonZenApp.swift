import SwiftUI
import UserNotifications

@main
struct MaisonZenApp: App {
    @State private var store = AppStore()

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.light)
                .tint(Color.maisonTeal)
        }
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}

extension Color {
    static let maisonTeal = Color(red: 0.17, green: 0.52, blue: 0.52)
    static let maisonMint = Color(red: 0.83, green: 0.92, blue: 0.88)
    static let maisonInk = Color(red: 0.12, green: 0.22, blue: 0.23)
    static let maisonCanvas = Color(red: 0.96, green: 0.97, blue: 0.95)
}
