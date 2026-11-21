import Foundation

/// Android permissions in plain English, with how they're granted.
struct AndroidPermission: Equatable {
    enum Level: Int, Comparable {
        /// Granted when installed.
        case normal = 0
        /// The person is asked when the app first needs it.
        case runtime = 1
        /// Granted by the person in Settings (overlay, all files, usage access…).
        case special = 2
        /// Only system apps, or apps signed with the platform key, get it.
        case system = 3

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let name: String
    let title: String
    let symbol: String
    let tint: InspectorTint
    let level: Level
    /// Worth a second look even when legitimate (SMS, call logs, overlays, installing apps…).
    let sensitive: Bool

    static func describe(_ name: String) -> AndroidPermission {
        let short = name.hasPrefix("android.permission.") ? String(name.dropFirst("android.permission.".count)) : name
        if let known = catalog[name] ?? catalog[short] {
            return AndroidPermission(name: name, title: known.0, symbol: known.1, tint: known.2, level: known.3, sensitive: known.4)
        }
        if short.hasPrefix("FOREGROUND_SERVICE_") {
            let kind = short.dropFirst("FOREGROUND_SERVICE_".count).replacingOccurrences(of: "_", with: " ").lowercased()
            return AndroidPermission(name: name, title: "Foreground service (\(kind))", symbol: "gearshape.2", tint: .gray, level: .normal, sensitive: false)
        }
        // Unknown: derive a readable title from the constant ("READ_FOO_BAR" -> "Read foo bar").
        let last = name.split(separator: ".").last.map(String.init) ?? name
        var words = last.replacingOccurrences(of: "_", with: " ").lowercased()
        if let first = words.first { words = first.uppercased() + words.dropFirst() }
        return AndroidPermission(name: name, title: words.isEmpty ? name : words, symbol: "key", tint: .gray, level: .normal, sensitive: false)
    }

