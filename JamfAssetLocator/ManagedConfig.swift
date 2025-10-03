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
            // IMPORTANT: For device testing without MDM-managed config, set this to your device's Jamf Mobile Device ID (e.g., "553").
            // Leaving it empty will now be treated as missing and will block API calls with a clear message.
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
            "UI_SHOW_ASSET_TAG": true,
            
            "UI_ALLOW_OTHER_BUILDING": true,
            "UI_ALLOW_OTHER_DEPARTMENT": true,
            
            // Prefer to use managed offices as building source when Jamf list is unavailable
            "UI_USE_MANAGED_OFFICES_AS_BUILDINGS": true,
            
            // Label overrides (change what the user sees; still map to Jamf canonical fields)
            "UI_BUILDING_LABEL": "Office",
            "UI_DEPARTMENT_LABEL": "Department",
            "UI_ROOM_LABEL": "Room / Desk",
            "UI_CONTACT_LABEL": "Contact Person (Real Name)",
            "UI_EMAIL_LABEL": "One Medical Email",
            "UI_ASSET_TAG_LABEL": "Asset Tag",
            
            // Required field controls (DEBUG: test all)
            "MANDATORY_EMAIL": true,
            "MANDATORY_CONTACT": true,
            "MANDATORY_DEPARTMENT": true,
            "MANDATORY_BUILDING": true,
            "MANDATORY_ASSET_TAG": false, // set to true to require asset tag
            
            // Logging control (optional; if absent, logs stay quiet)
            "LOG_VERBOSE": true,

            // OPTIONAL: Runtime accent colors (hex). If absent, the app uses the AccentColor asset.
            // Light mode (Avocado): #A8C47C
            "ACCENT_COLOR_LIGHT": "#8B0000",
            // Dark mode (Jade): #005450
            "ACCENT_COLOR_DARK": "#ff3f3f",

            // NEW (DEBUG defaults): Extension Attribute stamping via OAuth PATCH
            // Exact name of the Mobile Device Extension Attribute to write
            "JAMF_EA_NAME": "Asset Locator Last Stamp",
            // EA type (Jamf expects a string like "STRING", "INTEGER", etc.). Default is "STRING".
            "JAMF_EA_TYPE": "STRING",
            // If your EA allows collections (multi-value). Default false.
            "JAMF_EA_COLLECTION_ALLOWED": false,
            // Optional custom date format; if omitted, uses ISO 8601 UTC (e.g., 2025-10-03T17:42:10Z)
            "JAMF_EA_DATE_FORMAT": "yyyy-MM-dd'T'HH:mm:ss'Z'",
            // Whether to stamp automatically on Submit (default true)
            "JAMF_EA_ON_SUBMIT": true
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
    
    var jamfURL: String? { (dict["JAMF_URL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    // Treat empty string as missing so guards fail fast instead of building bad URLs.
    var jamfDeviceID: String? { (dict["JAMF_DEVICE_ID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    
    // Legacy: username/password (fallback if client credentials are not provided)
    var jamfUsername: String? { (dict["JAMF_USERNAME"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    var jamfPassword: String? { (dict["JAMF_PASSWORD"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    
    // Preferred: OAuth Client Credentials
    var jamfClientID: String? { (dict["JAMF_CLIENT_ID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    var jamfClientSecret: String? { (dict["JAMF_CLIENT_SECRET"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    
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
    
    // MARK: - Required (Mandatory) Controls
    
    var uiRequireEmail: Bool { (dict["MANDATORY_EMAIL"] as? Bool) ?? false }
    var uiRequireContact: Bool { (dict["MANDATORY_CONTACT"] as? Bool) ?? false }
    var uiRequireDepartment: Bool { (dict["MANDATORY_DEPARTMENT"] as? Bool) ?? false }
    var uiRequireBuilding: Bool { (dict["MANDATORY_BUILDING"] as? Bool) ?? false }
    var uiRequireAssetTag: Bool { (dict["MANDATORY_ASSET_TAG"] as? Bool) ?? false }
    
    // MARK: - Logging
    
    // If present in managed config, overrides default logging behavior.
    var logVerboseOverride: Bool? { dict["LOG_VERBOSE"] as? Bool }

    // MARK: - Accent color (Managed App Config overrides)
    var accentColorLightHex: String? { (dict["ACCENT_COLOR_LIGHT"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    var accentColorDarkHex: String? { (dict["ACCENT_COLOR_DARK"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }

    // MARK: - Extension Attribute stamping (Managed App Config)
    // Exact EA name (Mobile Device Extension Attribute)
    var jamfEAName: String? { (dict["JAMF_EA_NAME"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    // EA type (e.g., "STRING"); defaults to "STRING"
    var jamfEAType: String { ((dict["JAMF_EA_TYPE"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty) ?? "STRING" }
    // Whether the EA allows a collection (multi-value). Defaults to false.
    var jamfEACollectionAllowed: Bool { (dict["JAMF_EA_COLLECTION_ALLOWED"] as? Bool) ?? false }
    // Optional custom date format; if nil, we’ll use ISO 8601 UTC
    var jamfEADateFormat: String? { (dict["JAMF_EA_DATE_FORMAT"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    // Whether to stamp automatically on Submit
    var jamfEAOnSubmit: Bool { (dict["JAMF_EA_ON_SUBMIT"] as? Bool) ?? true }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

