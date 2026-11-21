import Foundation

/// A capability, permission or extension point described for people: a title, a symbol and a tint
/// for its tile, and how much it deserves attention. The raw key stays available as help text.
struct CatalogEntry {
    let title: String
    let symbol: String
    let tint: InspectorTint
    var tone: InspectorTone = .neutral
    var detail: String? = nil
}

enum EntitlementCatalog {
    /// Entitlements that only say "this is how the app was signed" add noise, not information.
    static let hidden: Set<String> = [
        "com.apple.application-identifier", "application-identifier", "com.apple.developer.team-identifier",
        "keychain-access-groups-legacy", "get-task-allow-legacy", "beta-reports-active",
    ]

    static func describe(_ key: String, value: Any) -> CatalogEntry? {
        if let entry = entries[key] { return entry }
        if key.hasPrefix("com.apple.security.temporary-exception.") {
            let kind = key.dropFirst("com.apple.security.temporary-exception.".count)
            return CatalogEntry(title: "Sandbox exception: \(kind)", symbol: "exclamationmark.shield", tint: .orange, tone: .caution)
        }
        if key.hasPrefix("com.apple.private.") {
            return CatalogEntry(title: "Private Apple entitlement", symbol: "lock.shield", tint: .gray, detail: key)
        }
        return nil
    }