    // name: (title, symbol, tint, level, sensitive)
    private static let catalog: [String: (String, String, InspectorTint, Level, Bool)] = [
        // Location
        "ACCESS_FINE_LOCATION": ("Precise location", "location.fill", .blue, .runtime, false),
        "ACCESS_COARSE_LOCATION": ("Approximate location", "location", .blue, .runtime, false),
        "ACCESS_BACKGROUND_LOCATION": ("Location in the background", "location.circle", .blue, .runtime, true),
        "ACCESS_MEDIA_LOCATION": ("Locations in your photos", "mappin.and.ellipse", .blue, .runtime, false),
        "ACCESS_LOCATION_EXTRA_COMMANDS": ("Extra location provider commands", "location", .blue, .normal, false),
        "ACCESS_MOCK_LOCATION": ("Fake its location", "location.slash", .blue, .system, false),
        // Camera, microphone, sensors
        "CAMERA": ("Camera", "camera.fill", .gray, .runtime, false),
        "RECORD_AUDIO": ("Microphone", "mic.fill", .orange, .runtime, false),
        "BODY_SENSORS": ("Body sensors", "heart.fill", .pink, .runtime, false),
        "BODY_SENSORS_BACKGROUND": ("Body sensors in the background", "heart.circle", .pink, .runtime, true),
        "ACTIVITY_RECOGNITION": ("Physical activity", "figure.walk", .green, .runtime, false),
        "HIGH_SAMPLING_RATE_SENSORS": ("High-rate motion sensors", "gyroscope", .gray, .normal, false),
        "DETECT_SCREEN_CAPTURE": ("Detect screenshots", "camera.viewfinder", .gray, .normal, false),
        // Contacts, calendar, accounts
        "READ_CONTACTS": ("Read your contacts", "person.crop.circle", .brown, .runtime, false),
        "WRITE_CONTACTS": ("Change your contacts", "person.crop.circle.badge.plus", .brown, .runtime, false),
        "GET_ACCOUNTS": ("Find accounts on the device", "person.2", .gray, .runtime, false),
        "READ_PROFILE": ("Read your profile card", "person.text.rectangle", .brown, .normal, false),
        "READ_CALENDAR": ("Read your calendar", "calendar", .red, .runtime, false),
        "WRITE_CALENDAR": ("Change your calendar", "calendar.badge.plus", .red, .runtime, false),
        "MANAGE_ACCOUNTS": ("Manage accounts", "person.2.badge.gearshape", .gray, .normal, false),
        "USE_CREDENTIALS": ("Use account credentials", "key", .gray, .normal, false),
        "AUTHENTICATE_ACCOUNTS": ("Create accounts and set passwords", "key", .gray, .normal, false),
        // Phone, calls, SMS
        "READ_PHONE_STATE": ("Phone status and identity", "phone", .green, .runtime, false),
        "READ_PHONE_NUMBERS": ("Read phone numbers", "phone", .green, .runtime, false),
        "CALL_PHONE": ("Make phone calls", "phone.arrow.up.right", .green, .runtime, true),
        "ANSWER_PHONE_CALLS": ("Answer phone calls", "phone.arrow.down.left", .green, .runtime, false),
        "MANAGE_OWN_CALLS": ("Route its own calls", "phone.connection", .green, .normal, false),
        "PROCESS_OUTGOING_CALLS": ("Reroute outgoing calls", "phone.arrow.right", .green, .runtime, true),
        "READ_CALL_LOG": ("Read your call log", "list.bullet.rectangle", .green, .runtime, true),
        "WRITE_CALL_LOG": ("Change your call log", "list.bullet.rectangle", .green, .runtime, true),
        "ADD_VOICEMAIL": ("Add voicemail", "recordingtape", .green, .runtime, false),
        "USE_SIP": ("Internet calls (SIP)", "phone.badge.waveform", .green, .runtime, false),
        "SEND_SMS": ("Send text messages", "message.fill", .green, .runtime, true),
        "RECEIVE_SMS": ("Receive text messages", "message", .green, .runtime, true),
        "READ_SMS": ("Read your text messages", "message", .green, .runtime, true),
        "RECEIVE_MMS": ("Receive picture messages", "message", .green, .runtime, true),
        "RECEIVE_WAP_PUSH": ("Receive WAP push messages", "message", .green, .runtime, true),
        "READ_CELL_BROADCASTS": ("Read emergency broadcasts", "exclamationmark.bubble", .green, .runtime, false),
        // Storage and media
        "READ_EXTERNAL_STORAGE": ("Read shared storage", "folder", .blue, .runtime, false),
        "WRITE_EXTERNAL_STORAGE": ("Change shared storage", "folder.badge.plus", .blue, .runtime, false),
        "MANAGE_EXTERNAL_STORAGE": ("All files access", "externaldrive.fill", .blue, .special, true),
        "READ_MEDIA_IMAGES": ("Photos", "photo.on.rectangle", .orange, .runtime, false),
        "READ_MEDIA_VIDEO": ("Videos", "film", .orange, .runtime, false),
        "READ_MEDIA_AUDIO": ("Music and audio", "music.note", .pink, .runtime, false),
        "READ_MEDIA_VISUAL_USER_SELECTED": ("Selected photos and videos", "photo", .orange, .runtime, false),
        // Notifications and alerts
        "POST_NOTIFICATIONS": ("Notifications", "bell.badge.fill", .red, .runtime, false),
        "USE_FULL_SCREEN_INTENT": ("Full-screen notifications", "rectangle.inset.filled", .red, .special, false),
        "ACCESS_NOTIFICATION_POLICY": ("Do Not Disturb access", "moon.fill", .indigo, .special, false),
        "SYSTEM_ALERT_WINDOW": ("Draw over other apps", "rectangle.on.rectangle", .purple, .special, true),
        // Nearby devices
        "BLUETOOTH": ("Connect to paired Bluetooth devices", "antenna.radiowaves.left.and.right", .blue, .normal, false),
        "BLUETOOTH_ADMIN": ("Pair with Bluetooth devices", "antenna.radiowaves.left.and.right", .blue, .normal, false),
        "BLUETOOTH_SCAN": ("Find nearby Bluetooth devices", "antenna.radiowaves.left.and.right", .blue, .runtime, false),
        "BLUETOOTH_CONNECT": ("Connect to nearby Bluetooth devices", "antenna.radiowaves.left.and.right", .blue, .runtime, false),
        "BLUETOOTH_ADVERTISE": ("Advertise to nearby Bluetooth devices", "antenna.radiowaves.left.and.right", .blue, .runtime, false),
        "NEARBY_WIFI_DEVICES": ("Nearby Wi-Fi devices", "wifi", .blue, .runtime, false),
        "UWB_RANGING": ("Ultra-wideband ranging", "dot.radiowaves.left.and.right", .blue, .runtime, false),
        "NFC": ("NFC", "wave.3.right", .gray, .normal, false),
        "TRANSMIT_IR": ("Infrared transmitter", "av.remote", .gray, .normal, false),
        // Network
        "INTERNET": ("Full network access", "network", .blue, .normal, false),
        "ACCESS_NETWORK_STATE": ("View network connections", "network", .gray, .normal, false),
        "ACCESS_WIFI_STATE": ("View Wi-Fi connections", "wifi", .gray, .normal, false),
        "CHANGE_WIFI_STATE": ("Connect to and disconnect from Wi-Fi", "wifi", .gray, .normal, false),
        "CHANGE_NETWORK_STATE": ("Change network connectivity", "network", .gray, .normal, false),
        "CHANGE_WIFI_MULTICAST_STATE": ("Receive Wi-Fi multicast", "wifi", .gray, .normal, false),
        // Apps and system
        "REQUEST_INSTALL_PACKAGES": ("Install other apps", "square.and.arrow.down", .indigo, .special, true),
        "REQUEST_DELETE_PACKAGES": ("Ask to uninstall apps", "trash", .indigo, .normal, false),
        "INSTALL_PACKAGES": ("Install apps silently", "square.and.arrow.down.fill", .indigo, .system, true),
        "DELETE_PACKAGES": ("Uninstall apps silently", "trash.fill", .indigo, .system, true),
        "QUERY_ALL_PACKAGES": ("See all installed apps", "square.grid.3x3", .indigo, .special, true),
        "PACKAGE_USAGE_STATS": ("App usage access", "chart.bar.fill", .indigo, .special, true),
        "GET_TASKS": ("See running apps", "square.stack.3d.up", .gray, .normal, false),
        "REORDER_TASKS": ("Reorder running apps", "square.stack.3d.up", .gray, .normal, false),
        "KILL_BACKGROUND_PROCESSES": ("Close other apps", "xmark.app", .gray, .normal, false),
        "WRITE_SETTINGS": ("Change system settings", "gearshape.fill", .gray, .special, true),
        "WRITE_SECURE_SETTINGS": ("Change secure system settings", "gearshape.2.fill", .gray, .system, true),
        "READ_LOGS": ("Read system logs", "doc.text.magnifyingglass", .gray, .system, true),
        "BIND_ACCESSIBILITY_SERVICE": ("Accessibility service", "accessibility", .blue, .special, true),
        "BIND_DEVICE_ADMIN": ("Device administrator", "lock.shield", .red, .special, true),
        "MOUNT_UNMOUNT_FILESYSTEMS": ("Mount and unmount storage", "externaldrive", .gray, .system, false),
        "CHANGE_COMPONENT_ENABLED_STATE": ("Enable and disable app components", "switch.2", .gray, .system, false),
        "CAPTURE_AUDIO_OUTPUT": ("Record audio from other apps", "waveform", .orange, .system, true),
        "READ_PRIVILEGED_PHONE_STATE": ("Read device identifiers", "phone", .green, .system, true),
        // Power and scheduling
        "RECEIVE_BOOT_COMPLETED": ("Start when the device turns on", "power", .gray, .normal, false),
        "WAKE_LOCK": ("Keep the device awake", "moon.zzz", .gray, .normal, false),
        "DISABLE_KEYGUARD": ("Disable the screen lock", "lock.open", .gray, .normal, false),
        "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS": ("Run without battery limits", "battery.100.bolt", .green, .special, false),
        "SCHEDULE_EXACT_ALARM": ("Exact alarms", "alarm", .orange, .special, false),
        "USE_EXACT_ALARM": ("Exact alarms", "alarm", .orange, .normal, false),
        "FOREGROUND_SERVICE": ("Run foreground services", "gearshape.2", .gray, .normal, false),
        "VIBRATE": ("Control vibration", "iphone.radiowaves.left.and.right", .gray, .normal, false),
        "FLASHLIGHT": ("Flashlight", "flashlight.on.fill", .gray, .normal, false),
        "EXPAND_STATUS_BAR": ("Expand the status bar", "menubar.rectangle", .gray, .normal, false),
        "SET_WALLPAPER": ("Set the wallpaper", "photo.artframe", .gray, .normal, false),
        "MODIFY_AUDIO_SETTINGS": ("Change audio settings", "speaker.wave.2", .gray, .normal, false),
        "READ_SYNC_SETTINGS": ("Read sync settings", "arrow.triangle.2.circlepath", .gray, .normal, false),
        "WRITE_SYNC_SETTINGS": ("Change sync settings", "arrow.triangle.2.circlepath", .gray, .normal, false),
        "USE_BIOMETRIC": ("Biometric sign-in", "touchid", .pink, .normal, false),
        "USE_FINGERPRINT": ("Fingerprint sign-in", "touchid", .pink, .normal, false),
        "INSTALL_SHORTCUT": ("Add home screen shortcuts", "plus.app", .gray, .normal, false),
        "REQUEST_COMPANION_RUN_IN_BACKGROUND": ("Run in the background for a companion device", "applewatch", .gray, .normal, false),
        // Google Play services
        "com.google.android.c2dm.permission.RECEIVE": ("Push messages", "bell", .red, .normal, false),
        "com.google.android.gms.permission.AD_ID": ("Advertising ID", "megaphone", .yellow, .normal, true),
        "com.google.android.gms.permission.ACTIVITY_RECOGNITION": ("Physical activity", "figure.walk", .green, .runtime, false),
        "com.android.vending.BILLING": ("In-app purchases", "creditcard", .green, .normal, false),
        "com.android.vending.CHECK_LICENSE": ("Google Play licence check", "checkmark.seal", .gray, .normal, false),
        "com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE": ("Install referrer (attribution)", "arrow.down.app", .yellow, .normal, false),
        "ACCESS_ADSERVICES_AD_ID": ("Advertising ID (Privacy Sandbox)", "megaphone", .yellow, .normal, true),
        "ACCESS_ADSERVICES_ATTRIBUTION": ("Ad attribution", "megaphone", .yellow, .normal, false),
        "ACCESS_ADSERVICES_TOPICS": ("Ad topics", "megaphone", .yellow, .normal, false),
        "com.google.android.providers.gsf.permission.READ_GSERVICES": ("Read Google service settings", "gearshape", .gray, .normal, false),
    ]
}

/// System integrations an app declares through its components: accessibility services, keyboards,
/// VPNs, device administrators and the like.
struct AndroidIntegration: Equatable {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: InspectorTint
    let sensitive: Bool

