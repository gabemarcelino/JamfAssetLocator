//
//  PushTokenUploader.swift
//  JamfAssetLocator
//
//  Created by Gabriel Marcelino on 8/14/25.
//

import Foundation

struct PushTokenUploader {
    static func upload(token: String) {
        // If you operate a push service, POST the token + device ID here.
        // Example only; replace with your endpoint.
        guard let url = URL(string: "https://push.yourcompany.example/register") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let config = ManagedConfig()
        let payload: [String: Any] = [
            "token": token,
            "device_id": config.jamfDeviceID ?? "",
            "bundle": Bundle.main.bundleIdentifier ?? ""
        ]
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }
}