    static let entries: [String: CatalogEntry] = [
        // Sandbox
        "com.apple.security.app-sandbox": .init(title: "App Sandbox", symbol: "shield.lefthalf.filled", tint: .green, tone: .positive),
        "com.apple.security.network.client": .init(title: "Outgoing network connections", symbol: "network", tint: .blue),
        "com.apple.security.network.server": .init(title: "Incoming network connections", symbol: "antenna.radiowaves.left.and.right", tint: .blue),
        "com.apple.security.device.camera": .init(title: "Camera", symbol: "camera.fill", tint: .gray),
        "com.apple.security.device.audio-input": .init(title: "Microphone", symbol: "mic.fill", tint: .orange),
        "com.apple.security.device.microphone": .init(title: "Microphone", symbol: "mic.fill", tint: .orange),
        "com.apple.security.device.usb": .init(title: "USB devices", symbol: "cable.connector", tint: .gray),
        "com.apple.security.device.bluetooth": .init(title: "Bluetooth devices", symbol: "dot.radiowaves.left.and.right", tint: .blue),
        "com.apple.security.device.serial": .init(title: "Serial ports", symbol: "cable.connector.horizontal", tint: .gray),
        "com.apple.security.print": .init(title: "Printing", symbol: "printer.fill", tint: .gray),
        "com.apple.security.personal-information.addressbook": .init(title: "Contacts", symbol: "person.crop.circle.fill", tint: .brown),
        "com.apple.security.personal-information.calendars": .init(title: "Calendars", symbol: "calendar", tint: .red),
        "com.apple.security.personal-information.location": .init(title: "Location", symbol: "location.fill", tint: .blue),
        "com.apple.security.personal-information.photos-library": .init(title: "Photos library", symbol: "photo.on.rectangle", tint: .orange),
        "com.apple.security.files.user-selected.read-only": .init(title: "Files you choose (read only)", symbol: "doc", tint: .blue),
        "com.apple.security.files.user-selected.read-write": .init(title: "Files you choose", symbol: "doc.badge.plus", tint: .blue),
        "com.apple.security.files.user-selected.executable": .init(title: "Creates executables you save", symbol: "terminal", tint: .gray),
        "com.apple.security.files.downloads.read-only": .init(title: "Downloads folder (read only)", symbol: "arrow.down.circle.fill", tint: .blue),
        "com.apple.security.files.downloads.read-write": .init(title: "Downloads folder", symbol: "arrow.down.circle.fill", tint: .blue),
        "com.apple.security.assets.pictures.read-only": .init(title: "Pictures folder (read only)", symbol: "photo", tint: .teal),
        "com.apple.security.assets.pictures.read-write": .init(title: "Pictures folder", symbol: "photo", tint: .teal),
        "com.apple.security.assets.music.read-only": .init(title: "Music folder (read only)", symbol: "music.note", tint: .pink),
        "com.apple.security.assets.music.read-write": .init(title: "Music folder", symbol: "music.note", tint: .pink),
        "com.apple.security.assets.movies.read-only": .init(title: "Movies folder (read only)", symbol: "film", tint: .indigo),
        "com.apple.security.assets.movies.read-write": .init(title: "Movies folder", symbol: "film", tint: .indigo),
        "com.apple.security.files.bookmarks.app-scope": .init(title: "Remembers files you open", symbol: "bookmark.fill", tint: .gray),
        "com.apple.security.files.bookmarks.document-scope": .init(title: "Remembers files documents refer to", symbol: "bookmark", tint: .gray),
        "com.apple.security.files.all": .init(title: "All files", symbol: "externaldrive.fill", tint: .gray, tone: .caution),
        "com.apple.security.automation.apple-events": .init(title: "Controls other apps", symbol: "applescript", tint: .gray, tone: .caution),
        "com.apple.security.scripting-targets": .init(title: "Scripts specific apps", symbol: "applescript", tint: .gray),
        "com.apple.security.application-groups": .init(title: "Shared app group", symbol: "square.stack.3d.up.fill", tint: .indigo),
        "com.apple.security.inherit": .init(title: "Inherits its parent’s sandbox", symbol: "arrow.down.right.and.arrow.up.left", tint: .green),
        "com.apple.security.virtualization": .init(title: "Virtual machines", symbol: "macwindow.on.rectangle", tint: .purple),
        "com.apple.security.hypervisor": .init(title: "Hypervisor", symbol: "cpu", tint: .purple),
        "com.apple.security.smartcard": .init(title: "Smart cards", symbol: "creditcard.fill", tint: .gray),
        "com.apple.security.network.vpn": .init(title: "VPN", symbol: "lock.shield", tint: .blue),

        // Hardened runtime exceptions
        "com.apple.security.cs.allow-jit": .init(title: "Generates code at runtime (JIT)", symbol: "bolt.fill", tint: .yellow, tone: .neutral),
        "com.apple.security.cs.allow-unsigned-executable-memory": .init(title: "Runs unsigned code in memory", symbol: "memorychip", tint: .orange, tone: .caution),
        "com.apple.security.cs.allow-dyld-environment-variables": .init(title: "Honours DYLD environment variables", symbol: "terminal", tint: .orange, tone: .caution),
        "com.apple.security.cs.disable-library-validation": .init(title: "Loads libraries signed by anyone", symbol: "puzzlepiece.extension.fill", tint: .orange, tone: .caution),
        "com.apple.security.cs.disable-executable-page-protection": .init(title: "Disables executable memory protection", symbol: "exclamationmark.triangle.fill", tint: .red, tone: .critical),
        "com.apple.security.cs.debugger": .init(title: "Debugs other processes", symbol: "ant.fill", tint: .orange, tone: .caution),
        "com.apple.security.get-task-allow": .init(title: "Debuggable", symbol: "ladybug.fill", tint: .orange, tone: .caution),
        "get-task-allow": .init(title: "Debuggable (development build)", symbol: "ladybug.fill", tint: .orange, tone: .caution),
        "com.apple.security.cs.jit-write-allowlist": .init(title: "JIT write allowlist", symbol: "bolt", tint: .yellow),

        // Enhanced security (macOS 26)
        "com.apple.security.hardened-process": .init(title: "Enhanced Security", symbol: "lock.shield.fill", tint: .green, tone: .positive),
        "com.apple.security.hardened-process.hardened-heap": .init(title: "Hardened memory allocator", symbol: "memorychip.fill", tint: .green, tone: .positive),
        "com.apple.security.hardened-process.enhanced-security-version": .init(title: "Enhanced Security version", symbol: "lock.shield", tint: .green),
        "com.apple.security.hardened-process.platform-restrictions": .init(title: "Platform restrictions", symbol: "lock.shield", tint: .green),
        "com.apple.security.hardened-process.dyld-ro": .init(title: "Read-only dynamic linker data", symbol: "lock.doc", tint: .green),
        "com.apple.security.hardened-process.checked-allocations": .init(title: "Checked memory allocations", symbol: "checkmark.shield", tint: .green),

        // iCloud, keychain, identity
        "com.apple.developer.icloud-container-identifiers": .init(title: "iCloud containers", symbol: "icloud.fill", tint: .cyan),
        "com.apple.developer.icloud-services": .init(title: "iCloud services", symbol: "icloud.fill", tint: .cyan),
        "com.apple.developer.ubiquity-container-identifiers": .init(title: "iCloud Drive", symbol: "icloud.and.arrow.up.fill", tint: .cyan),
        "com.apple.developer.ubiquity-kvstore-identifier": .init(title: "iCloud key-value storage", symbol: "icloud", tint: .cyan),
        "com.apple.developer.icloud-container-environment": .init(title: "iCloud environment", symbol: "icloud", tint: .cyan),
        "keychain-access-groups": .init(title: "Keychain groups", symbol: "key.fill", tint: .gray),
        "com.apple.developer.applesignin": .init(title: "Sign in with Apple", symbol: "apple.logo", tint: .gray),
        "com.apple.developer.authentication-services.autofill-credential-provider": .init(title: "Password AutoFill provider", symbol: "key.horizontal.fill", tint: .gray),
        "com.apple.developer.associated-domains": .init(title: "Associated domains", symbol: "link", tint: .blue),
        "com.apple.developer.associated-domains.applinks.read-write": .init(title: "Associated domains", symbol: "link", tint: .blue),
        "com.apple.developer.web-browser": .init(title: "Can be the default browser", symbol: "safari.fill", tint: .blue),
        "com.apple.developer.web-browser-engine.host": .init(title: "Alternative browser engine", symbol: "globe", tint: .blue),

        // Services
        "aps-environment": .init(title: "Push notifications", symbol: "bell.badge.fill", tint: .red),
        "com.apple.developer.aps-environment": .init(title: "Push notifications", symbol: "bell.badge.fill", tint: .red),
        "com.apple.developer.usernotifications.time-sensitive": .init(title: "Time-sensitive notifications", symbol: "bell.and.waves.left.and.right.fill", tint: .red),
        "com.apple.developer.usernotifications.communication": .init(title: "Communication notifications", symbol: "message.fill", tint: .green),
        "com.apple.developer.usernotifications.critical-alerts": .init(title: "Critical alerts", symbol: "exclamationmark.triangle.fill", tint: .red, tone: .caution),
        "com.apple.developer.healthkit": .init(title: "Health data", symbol: "heart.fill", tint: .pink),
        "com.apple.developer.healthkit.access": .init(title: "Health records", symbol: "heart.text.square.fill", tint: .pink),
        "com.apple.developer.healthkit.background-delivery": .init(title: "Health updates in the background", symbol: "heart.fill", tint: .pink),
        "com.apple.developer.homekit": .init(title: "Home", symbol: "house.fill", tint: .orange),
        "com.apple.developer.siri": .init(title: "Siri", symbol: "waveform", tint: .purple),
        "com.apple.developer.in-app-payments": .init(title: "Apple Pay", symbol: "creditcard.fill", tint: .gray),
        "com.apple.developer.pass-type-identifiers": .init(title: "Wallet passes", symbol: "wallet.pass.fill", tint: .gray),
        "com.apple.developer.game-center": .init(title: "Game Center", symbol: "gamecontroller.fill", tint: .pink),
        "com.apple.developer.networking.networkextension": .init(title: "Network extensions", symbol: "network.badge.shield.half.filled", tint: .blue, tone: .caution),
        "com.apple.developer.networking.vpn.api": .init(title: "Personal VPN", symbol: "lock.shield", tint: .blue),
        "com.apple.developer.networking.wifi-info": .init(title: "Wi-Fi network information", symbol: "wifi", tint: .blue),
        "com.apple.developer.networking.multipath": .init(title: "Multipath networking", symbol: "point.3.connected.trianglepath.dotted", tint: .blue),
        "com.apple.developer.networking.HotspotConfiguration": .init(title: "Configures Wi-Fi hotspots", symbol: "wifi", tint: .blue),
        "com.apple.developer.networking.multicast": .init(title: "Multicast networking", symbol: "dot.radiowaves.left.and.right", tint: .blue),
        "com.apple.developer.nfc.readersession.formats": .init(title: "NFC tags", symbol: "wave.3.right", tint: .gray),
        "com.apple.developer.associated-appclip-app-identifiers": .init(title: "App Clip", symbol: "appclip", tint: .blue),
        "com.apple.developer.family-controls": .init(title: "Screen Time controls", symbol: "hourglass", tint: .indigo, tone: .caution),
        "com.apple.developer.ClassKit-environment": .init(title: "ClassKit", symbol: "graduationcap.fill", tint: .orange),
        "com.apple.developer.kernel.increased-memory-limit": .init(title: "Increased memory limit", symbol: "memorychip", tint: .gray),
        "com.apple.developer.kernel.extended-virtual-addressing": .init(title: "Extended virtual addressing", symbol: "memorychip", tint: .gray),
        "com.apple.developer.weatherkit": .init(title: "WeatherKit", symbol: "cloud.sun.fill", tint: .cyan),
        "com.apple.developer.devicecheck.appattest-environment": .init(title: "App Attest", symbol: "checkmark.shield.fill", tint: .green),
        "com.apple.developer.group-session": .init(title: "SharePlay", symbol: "shareplay", tint: .green),
        "com.apple.developer.carplay-audio": .init(title: "CarPlay audio", symbol: "car.fill", tint: .gray),
        "com.apple.developer.contacts.notes": .init(title: "Contact notes", symbol: "note.text", tint: .brown, tone: .caution),
        "com.apple.developer.fileprovider.testing-mode": .init(title: "File provider testing", symbol: "folder.badge.gearshape", tint: .blue),
        "com.apple.developer.user-fonts": .init(title: "Installs fonts", symbol: "textformat", tint: .gray),
        "com.apple.developer.maps": .init(title: "Maps", symbol: "map.fill", tint: .green),
        "com.apple.developer.default-data-protection": .init(title: "Data protection", symbol: "lock.fill", tint: .gray),
        "com.apple.developer.payment-pass-provisioning": .init(title: "Adds cards to Wallet", symbol: "creditcard", tint: .gray),
        "com.apple.developer.shared-with-you": .init(title: "Shared with You", symbol: "person.2.fill", tint: .blue),
        "com.apple.developer.media-device-discovery-extension": .init(title: "Media device discovery", symbol: "airplayvideo", tint: .blue),

        // System-level powers
        "com.apple.developer.endpoint-security.client": .init(title: "Monitors system activity (Endpoint Security)", symbol: "eye.fill", tint: .red, tone: .caution),
        "com.apple.developer.system-extension.install": .init(title: "Installs system extensions", symbol: "puzzlepiece.extension.fill", tint: .orange, tone: .caution),
        "com.apple.developer.driverkit": .init(title: "Device driver", symbol: "cpu", tint: .gray, tone: .caution),
        "com.apple.developer.driverkit.userclient-access": .init(title: "Talks to device drivers", symbol: "cpu", tint: .gray),
        "com.apple.developer.driverkit.transport.usb": .init(title: "USB driver", symbol: "cable.connector", tint: .gray),
        "com.apple.developer.driverkit.transport.pci": .init(title: "PCI driver", symbol: "memorychip", tint: .gray),
        "com.apple.developer.driverkit.transport.hid": .init(title: "Keyboard and mouse driver", symbol: "keyboard", tint: .gray, tone: .caution),
        "com.apple.developer.driverkit.family.hid.eventservice": .init(title: "Injects keyboard and mouse events", symbol: "keyboard", tint: .orange, tone: .caution),
        "com.apple.developer.driverkit.family.audio": .init(title: "Audio driver", symbol: "speaker.wave.2.fill", tint: .gray),
        "com.apple.developer.driverkit.family.networking": .init(title: "Network driver", symbol: "network", tint: .gray),
        "com.apple.developer.driverkit.family.serial": .init(title: "Serial driver", symbol: "cable.connector.horizontal", tint: .gray),
        "com.apple.developer.driverkit.family.scsicontroller": .init(title: "Storage driver", symbol: "internaldrive", tint: .gray),
        "com.apple.developer.virtualhid": .init(title: "Virtual keyboard and mouse", symbol: "keyboard", tint: .orange, tone: .caution),
        "com.apple.developer.persistent-content-capture": .init(title: "Persistent screen capture", symbol: "rectangle.dashed.badge.record", tint: .red, tone: .caution),
        "com.apple.developer.screen-capture.include-passthrough": .init(title: "Captures passthrough video", symbol: "rectangle.dashed.badge.record", tint: .red),
        "com.apple.developer.mail-client": .init(title: "Can be the default mail app", symbol: "envelope.fill", tint: .blue),
        "com.apple.developer.messages.critical-messaging": .init(title: "Critical messaging", symbol: "message.badge.fill", tint: .red),
        "com.apple.developer.on-demand-install-capable": .init(title: "Installs on demand", symbol: "arrow.down.app", tint: .blue),
        "com.apple.developer.ubiquity-container-identifiers.private": .init(title: "Private iCloud Drive", symbol: "icloud", tint: .cyan),
        "com.apple.developer.securityd.keychain-sharing": .init(title: "Keychain sharing", symbol: "key.fill", tint: .gray),
        "com.apple.developer.contactless-payment-pass-provisioning": .init(title: "Contactless payments", symbol: "wave.3.right.circle.fill", tint: .gray),
        "com.apple.developer.proximity-reader.payment.acceptance": .init(title: "Tap to Pay", symbol: "wave.3.right.circle.fill", tint: .gray),
        "com.apple.developer.device-information.user-assigned-device-name": .init(title: "Reads your device name", symbol: "iphone", tint: .gray),
        "com.apple.developer.exposure-notification": .init(title: "Exposure notifications", symbol: "staroflife.fill", tint: .red),
        "com.apple.developer.sustained-execution": .init(title: "Runs in the background longer", symbol: "clock.arrow.circlepath", tint: .gray),
        "com.apple.developer.coremedia.hls.low-latency": .init(title: "Low-latency streaming", symbol: "play.tv.fill", tint: .gray),
    ]
}

