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
            let kind = String(key.dropFirst("com.apple.security.temporary-exception.".count))
            let title = sandboxExceptions[kind] ?? String(localized: "Sandbox exception (\(kind))", bundle: .greeceKit,
                                                          comment: "Inspector row. The argument is a raw sandbox exception key, such as “files.home-relative-path.read-only”")
            return CatalogEntry(title: title, symbol: "exclamationmark.shield.fill",
                                tint: .orange, tone: .caution)
        }

        return nil
    }

    /// Temporary exceptions punch specific holes in the App Sandbox.
    static let sandboxExceptions: [String: String] = [
        "files.home-relative-path.read-only": String(localized: "Reads files in your home folder", bundle: .greeceKit),
        "files.home-relative-path.read-write": String(localized: "Reads and writes files in your home folder", bundle: .greeceKit),
        "files.absolute-path.read-only": String(localized: "Reads files outside its sandbox", bundle: .greeceKit),
        "files.absolute-path.read-write": String(localized: "Reads and writes files outside its sandbox", bundle: .greeceKit),
        "mach-lookup.global-name": String(localized: "Talks to services outside its sandbox", bundle: .greeceKit),
        "mach-register.global-name": String(localized: "Offers services outside its sandbox", bundle: .greeceKit),
        "shared-preference.read-only": String(localized: "Reads other apps’ settings", bundle: .greeceKit),
        "shared-preference.read-write": String(localized: "Changes other apps’ settings", bundle: .greeceKit),
        "apple-events": String(localized: "Sends Apple events to other apps", bundle: .greeceKit),
        "iokit-user-client-class": String(localized: "Talks to hardware drivers", bundle: .greeceKit),
        "audio-unit-host": String(localized: "Hosts audio units", bundle: .greeceKit),
        "sbpl": String(localized: "Custom sandbox rules", bundle: .greeceKit),
    ]

    static func isPrivate(_ key: String) -> Bool { key.hasPrefix("com.apple.private.") }

    static let entries: [String: CatalogEntry] = [
        // Sandbox
        "com.apple.security.app-sandbox": .init(title: String(localized: "App Sandbox", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "shield.lefthalf.filled", tint: .green, tone: .positive),
        "com.apple.security.network.client": .init(title: String(localized: "Outgoing network connections", bundle: .greeceKit), symbol: "network", tint: .blue),
        "com.apple.security.network.server": .init(title: String(localized: "Incoming network connections", bundle: .greeceKit), symbol: "antenna.radiowaves.left.and.right", tint: .blue),
        "com.apple.security.device.camera": .init(title: String(localized: "Camera", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "camera.fill", tint: .gray),
        "com.apple.security.device.audio-input": .init(title: String(localized: "Microphone", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "mic.fill", tint: .orange),
        "com.apple.security.device.microphone": .init(title: String(localized: "Microphone", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "mic.fill", tint: .orange),
        "com.apple.security.device.usb": .init(title: String(localized: "USB devices", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "cable.connector", tint: .gray),
        "com.apple.security.device.bluetooth": .init(title: String(localized: "Bluetooth devices", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "dot.radiowaves.left.and.right", tint: .blue),
        "com.apple.security.device.serial": .init(title: String(localized: "Serial ports", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "cable.connector.horizontal", tint: .gray),
        "com.apple.security.print": .init(title: String(localized: "Printing", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "printer.fill", tint: .gray),
        "com.apple.security.personal-information.addressbook": .init(title: String(localized: "Contacts", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "person.crop.circle.fill", tint: .brown),
        "com.apple.security.personal-information.calendars": .init(title: String(localized: "Calendars", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "calendar", tint: .red),
        "com.apple.security.personal-information.location": .init(title: String(localized: "Location", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "location.fill", tint: .blue),
        "com.apple.security.personal-information.photos-library": .init(title: String(localized: "Photos library", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "photo.on.rectangle", tint: .orange),
        "com.apple.security.files.user-selected.read-only": .init(title: String(localized: "Files you choose (read only)", bundle: .greeceKit), symbol: "doc", tint: .blue),
        "com.apple.security.files.user-selected.read-write": .init(title: String(localized: "Files you choose", bundle: .greeceKit), symbol: "doc.badge.plus", tint: .blue),
        "com.apple.security.files.user-selected.executable": .init(title: String(localized: "Creates executables you save", bundle: .greeceKit), symbol: "terminal", tint: .gray),
        "com.apple.security.files.downloads.read-only": .init(title: String(localized: "Downloads folder (read only)", bundle: .greeceKit), symbol: "arrow.down.circle.fill", tint: .blue),
        "com.apple.security.files.downloads.read-write": .init(title: String(localized: "Downloads folder", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "arrow.down.circle.fill", tint: .blue),
        "com.apple.security.assets.pictures.read-only": .init(title: String(localized: "Pictures folder (read only)", bundle: .greeceKit), symbol: "photo", tint: .teal),
        "com.apple.security.assets.pictures.read-write": .init(title: String(localized: "Pictures folder", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "photo", tint: .teal),
        "com.apple.security.assets.music.read-only": .init(title: String(localized: "Music folder (read only)", bundle: .greeceKit), symbol: "music.note", tint: .pink),
        "com.apple.security.assets.music.read-write": .init(title: String(localized: "Music folder", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "music.note", tint: .pink),
        "com.apple.security.assets.movies.read-only": .init(title: String(localized: "Movies folder (read only)", bundle: .greeceKit), symbol: "film", tint: .indigo),
        "com.apple.security.assets.movies.read-write": .init(title: String(localized: "Movies folder", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "film", tint: .indigo),
        "com.apple.security.files.bookmarks.app-scope": .init(title: String(localized: "Remembers files you open", bundle: .greeceKit), symbol: "bookmark.fill", tint: .gray),
        "com.apple.security.files.bookmarks.document-scope": .init(title: String(localized: "Remembers files documents refer to", bundle: .greeceKit), symbol: "bookmark", tint: .gray),
        "com.apple.security.files.all": .init(title: String(localized: "All files", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "externaldrive.fill", tint: .gray, tone: .caution),
        "com.apple.security.automation.apple-events": .init(title: String(localized: "Controls other apps", bundle: .greeceKit), symbol: "applescript", tint: .gray, tone: .caution),
        "com.apple.security.scripting-targets": .init(title: String(localized: "Scripts specific apps", bundle: .greeceKit), symbol: "applescript", tint: .gray),
        "com.apple.security.application-groups": .init(title: String(localized: "Shared app group", bundle: .greeceKit), symbol: "square.stack.3d.up.fill", tint: .indigo),
        "com.apple.security.inherit": .init(title: String(localized: "Inherits its parent’s sandbox", bundle: .greeceKit), symbol: "arrow.down.right.and.arrow.up.left", tint: .green),
        "com.apple.security.virtualization": .init(title: String(localized: "Virtual machines", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "macwindow.on.rectangle", tint: .purple),
        "com.apple.security.hypervisor": .init(title: String(localized: "Hypervisor", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "cpu", tint: .purple),
        "com.apple.security.smartcard": .init(title: String(localized: "Smart cards", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "creditcard.fill", tint: .gray),
        "com.apple.security.network.vpn": .init(title: "VPN", symbol: "lock.shield", tint: .blue),

        // Hardened runtime exceptions
        "com.apple.security.cs.allow-jit": .init(title: String(localized: "Generates code at runtime (JIT)", bundle: .greeceKit), symbol: "bolt.fill", tint: .yellow, tone: .neutral),
        "com.apple.security.cs.allow-unsigned-executable-memory": .init(title: String(localized: "Runs unsigned code in memory", bundle: .greeceKit), symbol: "memorychip", tint: .orange, tone: .caution),
        "com.apple.security.cs.allow-dyld-environment-variables": .init(title: String(localized: "Honours DYLD environment variables", bundle: .greeceKit), symbol: "terminal", tint: .orange, tone: .caution),
        "com.apple.security.cs.disable-library-validation": .init(title: String(localized: "Loads libraries signed by anyone", bundle: .greeceKit), symbol: "puzzlepiece.extension.fill", tint: .orange, tone: .caution),
        "com.apple.security.cs.disable-executable-page-protection": .init(title: String(localized: "Disables executable memory protection", bundle: .greeceKit), symbol: "exclamationmark.triangle.fill", tint: .red, tone: .critical),
        "com.apple.security.cs.debugger": .init(title: String(localized: "Debugs other processes", bundle: .greeceKit), symbol: "ant.fill", tint: .orange, tone: .caution),
        "com.apple.security.get-task-allow": .init(title: String(localized: "Debuggable", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "ladybug.fill", tint: .orange, tone: .caution),
        "get-task-allow": .init(title: String(localized: "Debuggable (development build)", bundle: .greeceKit), symbol: "ladybug.fill", tint: .orange, tone: .caution),
        "com.apple.security.cs.jit-write-allowlist": .init(title: String(localized: "JIT write allowlist", bundle: .greeceKit), symbol: "bolt", tint: .yellow),

        // Enhanced security (macOS 26)
        "com.apple.security.hardened-process": .init(title: String(localized: "Enhanced Security", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "lock.shield.fill", tint: .green, tone: .positive),
        "com.apple.security.hardened-process.hardened-heap": .init(title: String(localized: "Hardened memory allocator", bundle: .greeceKit), symbol: "memorychip.fill", tint: .green, tone: .positive),
        "com.apple.security.hardened-process.enhanced-security-version": .init(title: String(localized: "Enhanced Security version", bundle: .greeceKit), symbol: "lock.shield", tint: .green),
        "com.apple.security.hardened-process.platform-restrictions": .init(title: String(localized: "Platform restrictions", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "lock.shield", tint: .green),
        "com.apple.security.hardened-process.dyld-ro": .init(title: String(localized: "Read-only dynamic linker data", bundle: .greeceKit), symbol: "lock.doc", tint: .green),
        "com.apple.security.hardened-process.checked-allocations": .init(title: String(localized: "Checked memory allocations", bundle: .greeceKit), symbol: "checkmark.shield", tint: .green),

        // iCloud, keychain, identity
        "com.apple.developer.icloud-container-identifiers": .init(title: String(localized: "iCloud containers", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "icloud.fill", tint: .cyan),
        "com.apple.developer.icloud-services": .init(title: String(localized: "iCloud services", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "icloud.fill", tint: .cyan),
        "com.apple.developer.ubiquity-container-identifiers": .init(title: String(localized: "iCloud Drive", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "icloud.and.arrow.up.fill", tint: .cyan),
        "com.apple.developer.ubiquity-kvstore-identifier": .init(title: String(localized: "iCloud key-value storage", bundle: .greeceKit), symbol: "icloud", tint: .cyan),
        "com.apple.developer.icloud-container-environment": .init(title: String(localized: "iCloud environment", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "icloud", tint: .cyan),
        "keychain-access-groups": .init(title: String(localized: "Keychain groups", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "key.fill", tint: .gray),
        "com.apple.developer.applesignin": .init(title: String(localized: "Sign in with Apple", bundle: .greeceKit), symbol: "apple.logo", tint: .gray),
        "com.apple.developer.authentication-services.autofill-credential-provider": .init(title: String(localized: "Password AutoFill provider", bundle: .greeceKit), symbol: "key.horizontal.fill", tint: .gray),
        "com.apple.developer.associated-domains": .init(title: String(localized: "Associated domains", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "link", tint: .blue),
        "com.apple.developer.associated-domains.applinks.read-write": .init(title: String(localized: "Associated domains", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "link", tint: .blue),
        "com.apple.developer.web-browser": .init(title: String(localized: "Can be the default browser", bundle: .greeceKit), symbol: "safari.fill", tint: .blue),
        "com.apple.developer.web-browser-engine.host": .init(title: String(localized: "Alternative browser engine", bundle: .greeceKit), symbol: "globe", tint: .blue),

        // Services
        "aps-environment": .init(title: String(localized: "Push notifications", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "bell.badge.fill", tint: .red),
        "com.apple.developer.aps-environment": .init(title: String(localized: "Push notifications", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "bell.badge.fill", tint: .red),
        "com.apple.developer.usernotifications.time-sensitive": .init(title: String(localized: "Time-sensitive notifications", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "bell.and.waves.left.and.right.fill", tint: .red),
        "com.apple.developer.usernotifications.communication": .init(title: String(localized: "Communication notifications", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "message.fill", tint: .green),
        "com.apple.developer.usernotifications.critical-alerts": .init(title: String(localized: "Critical alerts", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "exclamationmark.triangle.fill", tint: .red, tone: .caution),
        "com.apple.developer.healthkit": .init(title: String(localized: "Health data", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "heart.fill", tint: .pink),
        "com.apple.developer.healthkit.access": .init(title: String(localized: "Health records", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "heart.text.square.fill", tint: .pink),
        "com.apple.developer.healthkit.background-delivery": .init(title: String(localized: "Health updates in the background", bundle: .greeceKit), symbol: "heart.fill", tint: .pink),
        "com.apple.developer.homekit": .init(title: String(localized: "Home", bundle: .greeceKit, comment: "Inspector row: the Home app and HomeKit accessories"), symbol: "house.fill", tint: .orange),
        "com.apple.developer.siri": .init(title: "Siri", symbol: "waveform", tint: .purple),
        "com.apple.developer.in-app-payments": .init(title: "Apple Pay", symbol: "creditcard.fill", tint: .gray),
        "com.apple.developer.pass-type-identifiers": .init(title: String(localized: "Wallet passes", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "wallet.pass.fill", tint: .gray),
        "com.apple.developer.game-center": .init(title: "Game Center", symbol: "gamecontroller.fill", tint: .pink),
        "com.apple.developer.networking.networkextension": .init(title: String(localized: "Network extensions", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "network.badge.shield.half.filled", tint: .blue, tone: .caution),
        "com.apple.developer.networking.vpn.api": .init(title: String(localized: "Personal VPN", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "lock.shield", tint: .blue),
        "com.apple.developer.networking.wifi-info": .init(title: String(localized: "Wi-Fi network information", bundle: .greeceKit), symbol: "wifi", tint: .blue),
        "com.apple.developer.networking.multipath": .init(title: String(localized: "Multipath networking", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "point.3.connected.trianglepath.dotted", tint: .blue),
        "com.apple.developer.networking.HotspotConfiguration": .init(title: String(localized: "Configures Wi-Fi hotspots", bundle: .greeceKit), symbol: "wifi", tint: .blue),
        "com.apple.developer.networking.multicast": .init(title: String(localized: "Multicast networking", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "dot.radiowaves.left.and.right", tint: .blue),
        "com.apple.developer.nfc.readersession.formats": .init(title: String(localized: "NFC tags", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "wave.3.right", tint: .gray),
        "com.apple.developer.associated-appclip-app-identifiers": .init(title: "App Clip", symbol: "appclip", tint: .blue),
        "com.apple.developer.family-controls": .init(title: String(localized: "Screen Time controls", bundle: .greeceKit), symbol: "hourglass", tint: .indigo, tone: .caution),
        "com.apple.developer.ClassKit-environment": .init(title: "ClassKit", symbol: "graduationcap.fill", tint: .orange),
        "com.apple.developer.kernel.increased-memory-limit": .init(title: String(localized: "Increased memory limit", bundle: .greeceKit), symbol: "memorychip", tint: .gray),
        "com.apple.developer.kernel.extended-virtual-addressing": .init(title: String(localized: "Extended virtual addressing", bundle: .greeceKit), symbol: "memorychip", tint: .gray),
        "com.apple.developer.weatherkit": .init(title: "WeatherKit", symbol: "cloud.sun.fill", tint: .cyan),
        "com.apple.developer.devicecheck.appattest-environment": .init(title: "App Attest", symbol: "checkmark.shield.fill", tint: .green),
        "com.apple.developer.group-session": .init(title: "SharePlay", symbol: "shareplay", tint: .green),
        "com.apple.developer.carplay-audio": .init(title: String(localized: "CarPlay audio", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "car.fill", tint: .gray),
        "com.apple.developer.contacts.notes": .init(title: String(localized: "Contact notes", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "note.text", tint: .brown, tone: .caution),
        "com.apple.developer.fileprovider.testing-mode": .init(title: String(localized: "File provider testing", bundle: .greeceKit), symbol: "folder.badge.gearshape", tint: .blue),
        "com.apple.developer.user-fonts": .init(title: String(localized: "Installs fonts", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "textformat", tint: .gray),
        "com.apple.developer.maps": .init(title: String(localized: "Maps", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "map.fill", tint: .green),
        "com.apple.developer.default-data-protection": .init(title: String(localized: "Data protection", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "lock.fill", tint: .gray),
        "com.apple.developer.payment-pass-provisioning": .init(title: String(localized: "Adds cards to Wallet", bundle: .greeceKit), symbol: "creditcard", tint: .gray),
        "com.apple.developer.shared-with-you": .init(title: String(localized: "Shared with You", bundle: .greeceKit), symbol: "person.2.fill", tint: .blue),
        "com.apple.developer.media-device-discovery-extension": .init(title: String(localized: "Media device discovery", bundle: .greeceKit), symbol: "airplayvideo", tint: .blue),

        // System-level powers
        "com.apple.developer.endpoint-security.client": .init(title: String(localized: "Monitors system activity (Endpoint Security)", bundle: .greeceKit), symbol: "eye.fill", tint: .red, tone: .caution),
        "com.apple.developer.system-extension.install": .init(title: String(localized: "Installs system extensions", bundle: .greeceKit), symbol: "puzzlepiece.extension.fill", tint: .orange, tone: .caution),
        "com.apple.developer.driverkit": .init(title: String(localized: "Device driver", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "cpu", tint: .gray, tone: .caution),
        "com.apple.developer.driverkit.userclient-access": .init(title: String(localized: "Talks to device drivers", bundle: .greeceKit), symbol: "cpu", tint: .gray),
        "com.apple.developer.driverkit.transport.usb": .init(title: String(localized: "USB driver", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "cable.connector", tint: .gray),
        "com.apple.developer.driverkit.transport.pci": .init(title: String(localized: "PCI driver", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "memorychip", tint: .gray),
        "com.apple.developer.driverkit.transport.hid": .init(title: String(localized: "Keyboard and mouse driver", bundle: .greeceKit), symbol: "keyboard", tint: .gray, tone: .caution),
        "com.apple.developer.driverkit.family.hid.eventservice": .init(title: String(localized: "Injects keyboard and mouse events", bundle: .greeceKit), symbol: "keyboard", tint: .orange, tone: .caution),
        "com.apple.developer.driverkit.family.audio": .init(title: String(localized: "Audio driver", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "speaker.wave.2.fill", tint: .gray),
        "com.apple.developer.driverkit.family.networking": .init(title: String(localized: "Network driver", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "network", tint: .gray),
        "com.apple.developer.driverkit.family.serial": .init(title: String(localized: "Serial driver", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "cable.connector.horizontal", tint: .gray),
        "com.apple.developer.driverkit.family.scsicontroller": .init(title: String(localized: "Storage driver", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "internaldrive", tint: .gray),
        "com.apple.developer.virtualhid": .init(title: String(localized: "Virtual keyboard and mouse", bundle: .greeceKit), symbol: "keyboard", tint: .orange, tone: .caution),
        "com.apple.developer.persistent-content-capture": .init(title: String(localized: "Persistent screen capture", bundle: .greeceKit), symbol: "rectangle.dashed.badge.record", tint: .red, tone: .caution),
        "com.apple.developer.screen-capture.include-passthrough": .init(title: String(localized: "Captures passthrough video", bundle: .greeceKit), symbol: "rectangle.dashed.badge.record", tint: .red),
        "com.apple.developer.mail-client": .init(title: String(localized: "Can be the default mail app", bundle: .greeceKit), symbol: "envelope.fill", tint: .blue),
        "com.apple.developer.messages.critical-messaging": .init(title: String(localized: "Critical messaging", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "message.badge.fill", tint: .red),
        "com.apple.developer.on-demand-install-capable": .init(title: String(localized: "Installs on demand", bundle: .greeceKit), symbol: "arrow.down.app", tint: .blue),
        "com.apple.developer.ubiquity-container-identifiers.private": .init(title: String(localized: "Private iCloud Drive", bundle: .greeceKit), symbol: "icloud", tint: .cyan),
        "com.apple.developer.securityd.keychain-sharing": .init(title: String(localized: "Keychain sharing", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "key.fill", tint: .gray),
        "com.apple.developer.contactless-payment-pass-provisioning": .init(title: String(localized: "Contactless payments", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "wave.3.right.circle.fill", tint: .gray),
        "com.apple.developer.proximity-reader.payment.acceptance": .init(title: String(localized: "Tap to Pay", bundle: .greeceKit), symbol: "wave.3.right.circle.fill", tint: .gray),
        "com.apple.developer.device-information.user-assigned-device-name": .init(title: String(localized: "Reads your device name", bundle: .greeceKit), symbol: "iphone", tint: .gray),
        "com.apple.developer.exposure-notification": .init(title: String(localized: "Exposure notifications", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "staroflife.fill", tint: .red),
        "com.apple.developer.sustained-execution": .init(title: String(localized: "Runs in the background longer", bundle: .greeceKit), symbol: "clock.arrow.circlepath", tint: .gray),
        "com.apple.developer.coremedia.hls.low-latency": .init(title: String(localized: "Low-latency streaming", bundle: .greeceKit, comment: "Inspector row: something an app’s entitlements let it use or do"), symbol: "play.tv.fill", tint: .gray),
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
        "NSCameraUsageDescription": .init(title: String(localized: "Camera", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "camera.fill", tint: .gray),
        "NSMicrophoneUsageDescription": .init(title: String(localized: "Microphone", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "mic.fill", tint: .orange),
        "NSContactsUsageDescription": .init(title: String(localized: "Contacts", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "person.crop.circle.fill", tint: .brown),
        "NSCalendarsUsageDescription": .init(title: String(localized: "Calendars", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "calendar", tint: .red),
        "NSCalendarsFullAccessUsageDescription": .init(title: String(localized: "Calendars (full access)", bundle: .greeceKit), symbol: "calendar", tint: .red),
        "NSCalendarsWriteOnlyAccessUsageDescription": .init(title: String(localized: "Calendars (add events only)", bundle: .greeceKit), symbol: "calendar.badge.plus", tint: .red),
        "NSRemindersUsageDescription": .init(title: String(localized: "Reminders", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "list.bullet", tint: .orange),
        "NSRemindersFullAccessUsageDescription": .init(title: String(localized: "Reminders (full access)", bundle: .greeceKit), symbol: "list.bullet", tint: .orange),
        "NSPhotoLibraryUsageDescription": .init(title: String(localized: "Photos", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "photo.on.rectangle.angled", tint: .orange),
        "NSPhotoLibraryAddUsageDescription": .init(title: String(localized: "Photos (add only)", bundle: .greeceKit), symbol: "photo.badge.plus", tint: .orange),
        "NSLocationUsageDescription": .init(title: String(localized: "Location", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "location.fill", tint: .blue),
        "NSLocationWhenInUseUsageDescription": .init(title: String(localized: "Location while in use", bundle: .greeceKit), symbol: "location.fill", tint: .blue),
        "NSLocationAlwaysUsageDescription": .init(title: String(localized: "Location, always", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "location.fill", tint: .blue, tone: .caution),
        "NSLocationAlwaysAndWhenInUseUsageDescription": .init(title: String(localized: "Location, always", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "location.fill", tint: .blue, tone: .caution),
        "NSLocationTemporaryUsageDescriptionDictionary": .init(title: String(localized: "Precise location", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "location.circle.fill", tint: .blue),
        "NSBluetoothAlwaysUsageDescription": .init(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", tint: .blue),
        "NSBluetoothPeripheralUsageDescription": .init(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", tint: .blue),
        "NSAppleEventsUsageDescription": .init(title: String(localized: "Controls other apps", bundle: .greeceKit), symbol: "applescript", tint: .gray, tone: .caution),
        "NSSystemAdministrationUsageDescription": .init(title: String(localized: "Administrator actions", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "lock.open.fill", tint: .red, tone: .caution),
        "NSDesktopFolderUsageDescription": .init(title: String(localized: "Desktop folder", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "menubar.dock.rectangle", tint: .blue),
        "NSDocumentsFolderUsageDescription": .init(title: String(localized: "Documents folder", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "folder.fill", tint: .blue),
        "NSDownloadsFolderUsageDescription": .init(title: String(localized: "Downloads folder", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "arrow.down.circle.fill", tint: .blue),
        "NSNetworkVolumesUsageDescription": .init(title: String(localized: "Network volumes", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "externaldrive.connected.to.line.below.fill", tint: .gray),
        "NSRemovableVolumesUsageDescription": .init(title: String(localized: "Removable volumes", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "externaldrive.fill", tint: .gray),
        "NSFileProviderDomainUsageDescription": .init(title: String(localized: "Cloud storage files", bundle: .greeceKit), symbol: "icloud.fill", tint: .cyan),
        "NSFileProviderPresenceUsageDescription": .init(title: String(localized: "Cloud storage files", bundle: .greeceKit), symbol: "icloud.fill", tint: .cyan),
        "NSSpeechRecognitionUsageDescription": .init(title: String(localized: "Speech recognition", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "waveform", tint: .gray),
        "NSMotionUsageDescription": .init(title: String(localized: "Motion and fitness", bundle: .greeceKit), symbol: "figure.walk", tint: .green),
        "NSHealthShareUsageDescription": .init(title: String(localized: "Reads Health data", bundle: .greeceKit), symbol: "heart.fill", tint: .pink),
        "NSHealthUpdateUsageDescription": .init(title: String(localized: "Writes Health data", bundle: .greeceKit), symbol: "heart.fill", tint: .pink),
        "NSHealthClinicalHealthRecordsShareUsageDescription": .init(title: String(localized: "Health records", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "heart.text.square.fill", tint: .pink),
        "NSHomeKitUsageDescription": .init(title: String(localized: "Home", bundle: .greeceKit, comment: "Inspector row: the Home app and HomeKit accessories"), symbol: "house.fill", tint: .orange),
        "NSAppleMusicUsageDescription": .init(title: String(localized: "Media and Apple Music", bundle: .greeceKit), symbol: "music.note", tint: .pink),
        "NSFaceIDUsageDescription": .init(title: "Face ID", symbol: "faceid", tint: .green),
        "NSLocalNetworkUsageDescription": .init(title: String(localized: "Local network", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "network", tint: .blue),
        "NSUserTrackingUsageDescription": .init(title: String(localized: "Tracking across apps and websites", bundle: .greeceKit), symbol: "hand.raised.fill", tint: .blue, tone: .caution),
        "NSSiriUsageDescription": .init(title: "Siri", symbol: "waveform.circle.fill", tint: .purple),
        "NSFocusStatusUsageDescription": .init(title: String(localized: "Focus status", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "moon.fill", tint: .indigo),
        "NSNearbyInteractionUsageDescription": .init(title: String(localized: "Nearby interactions", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "wave.3.left.circle.fill", tint: .blue),
        "NSNearbyInteractionAllowOnceUsageDescription": .init(title: String(localized: "Nearby interactions", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "wave.3.left.circle.fill", tint: .blue),
        "NSSensorKitUsageDescription": .init(title: String(localized: "Research sensors", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "sensor.fill", tint: .green),
        "NSIdentityUsageDescription": .init(title: String(localized: "Identity documents", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "person.text.rectangle.fill", tint: .gray),
        "NSVideoSubscriberAccountUsageDescription": .init(title: String(localized: "TV provider", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "tv.fill", tint: .gray),
        "NSGKFriendListUsageDescription": .init(title: String(localized: "Game Center friends", bundle: .greeceKit), symbol: "person.2.fill", tint: .pink),
        "NSHomeKitAccessoriesUsageDescription": .init(title: String(localized: "Home accessories", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "homekit", tint: .orange),
        "NSAudioCaptureUsageDescription": .init(title: String(localized: "Captures audio from other apps", bundle: .greeceKit), symbol: "speaker.wave.2.circle.fill", tint: .orange, tone: .caution),
        "NSScreenCaptureUsageDescription": .init(title: String(localized: "Screen recording", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "rectangle.dashed.badge.record", tint: .purple, tone: .caution),
        "NSWorldSensingUsageDescription": .init(title: String(localized: "Surroundings", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "visionpro", tint: .gray),
        "NSHandsTrackingUsageDescription": .init(title: String(localized: "Hand tracking", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "hand.raised.fingers.spread.fill", tint: .gray),
        "NSFallDetectionUsageDescription": .init(title: String(localized: "Fall detection", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "figure.fall", tint: .red),
        "NSFinancialDataUsageDescription": .init(title: String(localized: "Financial data", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "dollarsign.circle.fill", tint: .green),
        "NFCReaderUsageDescription": .init(title: "NFC", symbol: "wave.3.right", tint: .gray),
        "NSAccessoryTrackingUsageDescription": .init(title: String(localized: "Accessory tracking", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "location.viewfinder", tint: .blue),
        "NSDiskImagesUsageDescription": .init(title: String(localized: "Disk images", bundle: .greeceKit, comment: "Inspector row: something an app may ask your permission to use"), symbol: "externaldrive", tint: .gray),
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
        "com.apple.quicklook.preview": .init(title: String(localized: "Quick Look preview", bundle: .greeceKit), symbol: "eye.fill", tint: .blue),
        "com.apple.quicklook.thumbnail": .init(title: String(localized: "Finder thumbnails", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "photo.fill", tint: .blue),
        "com.apple.share-services": .init(title: String(localized: "Share menu", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "square.and.arrow.up.fill", tint: .blue),
        "com.apple.ui-services": .init(title: String(localized: "Action", bundle: .greeceKit, comment: "Inspector row: a kind of app extension that acts on what you select (noun)"), symbol: "wand.and.stars", tint: .indigo),
        "com.apple.services": .init(title: String(localized: "Action", bundle: .greeceKit, comment: "Inspector row: a kind of app extension that acts on what you select (noun)"), symbol: "wand.and.stars", tint: .indigo),
        "com.apple.FinderSync": .init(title: String(localized: "Finder sync", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "folder.badge.gearshape", tint: .blue, tone: .neutral),
        "com.apple.fileprovider-nonui": .init(title: String(localized: "File provider", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "icloud.fill", tint: .cyan),
        "com.apple.fileprovider-actionsui": .init(title: String(localized: "File provider actions", bundle: .greeceKit), symbol: "icloud", tint: .cyan),
        "com.apple.widgetkit-extension": .init(title: String(localized: "Widget", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "square.grid.2x2.fill", tint: .indigo),
        "com.apple.widget-extension": .init(title: String(localized: "Widget", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "square.grid.2x2.fill", tint: .indigo),
        "com.apple.Safari.web-extension": .init(title: String(localized: "Safari web extension", bundle: .greeceKit), symbol: "safari.fill", tint: .blue),
        "com.apple.Safari.extension": .init(title: String(localized: "Safari extension", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "safari.fill", tint: .blue),
        "com.apple.Safari.content-blocker": .init(title: String(localized: "Safari content blocker", bundle: .greeceKit), symbol: "hand.raised.slash.fill", tint: .blue),
        "com.apple.usernotifications.service": .init(title: String(localized: "Notification service", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "bell.badge.fill", tint: .red),
        "com.apple.usernotifications.content-extension": .init(title: String(localized: "Notification content", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "bell.fill", tint: .red),
        "com.apple.intents-service": .init(title: String(localized: "Siri and Shortcuts intents", bundle: .greeceKit), symbol: "waveform.circle.fill", tint: .purple),
        "com.apple.intents-ui-service": .init(title: String(localized: "Siri and Shortcuts interface", bundle: .greeceKit), symbol: "waveform.circle.fill", tint: .purple),
        "com.apple.appintents-extension": .init(title: "App Intents", symbol: "square.stack.3d.forward.dottedline.fill", tint: .purple),
        "com.apple.spotlight.import": .init(title: String(localized: "Spotlight importer", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "magnifyingglass", tint: .gray),
        "com.apple.spotlight.index": .init(title: String(localized: "Spotlight indexing", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "magnifyingglass", tint: .gray),
        "com.apple.networkextension.packet-tunnel": .init(title: String(localized: "VPN (packet tunnel)", bundle: .greeceKit), symbol: "lock.shield.fill", tint: .blue, tone: .caution),
        "com.apple.networkextension.app-proxy": .init(title: String(localized: "App proxy", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "network.badge.shield.half.filled", tint: .blue, tone: .caution),
        "com.apple.networkextension.filter-data": .init(title: String(localized: "Network content filter", bundle: .greeceKit), symbol: "line.3.horizontal.decrease.circle.fill", tint: .blue, tone: .caution),
        "com.apple.networkextension.dns-proxy": .init(title: String(localized: "DNS proxy", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "network", tint: .blue, tone: .caution),
        "com.apple.keyboard-service": .init(title: String(localized: "Custom keyboard", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "keyboard.fill", tint: .gray, tone: .caution),
        "com.apple.photo-editing": .init(title: String(localized: "Photo editing", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "camera.filters", tint: .orange),
        "com.apple.photo-project": .init(title: String(localized: "Photos project", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "photo.stack.fill", tint: .orange),
        "com.apple.broadcast-services-upload": .init(title: String(localized: "Broadcast upload", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "dot.radiowaves.left.and.right", tint: .red),
        "com.apple.broadcast-services-setupui": .init(title: String(localized: "Broadcast setup", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "dot.radiowaves.left.and.right", tint: .red),
        "com.apple.authentication-services-credential-provider-ui": .init(title: String(localized: "Password AutoFill", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "key.horizontal.fill", tint: .gray),
        "com.apple.AudioUnit-UI": .init(title: String(localized: "Audio unit", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "waveform", tint: .pink),
        "com.apple.AudioUnit": .init(title: String(localized: "Audio unit", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "waveform", tint: .pink),
        "com.apple.message-payload-provider": .init(title: String(localized: "iMessage app", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "message.fill", tint: .green),
        "com.apple.messages-extension": .init(title: String(localized: "iMessage app", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "message.fill", tint: .green),
        "com.apple.callkit.call-directory": .init(title: String(localized: "Call directory", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "phone.fill", tint: .green),
        "com.apple.background-asset-downloader-extension": .init(title: String(localized: "Background assets", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "arrow.down.circle.fill", tint: .blue),
        "com.apple.deviceactivity.monitor-extension": .init(title: String(localized: "Screen Time monitor", bundle: .greeceKit), symbol: "hourglass", tint: .indigo),
        "com.apple.ManagedSettings.shield-configuration-service": .init(title: String(localized: "Screen Time shield", bundle: .greeceKit), symbol: "hourglass", tint: .indigo),
        "com.apple.system_extension.driver_extension": .init(title: String(localized: "Driver extension", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "cpu", tint: .gray, tone: .caution),
        "com.apple.system_extension.network_extension": .init(title: String(localized: "Network system extension", bundle: .greeceKit), symbol: "network.badge.shield.half.filled", tint: .blue, tone: .caution),
        "com.apple.system_extension.endpoint_security": .init(title: "Endpoint Security", symbol: "eye.fill", tint: .red, tone: .caution),
        "com.apple.cmio.camera-extension": .init(title: String(localized: "Virtual camera", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "web.camera.fill", tint: .gray),
        "com.apple.screensaver": .init(title: String(localized: "Screen saver", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "sparkles.tv.fill", tint: .indigo),
        "com.apple.wallpaper": .init(title: String(localized: "Wallpaper", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "photo.artframe", tint: .teal),
        "com.apple.textinputmethod": .init(title: String(localized: "Input method", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "character.cursor.ibeam", tint: .gray),
        "com.apple.dt.Xcode.extension.source-editor": .init(title: String(localized: "Xcode source editor", bundle: .greeceKit), symbol: "hammer.fill", tint: .blue),
        "com.apple.mail-extension": .init(title: String(localized: "Mail extension", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "envelope.fill", tint: .blue),
        "com.apple.printing.print-extension": .init(title: String(localized: "Printing", bundle: .greeceKit, comment: "Inspector row: a kind of app extension that adds printing options"), symbol: "printer.fill", tint: .gray),
        "com.apple.location.push.service": .init(title: String(localized: "Location push", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "location.fill", tint: .blue),
        "com.apple.ctk-tokens": .init(title: String(localized: "Smart card token", bundle: .greeceKit), symbol: "creditcard.fill", tint: .gray),
        "com.apple.dt.instruments.extension": .init(title: "Instruments", symbol: "gauge.with.needle", tint: .gray),
        "com.apple.diagnostic-extension": .init(title: String(localized: "Diagnostics", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "stethoscope", tint: .gray),
        "com.apple.contact.provider.extension": .init(title: String(localized: "Contacts provider", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "person.crop.circle.fill", tint: .brown),
        "com.apple.translation-provider": .init(title: String(localized: "Translation", bundle: .greeceKit, comment: "Inspector row: a kind of app extension that provides translations"), symbol: "translate", tint: .blue),
        "com.apple.storekit.app-store-extension": .init(title: "App Store", symbol: "bag.fill", tint: .blue),
        "com.apple.accessory-setup-extension": .init(title: String(localized: "Accessory setup", bundle: .greeceKit, comment: "Inspector row: a kind of app extension"), symbol: "cable.connector", tint: .gray),
    ]
}