    /// From a component's `android:permission` (what the system requires to bind to it).
    static func forBindPermission(_ permission: String) -> AndroidIntegration? {
        let short = permission.hasPrefix("android.permission.") ? String(permission.dropFirst("android.permission.".count)) : permission
        switch short {
        case "BIND_ACCESSIBILITY_SERVICE":
            return AndroidIntegration(title: "Accessibility service", subtitle: "Can read the screen and act on other apps once turned on", symbol: "accessibility", tint: .blue, sensitive: true)
        case "BIND_NOTIFICATION_LISTENER_SERVICE":
            return AndroidIntegration(title: "Notification access", subtitle: "Can read every notification once allowed", symbol: "bell.badge", tint: .red, sensitive: true)
        case "BIND_DEVICE_ADMIN":
            return AndroidIntegration(title: "Device administrator", subtitle: "Can lock the device, enforce policies or erase it once activated", symbol: "lock.shield", tint: .red, sensitive: true)
        case "BIND_VPN_SERVICE":
            return AndroidIntegration(title: "VPN", subtitle: "Can route all network traffic", symbol: "network.badge.shield.half.filled", tint: .blue, sensitive: true)
        case "BIND_INPUT_METHOD":
            return AndroidIntegration(title: "Keyboard", subtitle: "Sees everything typed while it’s the active keyboard", symbol: "keyboard", tint: .gray, sensitive: true)
        case "BIND_AUTOFILL_SERVICE":
            return AndroidIntegration(title: "Autofill service", subtitle: "Fills in passwords and forms in other apps", symbol: "rectangle.and.pencil.and.ellipsis", tint: .blue, sensitive: true)
        case "BIND_CREDENTIAL_PROVIDER_SERVICE":
            return AndroidIntegration(title: "Passkey and password provider", subtitle: "Offers sign-in credentials to other apps", symbol: "person.badge.key", tint: .blue, sensitive: false)
        case "BIND_WALLPAPER":
            return AndroidIntegration(title: "Live wallpaper", subtitle: "Draws the home screen background", symbol: "photo.artframe", tint: .teal, sensitive: false)
        case "BIND_QUICK_SETTINGS_TILE":
            return AndroidIntegration(title: "Quick Settings tile", subtitle: "Adds a tile to Quick Settings", symbol: "square.grid.2x2", tint: .gray, sensitive: false)
        case "BIND_DREAM_SERVICE":
            return AndroidIntegration(title: "Screen saver", subtitle: "Shows while the device is charging or docked", symbol: "sparkles.tv", tint: .indigo, sensitive: false)
        case "BIND_INCALL_SERVICE":
            return AndroidIntegration(title: "Phone app", subtitle: "Can replace the phone app’s in-call screen", symbol: "phone.fill", tint: .green, sensitive: true)
        case "BIND_SCREENING_SERVICE":
            return AndroidIntegration(title: "Call screening", subtitle: "Sees incoming calls and can block them", symbol: "phone.badge.checkmark", tint: .green, sensitive: true)
        case "BIND_TELECOM_CONNECTION_SERVICE":
            return AndroidIntegration(title: "Calling service", subtitle: "Places and receives calls", symbol: "phone.connection", tint: .green, sensitive: false)
        case "BIND_NFC_SERVICE":
            return AndroidIntegration(title: "NFC card emulation", subtitle: "Acts as a contactless card, such as for payments", symbol: "wave.3.right", tint: .gray, sensitive: false)
        case "BIND_PRINT_SERVICE":
            return AndroidIntegration(title: "Print service", subtitle: "Adds a printer to the print dialog", symbol: "printer", tint: .gray, sensitive: false)
        case "BIND_CONTROLS":
            return AndroidIntegration(title: "Device controls", subtitle: "Adds smart home controls to the system", symbol: "lightswitch.on", tint: .orange, sensitive: false)
        case "BIND_TV_INPUT":
            return AndroidIntegration(title: "TV input", subtitle: "Provides TV channels", symbol: "tv", tint: .gray, sensitive: false)
        case "BIND_COMPANION_DEVICE_SERVICE":
            return AndroidIntegration(title: "Companion device service", subtitle: "Stays connected to a paired device", symbol: "applewatch", tint: .gray, sensitive: false)
        case "BIND_CARRIER_SERVICES", "BIND_CARRIER_MESSAGING_SERVICE":
            return AndroidIntegration(title: "Carrier service", subtitle: "Integrates with the mobile carrier", symbol: "antenna.radiowaves.left.and.right", tint: .green, sensitive: false)
        default:
            return nil
        }
    }

