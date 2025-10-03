//
//  JamfAssetLocatorApp.swift
//  JamfAssetLocator
//
//  Created by Gabriel Marcelino on 8/14/25.
//

import SwiftUI
import UserNotifications
import UIKit

@main
struct AssetLocatorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Load managed config once at launch
    private let config = ManagedConfig()

    // Resolve app-wide tint: managed override (light/dark) or fallback to asset AccentColor
    private var appTint: Color {
        if let dynamic = Self.dynamicAccentColor(lightHex: config.accentColorLightHex, darkHex: config.accentColorDarkHex) {
            return dynamic
        } else {
            // Fallback to asset (keeps Xcode’s global Accent Color happy)
            return Color("AccentColor")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(appTint)
        }
    }

    // Build a dynamic Color that switches for light/dark based on provided hex values.
    private static func dynamicAccentColor(lightHex: String?, darkHex: String?) -> Color? {
        guard let lightHex, let light = UIColor(hex: lightHex) else {
            // If only dark provided, still allow a single-color override
            if let darkHex, let dark = UIColor(hex: darkHex) {
                return Color(dark)
            }
            return nil
        }
        // If dark is missing, use the light color for both appearances
        let dark = (darkHex.flatMap { UIColor(hex: $0) }) ?? light
        let dynamic = UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
        return Color(dynamic)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Ask for notification permission, then register with APNs
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            if granted {
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("APNs token: \(token)")
        // Send token + device identifier to your push service (optional)
        PushTokenUploader.upload(token: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }
}

// MARK: - Hex parsing

private extension UIColor {
    convenience init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: s)
        var rgba: UInt64 = 0
        guard scanner.scanHexInt64(&rgba) else { return nil }
        switch s.count {
        case 6:
            let r = CGFloat((rgba & 0xFF0000) >> 16) / 255.0
            let g = CGFloat((rgba & 0x00FF00) >> 8) / 255.0
            let b = CGFloat(rgba & 0x0000FF) / 255.0
            self.init(red: r, green: g, blue: b, alpha: 1.0)
        case 8:
            let a = CGFloat((rgba & 0xFF000000) >> 24) / 255.0
            let r = CGFloat((rgba & 0x00FF0000) >> 16) / 255.0
            let g = CGFloat((rgba & 0x0000FF00) >> 8) / 255.0
            let b = CGFloat(rgba & 0x000000FF) / 255.0
            self.init(red: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }
}
