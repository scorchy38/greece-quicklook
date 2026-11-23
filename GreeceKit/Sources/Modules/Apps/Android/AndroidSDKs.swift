import Foundation

/// Third-party SDKs an app embeds, recognised from the components and metadata they add to the
/// manifest, the `.properties` markers Google's libraries leave, and native library names.
enum AndroidSDKs {
    private struct Signature {
        let name: String
        /// Prefixes of component class names, meta-data names or the application class.
        var classes: [String] = []
        /// Exact `<name>.properties` markers at the package root.
        var properties: [String] = []
        var libraries: [String] = []
    }

    private static let catalog: [Signature] = [
        Signature(name: "Firebase", classes: ["com.google.firebase."], properties: ["firebase-common", "firebase-components"]),
        Signature(name: "Firebase Analytics", classes: ["com.google.android.gms.measurement."], properties: ["firebase-analytics", "play-services-measurement"]),
        Signature(name: "Firebase Crashlytics", classes: ["com.google.firebase.crashlytics."], properties: ["firebase-crashlytics"]),
        Signature(name: "Firebase Cloud Messaging", classes: ["com.google.firebase.messaging."], properties: ["firebase-messaging"]),
        Signature(name: "Google Mobile Ads", classes: ["com.google.android.gms.ads.", "com.google.android.gms.ads.APPLICATION_ID"],
                  properties: ["play-services-ads", "play-services-ads-lite", "play-services-ads-base"]),
        Signature(name: "Google Maps", classes: ["com.google.android.geo.API_KEY", "com.google.android.gms.maps."], properties: ["play-services-maps"]),
        Signature(name: "Google Sign-In", classes: ["com.google.android.gms.auth.api.signin."], properties: ["play-services-auth"]),
        Signature(name: "Google Play Billing", classes: ["com.android.billingclient."], properties: ["billing"]),
        Signature(name: "Play Integrity", properties: ["integrity"]),
        Signature(name: "Meta (Facebook) SDK", classes: ["com.facebook.FacebookActivity", "com.facebook.sdk.", "com.facebook.CustomTabActivity", "com.facebook.internal."]),
        Signature(name: "AppsFlyer", classes: ["com.appsflyer."]),
        Signature(name: "Adjust", classes: ["com.adjust.sdk."]),
        Signature(name: "Branch", classes: ["io.branch."]),
        Signature(name: "OneSignal", classes: ["com.onesignal."]),
        Signature(name: "Braze", classes: ["com.braze.", "com.appboy."]),
        Signature(name: "CleverTap", classes: ["com.clevertap."]),
        Signature(name: "MoEngage", classes: ["com.moengage."]),
        Signature(name: "Mixpanel", classes: ["com.mixpanel."]),
        Signature(name: "Amplitude", classes: ["com.amplitude."]),
        Signature(name: "Segment", classes: ["com.segment."]),
        Signature(name: "Sentry", classes: ["io.sentry."], libraries: ["libsentry.so", "libsentry-android.so"]),
        Signature(name: "Bugsnag", classes: ["com.bugsnag."], libraries: ["libbugsnag-ndk.so"]),
        Signature(name: "Instabug", classes: ["com.instabug."]),
        Signature(name: "UXCam", classes: ["com.uxcam."]),
        Signature(name: "Intercom", classes: ["io.intercom."]),
        Signature(name: "Zendesk", classes: ["zendesk.", "com.zendesk."]),
        Signature(name: "RevenueCat", classes: ["com.revenuecat."]),
        Signature(name: "Stripe", classes: ["com.stripe."]),
        Signature(name: "Razorpay", classes: ["com.razorpay."]),
        Signature(name: "PayPal", classes: ["com.paypal."]),
        Signature(name: "Amazon In-App Purchasing", classes: ["com.amazon.device.iap."]),
        Signature(name: "AppLovin", classes: ["com.applovin."]),
        Signature(name: "Unity Ads", classes: ["com.unity3d.ads.", "com.unity3d.services."]),
        Signature(name: "ironSource", classes: ["com.ironsource."]),
        Signature(name: "Vungle", classes: ["com.vungle."]),
        Signature(name: "Chartboost", classes: ["com.chartboost."]),
        Signature(name: "Realm", libraries: ["librealm-jni.so", "librealm_dart.so"]),
        Signature(name: "SQLCipher", libraries: ["libsqlcipher.so"]),
        Signature(name: "Agora", classes: ["io.agora."], libraries: ["libagora-rtc-sdk.so"]),
        Signature(name: "Google Play Services", properties: ["play-services-basement"]),
    ]

    static func detect(package: AndroidPackage, properties: Set<String>, libraries: Set<String>) -> [String] {
        var classes = (package.activities + package.services + package.receivers + package.providers).map(\.name)
        classes += package.metaDataNames
        if let application = package.applicationClass { classes.append(application) }
        var found: [String] = []
        for signature in catalog {
            let byClass = signature.classes.contains { prefix in classes.contains { $0.hasPrefix(prefix) } }
            let byProperty = signature.properties.contains { properties.contains($0) }
            let byLibrary = signature.libraries.contains { libraries.contains($0) }
            if byClass || byProperty || byLibrary { found.append(signature.name) }
        }
        return found
    }
}