enum PrivacyCatalog {
    static func describe(_ key: String) -> CatalogEntry? {
        if let entry = entries[key] { return entry }
        guard key.hasSuffix("UsageDescription") else { return nil }
        // NSSomethingUsageDescription → "Something"
        var name = key
        if name.hasPrefix("NS") { name.removeFirst(2) }
        name = String(name.dropLast("UsageDescription".count))
        let spaced = name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return CatalogEntry(title: spaced, symbol: "hand.raised.fill", tint: .blue)
    }

    static let entries: [String: CatalogEntry] = [
        "NSCameraUsageDescription": .init(title: "Camera", symbol: "camera.fill", tint: .gray),
        "NSMicrophoneUsageDescription": .init(title: "Microphone", symbol: "mic.fill", tint: .orange),
        "NSContactsUsageDescription": .init(title: "Contacts", symbol: "person.crop.circle.fill", tint: .brown),
        "NSCalendarsUsageDescription": .init(title: "Calendars", symbol: "calendar", tint: .red),
        "NSCalendarsFullAccessUsageDescription": .init(title: "Calendars (full access)", symbol: "calendar", tint: .red),
        "NSCalendarsWriteOnlyAccessUsageDescription": .init(title: "Calendars (add events only)", symbol: "calendar.badge.plus", tint: .red),
        "NSRemindersUsageDescription": .init(title: "Reminders", symbol: "list.bullet", tint: .orange),
        "NSRemindersFullAccessUsageDescription": .init(title: "Reminders (full access)", symbol: "list.bullet", tint: .orange),
        "NSPhotoLibraryUsageDescription": .init(title: "Photos", symbol: "photo.on.rectangle.angled", tint: .orange),
        "NSPhotoLibraryAddUsageDescription": .init(title: "Photos (add only)", symbol: "photo.badge.plus", tint: .orange),
        "NSLocationUsageDescription": .init(title: "Location", symbol: "location.fill", tint: .blue),
        "NSLocationWhenInUseUsageDescription": .init(title: "Location while in use", symbol: "location.fill", tint: .blue),
        "NSLocationAlwaysUsageDescription": .init(title: "Location, always", symbol: "location.fill", tint: .blue, tone: .caution),
        "NSLocationAlwaysAndWhenInUseUsageDescription": .init(title: "Location, always", symbol: "location.fill", tint: .blue, tone: .caution),
        "NSLocationTemporaryUsageDescriptionDictionary": .init(title: "Precise location", symbol: "location.circle.fill", tint: .blue),
        "NSBluetoothAlwaysUsageDescription": .init(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", tint: .blue),
        "NSBluetoothPeripheralUsageDescription": .init(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", tint: .blue),
        "NSAppleEventsUsageDescription": .init(title: "Controls other apps", symbol: "applescript", tint: .gray, tone: .caution),
        "NSSystemAdministrationUsageDescription": .init(title: "Administrator actions", symbol: "lock.open.fill", tint: .red, tone: .caution),
        "NSDesktopFolderUsageDescription": .init(title: "Desktop folder", symbol: "menubar.dock.rectangle", tint: .blue),
        "NSDocumentsFolderUsageDescription": .init(title: "Documents folder", symbol: "folder.fill", tint: .blue),
        "NSDownloadsFolderUsageDescription": .init(title: "Downloads folder", symbol: "arrow.down.circle.fill", tint: .blue),
        "NSNetworkVolumesUsageDescription": .init(title: "Network volumes", symbol: "externaldrive.connected.to.line.below.fill", tint: .gray),
        "NSRemovableVolumesUsageDescription": .init(title: "Removable volumes", symbol: "externaldrive.fill", tint: .gray),
        "NSFileProviderDomainUsageDescription": .init(title: "Cloud storage files", symbol: "icloud.fill", tint: .cyan),
        "NSFileProviderPresenceUsageDescription": .init(title: "Cloud storage files", symbol: "icloud.fill", tint: .cyan),
        "NSSpeechRecognitionUsageDescription": .init(title: "Speech recognition", symbol: "waveform", tint: .gray),
        "NSMotionUsageDescription": .init(title: "Motion and fitness", symbol: "figure.walk", tint: .green),
        "NSHealthShareUsageDescription": .init(title: "Reads Health data", symbol: "heart.fill", tint: .pink),
        "NSHealthUpdateUsageDescription": .init(title: "Writes Health data", symbol: "heart.fill", tint: .pink),
        "NSHealthClinicalHealthRecordsShareUsageDescription": .init(title: "Health records", symbol: "heart.text.square.fill", tint: .pink),
        "NSHomeKitUsageDescription": .init(title: "Home", symbol: "house.fill", tint: .orange),
        "NSAppleMusicUsageDescription": .init(title: "Media and Apple Music", symbol: "music.note", tint: .pink),
        "NSFaceIDUsageDescription": .init(title: "Face ID", symbol: "faceid", tint: .green),
        "NSLocalNetworkUsageDescription": .init(title: "Local network", symbol: "network", tint: .blue),
        "NSUserTrackingUsageDescription": .init(title: "Tracking across apps and websites", symbol: "hand.raised.fill", tint: .blue, tone: .caution),
        "NSSiriUsageDescription": .init(title: "Siri", symbol: "waveform.circle.fill", tint: .purple),
        "NSFocusStatusUsageDescription": .init(title: "Focus status", symbol: "moon.fill", tint: .indigo),
        "NSNearbyInteractionUsageDescription": .init(title: "Nearby interactions", symbol: "wave.3.left.circle.fill", tint: .blue),
        "NSNearbyInteractionAllowOnceUsageDescription": .init(title: "Nearby interactions", symbol: "wave.3.left.circle.fill", tint: .blue),
        "NSSensorKitUsageDescription": .init(title: "Research sensors", symbol: "sensor.fill", tint: .green),
        "NSIdentityUsageDescription": .init(title: "Identity documents", symbol: "person.text.rectangle.fill", tint: .gray),
        "NSVideoSubscriberAccountUsageDescription": .init(title: "TV provider", symbol: "tv.fill", tint: .gray),
        "NSGKFriendListUsageDescription": .init(title: "Game Center friends", symbol: "person.2.fill", tint: .pink),
        "NSHomeKitAccessoriesUsageDescription": .init(title: "Home accessories", symbol: "homekit", tint: .orange),
        "NSAudioCaptureUsageDescription": .init(title: "Captures audio from other apps", symbol: "speaker.wave.2.circle.fill", tint: .orange, tone: .caution),
        "NSScreenCaptureUsageDescription": .init(title: "Screen recording", symbol: "rectangle.dashed.badge.record", tint: .purple, tone: .caution),
        "NSWorldSensingUsageDescription": .init(title: "Surroundings", symbol: "visionpro", tint: .gray),
        "NSHandsTrackingUsageDescription": .init(title: "Hand tracking", symbol: "hand.raised.fingers.spread.fill", tint: .gray),
        "NSFallDetectionUsageDescription": .init(title: "Fall detection", symbol: "figure.fall", tint: .red),
        "NSFinancialDataUsageDescription": .init(title: "Financial data", symbol: "dollarsign.circle.fill", tint: .green),
        "NFCReaderUsageDescription": .init(title: "NFC", symbol: "wave.3.right", tint: .gray),
        "NSAccessoryTrackingUsageDescription": .init(title: "Accessory tracking", symbol: "location.viewfinder", tint: .blue),
        "NSDiskImagesUsageDescription": .init(title: "Disk images", symbol: "externaldrive", tint: .gray),
    ]
}

enum ExtensionPointCatalog {
    static func describe(_ identifier: String) -> CatalogEntry {
        if let entry = entries[identifier] { return entry }
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let spaced = last.replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
        return CatalogEntry(title: spaced.prefix(1).uppercased() + spaced.dropFirst(), symbol: "puzzlepiece.extension.fill", tint: .gray)
    }

    static let entries: [String: CatalogEntry] = [
        "com.apple.quicklook.preview": .init(title: "Quick Look preview", symbol: "eye.fill", tint: .blue),
        "com.apple.quicklook.thumbnail": .init(title: "Finder thumbnails", symbol: "photo.fill", tint: .blue),
        "com.apple.share-services": .init(title: "Share menu", symbol: "square.and.arrow.up.fill", tint: .blue),
        "com.apple.ui-services": .init(title: "Action", symbol: "wand.and.stars", tint: .indigo),
        "com.apple.services": .init(title: "Action", symbol: "wand.and.stars", tint: .indigo),
        "com.apple.FinderSync": .init(title: "Finder sync", symbol: "folder.badge.gearshape", tint: .blue, tone: .neutral),
        "com.apple.fileprovider-nonui": .init(title: "File provider", symbol: "icloud.fill", tint: .cyan),
        "com.apple.fileprovider-actionsui": .init(title: "File provider actions", symbol: "icloud", tint: .cyan),
        "com.apple.widgetkit-extension": .init(title: "Widget", symbol: "square.grid.2x2.fill", tint: .indigo),
        "com.apple.widget-extension": .init(title: "Widget", symbol: "square.grid.2x2.fill", tint: .indigo),
        "com.apple.Safari.web-extension": .init(title: "Safari web extension", symbol: "safari.fill", tint: .blue),
        "com.apple.Safari.extension": .init(title: "Safari extension", symbol: "safari.fill", tint: .blue),
        "com.apple.Safari.content-blocker": .init(title: "Safari content blocker", symbol: "hand.raised.slash.fill", tint: .blue),
        "com.apple.usernotifications.service": .init(title: "Notification service", symbol: "bell.badge.fill", tint: .red),
        "com.apple.usernotifications.content-extension": .init(title: "Notification content", symbol: "bell.fill", tint: .red),
        "com.apple.intents-service": .init(title: "Siri and Shortcuts intents", symbol: "waveform.circle.fill", tint: .purple),
        "com.apple.intents-ui-service": .init(title: "Siri and Shortcuts interface", symbol: "waveform.circle.fill", tint: .purple),
        "com.apple.appintents-extension": .init(title: "App Intents", symbol: "square.stack.3d.forward.dottedline.fill", tint: .purple),
        "com.apple.spotlight.import": .init(title: "Spotlight importer", symbol: "magnifyingglass", tint: .gray),
        "com.apple.spotlight.index": .init(title: "Spotlight indexing", symbol: "magnifyingglass", tint: .gray),
        "com.apple.networkextension.packet-tunnel": .init(title: "VPN (packet tunnel)", symbol: "lock.shield.fill", tint: .blue, tone: .caution),
        "com.apple.networkextension.app-proxy": .init(title: "App proxy", symbol: "network.badge.shield.half.filled", tint: .blue, tone: .caution),
        "com.apple.networkextension.filter-data": .init(title: "Network content filter", symbol: "line.3.horizontal.decrease.circle.fill", tint: .blue, tone: .caution),
        "com.apple.networkextension.dns-proxy": .init(title: "DNS proxy", symbol: "network", tint: .blue, tone: .caution),
        "com.apple.keyboard-service": .init(title: "Custom keyboard", symbol: "keyboard.fill", tint: .gray, tone: .caution),
        "com.apple.photo-editing": .init(title: "Photo editing", symbol: "camera.filters", tint: .orange),
        "com.apple.photo-project": .init(title: "Photos project", symbol: "photo.stack.fill", tint: .orange),
        "com.apple.broadcast-services-upload": .init(title: "Broadcast upload", symbol: "dot.radiowaves.left.and.right", tint: .red),
        "com.apple.broadcast-services-setupui": .init(title: "Broadcast setup", symbol: "dot.radiowaves.left.and.right", tint: .red),
        "com.apple.authentication-services-credential-provider-ui": .init(title: "Password AutoFill", symbol: "key.horizontal.fill", tint: .gray),
        "com.apple.AudioUnit-UI": .init(title: "Audio unit", symbol: "waveform", tint: .pink),
        "com.apple.AudioUnit": .init(title: "Audio unit", symbol: "waveform", tint: .pink),
        "com.apple.message-payload-provider": .init(title: "iMessage app", symbol: "message.fill", tint: .green),
        "com.apple.messages-extension": .init(title: "iMessage app", symbol: "message.fill", tint: .green),
        "com.apple.callkit.call-directory": .init(title: "Call directory", symbol: "phone.fill", tint: .green),
        "com.apple.background-asset-downloader-extension": .init(title: "Background assets", symbol: "arrow.down.circle.fill", tint: .blue),
        "com.apple.deviceactivity.monitor-extension": .init(title: "Screen Time monitor", symbol: "hourglass", tint: .indigo),
        "com.apple.ManagedSettings.shield-configuration-service": .init(title: "Screen Time shield", symbol: "hourglass", tint: .indigo),
        "com.apple.system_extension.driver_extension": .init(title: "Driver extension", symbol: "cpu", tint: .gray, tone: .caution),
        "com.apple.system_extension.network_extension": .init(title: "Network system extension", symbol: "network.badge.shield.half.filled", tint: .blue, tone: .caution),
        "com.apple.system_extension.endpoint_security": .init(title: "Endpoint Security", symbol: "eye.fill", tint: .red, tone: .caution),
        "com.apple.cmio.camera-extension": .init(title: "Virtual camera", symbol: "web.camera.fill", tint: .gray),
        "com.apple.screensaver": .init(title: "Screen saver", symbol: "sparkles.tv.fill", tint: .indigo),
        "com.apple.wallpaper": .init(title: "Wallpaper", symbol: "photo.artframe", tint: .teal),
        "com.apple.textinputmethod": .init(title: "Input method", symbol: "character.cursor.ibeam", tint: .gray),
        "com.apple.dt.Xcode.extension.source-editor": .init(title: "Xcode source editor", symbol: "hammer.fill", tint: .blue),
        "com.apple.mail-extension": .init(title: "Mail extension", symbol: "envelope.fill", tint: .blue),
        "com.apple.printing.print-extension": .init(title: "Printing", symbol: "printer.fill", tint: .gray),
        "com.apple.location.push.service": .init(title: "Location push", symbol: "location.fill", tint: .blue),
        "com.apple.ctk-tokens": .init(title: "Smart card token", symbol: "creditcard.fill", tint: .gray),
        "com.apple.dt.instruments.extension": .init(title: "Instruments", symbol: "gauge.with.needle", tint: .gray),
        "com.apple.diagnostic-extension": .init(title: "Diagnostics", symbol: "stethoscope", tint: .gray),
        "com.apple.contact.provider.extension": .init(title: "Contacts provider", symbol: "person.crop.circle.fill", tint: .brown),
        "com.apple.translation-provider": .init(title: "Translation", symbol: "translate", tint: .blue),
        "com.apple.storekit.app-store-extension": .init(title: "App Store", symbol: "bag.fill", tint: .blue),
        "com.apple.accessory-setup-extension": .init(title: "Accessory setup", symbol: "cable.connector", tint: .gray),
    ]
}
