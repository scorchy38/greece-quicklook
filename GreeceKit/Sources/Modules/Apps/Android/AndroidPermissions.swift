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
            let title = String(localized: "Foreground service (\(kind))", bundle: .greeceKit,
                               comment: "Android permission. The argument is a service type taken from the permission’s name, such as “camera” or “data sync”")
            return AndroidPermission(name: name, title: title, symbol: "gearshape.2", tint: .gray, level: .normal, sensitive: false)
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
        "ACCESS_FINE_LOCATION": (String(localized: "Precise location", bundle: .greeceKit, comment: "Android permission"), "location.fill", .blue, .runtime, false),
        "ACCESS_COARSE_LOCATION": (String(localized: "Approximate location", bundle: .greeceKit, comment: "Android permission"), "location", .blue, .runtime, false),
        "ACCESS_BACKGROUND_LOCATION": (String(localized: "Location in the background", bundle: .greeceKit), "location.circle", .blue, .runtime, true),
        "ACCESS_MEDIA_LOCATION": (String(localized: "Locations in your photos", bundle: .greeceKit), "mappin.and.ellipse", .blue, .runtime, false),
        "ACCESS_LOCATION_EXTRA_COMMANDS": (String(localized: "Extra location provider commands", bundle: .greeceKit), "location", .blue, .normal, false),
        "ACCESS_MOCK_LOCATION": (String(localized: "Fake its location", bundle: .greeceKit), "location.slash", .blue, .system, false),
        // Camera, microphone, sensors
        "CAMERA": (String(localized: "Camera", bundle: .greeceKit, comment: "Android permission"), "camera.fill", .gray, .runtime, false),
        "RECORD_AUDIO": (String(localized: "Microphone", bundle: .greeceKit, comment: "Android permission"), "mic.fill", .orange, .runtime, false),
        "BODY_SENSORS": (String(localized: "Body sensors", bundle: .greeceKit, comment: "Android permission"), "heart.fill", .pink, .runtime, false),
        "BODY_SENSORS_BACKGROUND": (String(localized: "Body sensors in the background", bundle: .greeceKit), "heart.circle", .pink, .runtime, true),
        "ACTIVITY_RECOGNITION": (String(localized: "Physical activity", bundle: .greeceKit, comment: "Android permission"), "figure.walk", .green, .runtime, false),
        "HIGH_SAMPLING_RATE_SENSORS": (String(localized: "High-rate motion sensors", bundle: .greeceKit), "gyroscope", .gray, .normal, false),
        "DETECT_SCREEN_CAPTURE": (String(localized: "Detect screenshots", bundle: .greeceKit, comment: "Android permission"), "camera.viewfinder", .gray, .normal, false),
        // Contacts, calendar, accounts
        "READ_CONTACTS": (String(localized: "Read your contacts", bundle: .greeceKit), "person.crop.circle", .brown, .runtime, false),
        "WRITE_CONTACTS": (String(localized: "Change your contacts", bundle: .greeceKit), "person.crop.circle.badge.plus", .brown, .runtime, false),
        "GET_ACCOUNTS": (String(localized: "Find accounts on the device", bundle: .greeceKit), "person.2", .gray, .runtime, false),
        "READ_PROFILE": (String(localized: "Read your profile card", bundle: .greeceKit), "person.text.rectangle", .brown, .normal, false),
        "READ_CALENDAR": (String(localized: "Read your calendar", bundle: .greeceKit), "calendar", .red, .runtime, false),
        "WRITE_CALENDAR": (String(localized: "Change your calendar", bundle: .greeceKit), "calendar.badge.plus", .red, .runtime, false),
        "MANAGE_ACCOUNTS": (String(localized: "Manage accounts", bundle: .greeceKit, comment: "Android permission"), "person.2.badge.gearshape", .gray, .normal, false),
        "USE_CREDENTIALS": (String(localized: "Use account credentials", bundle: .greeceKit), "key", .gray, .normal, false),
        "AUTHENTICATE_ACCOUNTS": (String(localized: "Create accounts and set passwords", bundle: .greeceKit), "key", .gray, .normal, false),
        // Phone, calls, SMS
        "READ_PHONE_STATE": (String(localized: "Phone status and identity", bundle: .greeceKit), "phone", .green, .runtime, false),
        "READ_PHONE_NUMBERS": (String(localized: "Read phone numbers", bundle: .greeceKit), "phone", .green, .runtime, false),
        "CALL_PHONE": (String(localized: "Make phone calls", bundle: .greeceKit), "phone.arrow.up.right", .green, .runtime, true),
        "ANSWER_PHONE_CALLS": (String(localized: "Answer phone calls", bundle: .greeceKit), "phone.arrow.down.left", .green, .runtime, false),
        "MANAGE_OWN_CALLS": (String(localized: "Route its own calls", bundle: .greeceKit), "phone.connection", .green, .normal, false),
        "PROCESS_OUTGOING_CALLS": (String(localized: "Reroute outgoing calls", bundle: .greeceKit), "phone.arrow.right", .green, .runtime, true),
        "READ_CALL_LOG": (String(localized: "Read your call log", bundle: .greeceKit), "list.bullet.rectangle", .green, .runtime, true),
        "WRITE_CALL_LOG": (String(localized: "Change your call log", bundle: .greeceKit), "list.bullet.rectangle", .green, .runtime, true),
        "ADD_VOICEMAIL": (String(localized: "Add voicemail", bundle: .greeceKit, comment: "Android permission"), "recordingtape", .green, .runtime, false),
        "USE_SIP": (String(localized: "Internet calls (SIP)", bundle: .greeceKit), "phone.badge.waveform", .green, .runtime, false),
        "SEND_SMS": (String(localized: "Send text messages", bundle: .greeceKit), "message.fill", .green, .runtime, true),
        "RECEIVE_SMS": (String(localized: "Receive text messages", bundle: .greeceKit), "message", .green, .runtime, true),
        "READ_SMS": (String(localized: "Read your text messages", bundle: .greeceKit), "message", .green, .runtime, true),
        "RECEIVE_MMS": (String(localized: "Receive picture messages", bundle: .greeceKit), "message", .green, .runtime, true),
        "RECEIVE_WAP_PUSH": (String(localized: "Receive WAP push messages", bundle: .greeceKit), "message", .green, .runtime, true),
        "READ_CELL_BROADCASTS": (String(localized: "Read emergency broadcasts", bundle: .greeceKit), "exclamationmark.bubble", .green, .runtime, false),
        // Storage and media
        "READ_EXTERNAL_STORAGE": (String(localized: "Read shared storage", bundle: .greeceKit), "folder", .blue, .runtime, false),
        "WRITE_EXTERNAL_STORAGE": (String(localized: "Change shared storage", bundle: .greeceKit), "folder.badge.plus", .blue, .runtime, false),
        "MANAGE_EXTERNAL_STORAGE": (String(localized: "All files access", bundle: .greeceKit), "externaldrive.fill", .blue, .special, true),
        "READ_MEDIA_IMAGES": (String(localized: "Photos", bundle: .greeceKit, comment: "Android permission"), "photo.on.rectangle", .orange, .runtime, false),
        "READ_MEDIA_VIDEO": (String(localized: "Videos", bundle: .greeceKit, comment: "Android permission"), "film", .orange, .runtime, false),
        "READ_MEDIA_AUDIO": (String(localized: "Music and audio", bundle: .greeceKit), "music.note", .pink, .runtime, false),
        "READ_MEDIA_VISUAL_USER_SELECTED": (String(localized: "Selected photos and videos", bundle: .greeceKit), "photo", .orange, .runtime, false),
        // Notifications and alerts
        "POST_NOTIFICATIONS": (String(localized: "Notifications", bundle: .greeceKit, comment: "Android permission"), "bell.badge.fill", .red, .runtime, false),
        "USE_FULL_SCREEN_INTENT": (String(localized: "Full-screen notifications", bundle: .greeceKit, comment: "Android permission"), "rectangle.inset.filled", .red, .special, false),
        "ACCESS_NOTIFICATION_POLICY": (String(localized: "Do Not Disturb access", bundle: .greeceKit), "moon.fill", .indigo, .special, false),
        "SYSTEM_ALERT_WINDOW": (String(localized: "Draw over other apps", bundle: .greeceKit), "rectangle.on.rectangle", .purple, .special, true),
        // Nearby devices
        "BLUETOOTH": (String(localized: "Connect to paired Bluetooth devices", bundle: .greeceKit), "antenna.radiowaves.left.and.right", .blue, .normal, false),
        "BLUETOOTH_ADMIN": (String(localized: "Pair with Bluetooth devices", bundle: .greeceKit), "antenna.radiowaves.left.and.right", .blue, .normal, false),
        "BLUETOOTH_SCAN": (String(localized: "Find nearby Bluetooth devices", bundle: .greeceKit), "antenna.radiowaves.left.and.right", .blue, .runtime, false),
        "BLUETOOTH_CONNECT": (String(localized: "Connect to nearby Bluetooth devices", bundle: .greeceKit), "antenna.radiowaves.left.and.right", .blue, .runtime, false),
        "BLUETOOTH_ADVERTISE": (String(localized: "Advertise to nearby Bluetooth devices", bundle: .greeceKit), "antenna.radiowaves.left.and.right", .blue, .runtime, false),
        "NEARBY_WIFI_DEVICES": (String(localized: "Nearby Wi-Fi devices", bundle: .greeceKit), "wifi", .blue, .runtime, false),
        "UWB_RANGING": (String(localized: "Ultra-wideband ranging", bundle: .greeceKit, comment: "Android permission"), "dot.radiowaves.left.and.right", .blue, .runtime, false),
        "NFC": ("NFC", "wave.3.right", .gray, .normal, false),
        "TRANSMIT_IR": (String(localized: "Infrared transmitter", bundle: .greeceKit, comment: "Android permission"), "av.remote", .gray, .normal, false),
        // Network
        "INTERNET": (String(localized: "Full network access", bundle: .greeceKit), "network", .blue, .normal, false),
        "ACCESS_NETWORK_STATE": (String(localized: "View network connections", bundle: .greeceKit), "network", .gray, .normal, false),
        "ACCESS_WIFI_STATE": (String(localized: "View Wi-Fi connections", bundle: .greeceKit), "wifi", .gray, .normal, false),
        "CHANGE_WIFI_STATE": (String(localized: "Connect to and disconnect from Wi-Fi", bundle: .greeceKit), "wifi", .gray, .normal, false),
        "CHANGE_NETWORK_STATE": (String(localized: "Change network connectivity", bundle: .greeceKit), "network", .gray, .normal, false),
        "CHANGE_WIFI_MULTICAST_STATE": (String(localized: "Receive Wi-Fi multicast", bundle: .greeceKit), "wifi", .gray, .normal, false),
        // Apps and system
        "REQUEST_INSTALL_PACKAGES": (String(localized: "Install other apps", bundle: .greeceKit), "square.and.arrow.down", .indigo, .special, true),
        "REQUEST_DELETE_PACKAGES": (String(localized: "Ask to uninstall apps", bundle: .greeceKit), "trash", .indigo, .normal, false),
        "INSTALL_PACKAGES": (String(localized: "Install apps silently", bundle: .greeceKit), "square.and.arrow.down.fill", .indigo, .system, true),
        "DELETE_PACKAGES": (String(localized: "Uninstall apps silently", bundle: .greeceKit), "trash.fill", .indigo, .system, true),
        "QUERY_ALL_PACKAGES": (String(localized: "See all installed apps", bundle: .greeceKit), "square.grid.3x3", .indigo, .special, true),
        "PACKAGE_USAGE_STATS": (String(localized: "App usage access", bundle: .greeceKit), "chart.bar.fill", .indigo, .special, true),
        "GET_TASKS": (String(localized: "See running apps", bundle: .greeceKit), "square.stack.3d.up", .gray, .normal, false),
        "REORDER_TASKS": (String(localized: "Reorder running apps", bundle: .greeceKit), "square.stack.3d.up", .gray, .normal, false),
        "KILL_BACKGROUND_PROCESSES": (String(localized: "Close other apps", bundle: .greeceKit), "xmark.app", .gray, .normal, false),
        "WRITE_SETTINGS": (String(localized: "Change system settings", bundle: .greeceKit), "gearshape.fill", .gray, .special, true),
        "WRITE_SECURE_SETTINGS": (String(localized: "Change secure system settings", bundle: .greeceKit), "gearshape.2.fill", .gray, .system, true),
        "READ_LOGS": (String(localized: "Read system logs", bundle: .greeceKit), "doc.text.magnifyingglass", .gray, .system, true),
        "BIND_ACCESSIBILITY_SERVICE": (String(localized: "Accessibility service", bundle: .greeceKit, comment: "Android permission"), "accessibility", .blue, .special, true),
        "BIND_DEVICE_ADMIN": (String(localized: "Device administrator", bundle: .greeceKit, comment: "Android permission"), "lock.shield", .red, .special, true),
        "MOUNT_UNMOUNT_FILESYSTEMS": (String(localized: "Mount and unmount storage", bundle: .greeceKit), "externaldrive", .gray, .system, false),
        "CHANGE_COMPONENT_ENABLED_STATE": (String(localized: "Enable and disable app components", bundle: .greeceKit), "switch.2", .gray, .system, false),
        "CAPTURE_AUDIO_OUTPUT": (String(localized: "Record audio from other apps", bundle: .greeceKit), "waveform", .orange, .system, true),
        "READ_PRIVILEGED_PHONE_STATE": (String(localized: "Read device identifiers", bundle: .greeceKit), "phone", .green, .system, true),
        // Power and scheduling
        "RECEIVE_BOOT_COMPLETED": (String(localized: "Start when the device turns on", bundle: .greeceKit), "power", .gray, .normal, false),
        "WAKE_LOCK": (String(localized: "Keep the device awake", bundle: .greeceKit), "moon.zzz", .gray, .normal, false),
        "DISABLE_KEYGUARD": (String(localized: "Disable the screen lock", bundle: .greeceKit), "lock.open", .gray, .normal, false),
        "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS": (String(localized: "Run without battery limits", bundle: .greeceKit), "battery.100.bolt", .green, .special, false),
        "SCHEDULE_EXACT_ALARM": (String(localized: "Exact alarms", bundle: .greeceKit, comment: "Android permission"), "alarm", .orange, .special, false),
        "USE_EXACT_ALARM": (String(localized: "Exact alarms", bundle: .greeceKit, comment: "Android permission"), "alarm", .orange, .normal, false),
        "FOREGROUND_SERVICE": (String(localized: "Run foreground services", bundle: .greeceKit), "gearshape.2", .gray, .normal, false),
        "VIBRATE": (String(localized: "Control vibration", bundle: .greeceKit, comment: "Android permission"), "iphone.radiowaves.left.and.right", .gray, .normal, false),
        "FLASHLIGHT": (String(localized: "Flashlight", bundle: .greeceKit, comment: "Android permission"), "flashlight.on.fill", .gray, .normal, false),
        "EXPAND_STATUS_BAR": (String(localized: "Expand the status bar", bundle: .greeceKit), "menubar.rectangle", .gray, .normal, false),
        "SET_WALLPAPER": (String(localized: "Set the wallpaper", bundle: .greeceKit), "photo.artframe", .gray, .normal, false),
        "MODIFY_AUDIO_SETTINGS": (String(localized: "Change audio settings", bundle: .greeceKit), "speaker.wave.2", .gray, .normal, false),
        "READ_SYNC_SETTINGS": (String(localized: "Read sync settings", bundle: .greeceKit), "arrow.triangle.2.circlepath", .gray, .normal, false),
        "WRITE_SYNC_SETTINGS": (String(localized: "Change sync settings", bundle: .greeceKit), "arrow.triangle.2.circlepath", .gray, .normal, false),
        "USE_BIOMETRIC": (String(localized: "Biometric sign-in", bundle: .greeceKit, comment: "Android permission"), "touchid", .pink, .normal, false),
        "USE_FINGERPRINT": (String(localized: "Fingerprint sign-in", bundle: .greeceKit, comment: "Android permission"), "touchid", .pink, .normal, false),
        "INSTALL_SHORTCUT": (String(localized: "Add home screen shortcuts", bundle: .greeceKit), "plus.app", .gray, .normal, false),
        "REQUEST_COMPANION_RUN_IN_BACKGROUND": (String(localized: "Run in the background for a companion device", bundle: .greeceKit), "applewatch", .gray, .normal, false),
        // Google Play services
        "com.google.android.c2dm.permission.RECEIVE": (String(localized: "Push messages", bundle: .greeceKit, comment: "Android permission"), "bell", .red, .normal, false),
        "com.google.android.gms.permission.AD_ID": (String(localized: "Advertising ID", bundle: .greeceKit, comment: "Android permission"), "megaphone", .yellow, .normal, true),
        "com.google.android.gms.permission.ACTIVITY_RECOGNITION": (String(localized: "Physical activity", bundle: .greeceKit, comment: "Android permission"), "figure.walk", .green, .runtime, false),
        "com.android.vending.BILLING": (String(localized: "In-app purchases", bundle: .greeceKit, comment: "Android permission"), "creditcard", .green, .normal, false),
        "com.android.vending.CHECK_LICENSE": (String(localized: "Google Play licence check", bundle: .greeceKit), "checkmark.seal", .gray, .normal, false),
        "com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE": (String(localized: "Install referrer (attribution)", bundle: .greeceKit), "arrow.down.app", .yellow, .normal, false),
        "ACCESS_ADSERVICES_AD_ID": (String(localized: "Advertising ID (Privacy Sandbox)", bundle: .greeceKit), "megaphone", .yellow, .normal, true),
        "ACCESS_ADSERVICES_ATTRIBUTION": (String(localized: "Ad attribution", bundle: .greeceKit, comment: "Android permission"), "megaphone", .yellow, .normal, false),
        "ACCESS_ADSERVICES_TOPICS": (String(localized: "Ad topics", bundle: .greeceKit, comment: "Android permission"), "megaphone", .yellow, .normal, false),
        "com.google.android.providers.gsf.permission.READ_GSERVICES": (String(localized: "Read Google service settings", bundle: .greeceKit), "gearshape", .gray, .normal, false),
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
            return AndroidIntegration(title: String(localized: "Accessibility service", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Can read the screen and act on other apps once turned on", bundle: .greeceKit), symbol: "accessibility", tint: .blue, sensitive: true)
        case "BIND_NOTIFICATION_LISTENER_SERVICE":
            return AndroidIntegration(title: String(localized: "Notification access", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Can read every notification once allowed", bundle: .greeceKit), symbol: "bell.badge", tint: .red, sensitive: true)
        case "BIND_DEVICE_ADMIN":
            return AndroidIntegration(title: String(localized: "Device administrator", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Can lock the device, enforce policies or erase it once activated", bundle: .greeceKit), symbol: "lock.shield", tint: .red, sensitive: true)
        case "BIND_VPN_SERVICE":
            return AndroidIntegration(title: String(localized: "VPN", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Can route all network traffic", bundle: .greeceKit), symbol: "network.badge.shield.half.filled", tint: .blue, sensitive: true)
        case "BIND_INPUT_METHOD":
            return AndroidIntegration(title: String(localized: "Keyboard", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Sees everything typed while it’s the active keyboard", bundle: .greeceKit), symbol: "keyboard", tint: .gray, sensitive: true)
        case "BIND_AUTOFILL_SERVICE":
            return AndroidIntegration(title: String(localized: "Autofill service", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Fills in passwords and forms in other apps", bundle: .greeceKit), symbol: "rectangle.and.pencil.and.ellipsis", tint: .blue, sensitive: true)
        case "BIND_CREDENTIAL_PROVIDER_SERVICE":
            return AndroidIntegration(title: String(localized: "Passkey and password provider", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Offers sign-in credentials to other apps", bundle: .greeceKit), symbol: "person.badge.key", tint: .blue, sensitive: false)
        case "BIND_WALLPAPER":
            return AndroidIntegration(title: String(localized: "Live wallpaper", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Draws the home screen background", bundle: .greeceKit), symbol: "photo.artframe", tint: .teal, sensitive: false)
        case "BIND_QUICK_SETTINGS_TILE":
            return AndroidIntegration(title: String(localized: "Quick Settings tile", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Adds a tile to Quick Settings", bundle: .greeceKit), symbol: "square.grid.2x2", tint: .gray, sensitive: false)
        case "BIND_DREAM_SERVICE":
            return AndroidIntegration(title: String(localized: "Screen saver", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Shows while the device is charging or docked", bundle: .greeceKit), symbol: "sparkles.tv", tint: .indigo, sensitive: false)
        case "BIND_INCALL_SERVICE":
            return AndroidIntegration(title: String(localized: "Phone app", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Can replace the phone app’s in-call screen", bundle: .greeceKit), symbol: "phone.fill", tint: .green, sensitive: true)
        case "BIND_SCREENING_SERVICE":
            return AndroidIntegration(title: String(localized: "Call screening", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Sees incoming calls and can block them", bundle: .greeceKit), symbol: "phone.badge.checkmark", tint: .green, sensitive: true)
        case "BIND_TELECOM_CONNECTION_SERVICE":
            return AndroidIntegration(title: String(localized: "Calling service", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Places and receives calls", bundle: .greeceKit), symbol: "phone.connection", tint: .green, sensitive: false)
        case "BIND_NFC_SERVICE":
            return AndroidIntegration(title: String(localized: "NFC card emulation", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Acts as a contactless card, such as for payments", bundle: .greeceKit), symbol: "wave.3.right", tint: .gray, sensitive: false)
        case "BIND_PRINT_SERVICE":
            return AndroidIntegration(title: String(localized: "Print service", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Adds a printer to the print dialog", bundle: .greeceKit), symbol: "printer", tint: .gray, sensitive: false)
        case "BIND_CONTROLS":
            return AndroidIntegration(title: String(localized: "Device controls", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Adds smart home controls to the system", bundle: .greeceKit), symbol: "lightswitch.on", tint: .orange, sensitive: false)
        case "BIND_TV_INPUT":
            return AndroidIntegration(title: String(localized: "TV input", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Provides TV channels", bundle: .greeceKit), symbol: "tv", tint: .gray, sensitive: false)
        case "BIND_COMPANION_DEVICE_SERVICE":
            return AndroidIntegration(title: String(localized: "Companion device service", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Stays connected to a paired device", bundle: .greeceKit), symbol: "applewatch", tint: .gray, sensitive: false)
        case "BIND_CARRIER_SERVICES", "BIND_CARRIER_MESSAGING_SERVICE":
            return AndroidIntegration(title: String(localized: "Carrier service", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Integrates with the mobile carrier", bundle: .greeceKit), symbol: "antenna.radiowaves.left.and.right", tint: .green, sensitive: false)
        default:
            return nil
        }
    }

    /// From an intent-filter action.
    static func forAction(_ action: String) -> AndroidIntegration? {
        switch action {
        case "android.appwidget.action.APPWIDGET_UPDATE":
            return AndroidIntegration(title: String(localized: "Home screen widget", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Offers widgets for the home screen", bundle: .greeceKit), symbol: "square.grid.2x2.fill", tint: .blue, sensitive: false)
        case "android.intent.action.SEND", "android.intent.action.SEND_MULTIPLE":
            return AndroidIntegration(title: String(localized: "Share target", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Appears in the share sheet", bundle: .greeceKit), symbol: "square.and.arrow.up", tint: .blue, sensitive: false)
        case "android.provider.Telephony.SMS_RECEIVED", "android.provider.Telephony.SMS_DELIVER":
            return AndroidIntegration(title: String(localized: "SMS receiver", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Is told about incoming text messages", bundle: .greeceKit), symbol: "message", tint: .green, sensitive: true)
        case "android.intent.action.BOOT_COMPLETED", "android.intent.action.LOCKED_BOOT_COMPLETED":
            return AndroidIntegration(title: String(localized: "Starts at boot", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Runs when the device turns on", bundle: .greeceKit), symbol: "power", tint: .gray, sensitive: false)
        case "android.intent.action.PROCESS_TEXT":
            return AndroidIntegration(title: String(localized: "Text selection action", bundle: .greeceKit, comment: "A system integration an Android app declares"),
                                      subtitle: String(localized: "Appears in the menu for selected text", bundle: .greeceKit), symbol: "text.cursor", tint: .gray, sensitive: false)
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
        let level = String(api)
        if let name = names[api] {
            return String(localized: "Android \(name) (API \(level))", bundle: .greeceKit,
                          comment: "An Android version and its API level, such as “Android 8.0 (API 26)”")
        }
        return String(localized: "API \(level)", bundle: .greeceKit, comment: "An Android API level, such as “API 40”")
    }

    /// "Android 8.0+" for compact places.
    static func short(_ api: Int) -> String {
        let level = String(api)
        if let name = names[api] {
            return String(localized: "Android \(name)+", bundle: .greeceKit, comment: "Info bar detail: the oldest Android version an app runs on, such as “Android 8.0+”")
        }
        return String(localized: "API \(level)+", bundle: .greeceKit, comment: "Info bar detail: the oldest Android API level an app runs on, such as “API 40+”")
    }
}
