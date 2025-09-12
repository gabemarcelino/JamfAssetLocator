//
//  ManagedConfig.swift
//  JamfAssetLocator
//
//  Created by Gabriel Marcelino on 8/14/25.
//

import Foundation

struct ManagedConfig {
    private let dict: [String: Any]
    
    init() {
        #if DEBUG
        self.dict = [
            "JAMF_URL": "https://onemedical.jamfcloud.com",
            "JAMF_DEVICE_ID": "553",

            // Legacy username/password flow (optional; will be ignored if client credentials are present)
            "JAMF_USERNAME": "",
            "JAMF_PASSWORD": "",

            // OAuth Client Credentials (preferred when present)
            "JAMF_CLIENT_ID": "52b32b92-a5c6-4f33-89de-5110cf6da832",
            "JAMF_CLIENT_SECRET": "3qxn2GaZ-mm7wcEeu5S8MsE3VEbcoSBcJH2ZdLyKOGZKW-nAGhffOSVJx9cy_mqK",

            // Optional managed list of offices (used as building source if enabled)
            "JAMF_OFFICES": "NYC HQ,Boston Clinic",

            // UI configurability
            "UI_SHOW_BUILDING": true,
            "UI_SHOW_DEPARTMENT": true,
            "UI_SHOW_ROOM": true,
            "UI_SHOW_CONTACT": true,
            "UI_SHOW_EMAIL": true,

            "UI_ALLOW_OTHER_BUILDING": true,
            "UI_ALLOW_OTHER_DEPARTMENT": true,

            // Prefer to use managed offices as building source when Jamf list is unavailable
            "UI_USE_MANAGED_OFFICES_AS_BUILDINGS": true,

            // Label overrides (change what the user sees; still map to Jamf canonical fields)
            "UI_BUILDING_LABEL": "Office",
            "UI_DEPARTMENT_LABEL": "Department",
            "UI_ROOM_LABEL": "Room / Desk",
            "UI_CONTACT_LABEL": "Contact Person (Real Name)",
            "UI_EMAIL_LABEL": "Email",

            // Asset Tag UI (new)
            "UI_SHOW_ASSET_TAG": true,
            "UI_ASSET_TAG_LABEL": "Asset Tag"
        ]
        #else
        self.dict = (UserDefaults.standard.object(forKey: "com.apple.configuration.managed") as? [String: Any]) ?? [:]
        #endif

        #if DEBUG
        var redacted = dict
        if redacted["JAMF_PASSWORD"] != nil { redacted["JAMF_PASSWORD"] = "REDACTED" }
        if redacted["JAMF_USERNAME"] != nil { redacted["JAMF_USERNAME"] = "REDACTED" }
        if redacted["JAMF_CLIENT_ID"] != nil { redacted["JAMF_CLIENT_ID"] = "REDACTED" }
        if redacted["JAMF_CLIENT_SECRET"] != nil { redacted["JAMF_CLIENT_SECRET"] = "REDACTED" }
        print("ManagedConfig loaded (DEBUG): \(redacted)")
        #endif
    }
    
    var jamfURL: String? { dict["JAMF_URL"] as? String }
    var jamfDeviceID: String? { dict["JAMF_DEVICE_ID"] as? String }
    
    // Legacy: username/password (fallback if client credentials are not provided)
    var jamfUsername: String? { dict["JAMF_USERNAME"] as? String }
    var jamfPassword: String? { dict["JAMF_PASSWORD"] as? String }

    // Preferred: OAuth Client Credentials
    var jamfClientID: String? { dict["JAMF_CLIENT_ID"] as? String }
    var jamfClientSecret: String? { dict["JAMF_CLIENT_SECRET"] as? String }
    
    var officeOptions: [String] {
        if let csv = dict["JAMF_OFFICES"] as? String {
            return csv
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    // MARK: - UI Config Flags

    var uiShowBuilding: Bool { (dict["UI_SHOW_BUILDING"] as? Bool) ?? true }
    var uiShowDepartment: Bool { (dict["UI_SHOW_DEPARTMENT"] as? Bool) ?? true }
    var uiShowRoom: Bool { (dict["UI_SHOW_ROOM"] as? Bool) ?? true }
    var uiShowContact: Bool { (dict["UI_SHOW_CONTACT"] as? Bool) ?? true }
    var uiShowEmail: Bool { (dict["UI_SHOW_EMAIL"] as? Bool) ?? true }
    var uiShowAssetTag: Bool { (dict["UI_SHOW_ASSET_TAG"] as? Bool) ?? true } // NEW

    var uiAllowOtherBuilding: Bool { (dict["UI_ALLOW_OTHER_BUILDING"] as? Bool) ?? true }
    var uiAllowOtherDepartment: Bool { (dict["UI_ALLOW_OTHER_DEPARTMENT"] as? Bool) ?? true }

    var uiUseManagedOfficesAsBuildings: Bool { (dict["UI_USE_MANAGED_OFFICES_AS_BUILDINGS"] as? Bool) ?? true }

    // MARK: - UI Label Overrides

    var uiBuildingLabel: String { (dict["UI_BUILDING_LABEL"] as? String)?.nilIfEmpty ?? "Building" }
    var uiDepartmentLabel: String { (dict["UI_DEPARTMENT_LABEL"] as? String)?.nilIfEmpty ?? "Department" }
    var uiRoomLabel: String { (dict["UI_ROOM_LABEL"] as? String)?.nilIfEmpty ?? "Room / Desk" }
    var uiContactLabel: String { (dict["UI_CONTACT_LABEL"] as? String)?.nilIfEmpty ?? "Contact Person (Real Name)" }
    var uiEmailLabel: String { (dict["UI_EMAIL_LABEL"] as? String)?.nilIfEmpty ?? "Email" }
    var uiAssetTagLabel: String { (dict["UI_ASSET_TAG_LABEL"] as? String)?.nilIfEmpty ?? "Asset Tag" } // NEW
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