    /// From an intent-filter action.
    static func forAction(_ action: String) -> AndroidIntegration? {
        switch action {
        case "android.appwidget.action.APPWIDGET_UPDATE":
            return AndroidIntegration(title: "Home screen widget", subtitle: "Offers widgets for the home screen", symbol: "square.grid.2x2.fill", tint: .blue, sensitive: false)
        case "android.intent.action.SEND", "android.intent.action.SEND_MULTIPLE":
            return AndroidIntegration(title: "Share target", subtitle: "Appears in the share sheet", symbol: "square.and.arrow.up", tint: .blue, sensitive: false)
        case "android.provider.Telephony.SMS_RECEIVED", "android.provider.Telephony.SMS_DELIVER":
            return AndroidIntegration(title: "SMS receiver", subtitle: "Is told about incoming text messages", symbol: "message", tint: .green, sensitive: true)
        case "android.intent.action.BOOT_COMPLETED", "android.intent.action.LOCKED_BOOT_COMPLETED":
            return AndroidIntegration(title: "Starts at boot", subtitle: "Runs when the device turns on", symbol: "power", tint: .gray, sensitive: false)
        case "android.intent.action.PROCESS_TEXT":
            return AndroidIntegration(title: "Text selection action", subtitle: "Appears in the menu for selected text", symbol: "text.cursor", tint: .gray, sensitive: false)
        case "android.service.chooser.ChooserTargetService", "android.intent.action.CREATE_SHORTCUT":
            return nil
        default:
            return nil
        }
    }
}

/// Android version names for API levels.
enum AndroidVersions {
    private static let names: [Int: String] = [
        1: "1.0", 2: "1.1", 3: "1.5", 4: "1.6", 5: "2.0", 6: "2.0.1", 7: "2.1", 8: "2.2", 9: "2.3", 10: "2.3.3",
        11: "3.0", 12: "3.1", 13: "3.2", 14: "4.0", 15: "4.0.3", 16: "4.1", 17: "4.2", 18: "4.3", 19: "4.4", 20: "4.4W",
        21: "5.0", 22: "5.1", 23: "6.0", 24: "7.0", 25: "7.1", 26: "8.0", 27: "8.1", 28: "9", 29: "10", 30: "11",
        31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16",
    ]

    /// "Android 8.0 (API 26)", or "API 40" when the name isn't known.
    static func describe(_ api: Int) -> String {
        if let name = names[api] { return "Android \(name) (API \(api))" }
        return "API \(api)"
    }

    /// "Android 8.0+" for compact places.
    static func short(_ api: Int) -> String {
        if let name = names[api] { return "Android \(name)+" }
        return "API \(api)+"
    }
}
