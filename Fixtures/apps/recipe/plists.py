# Writes the Info.plists and entitlements used by build.sh into this folder.
import plistlib, os, datetime
here = os.path.dirname(os.path.abspath(__file__))


def save(name, value):
    plistlib.dump(value, open(os.path.join(here, name), 'wb'))


save('Tiny-Info.plist', {
    'CFBundleExecutable': 'Tiny', 'CFBundleIdentifier': 'com.scorchy.greece.fixture.tiny', 'CFBundleName': 'Tiny',
    'CFBundleDisplayName': 'Tiny', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '2.1', 'CFBundleVersion': '214',
    'CFBundleSupportedPlatforms': ['MacOSX'], 'LSMinimumSystemVersion': '14.0',
    'LSApplicationCategoryType': 'public.app-category.developer-tools', 'DTSDKName': 'macosx26.5', 'DTXcode': '2660',
    'DTXcodeBuild': '17F42', 'NSHumanReadableCopyright': 'Copyright © 2026 Greece Fixtures',
    'NSCameraUsageDescription': 'Tiny uses the camera to scan documents.',
    'NSMicrophoneUsageDescription': 'Tiny records voice notes.',
    'NSAppleEventsUsageDescription': 'Tiny automates Finder to reveal files.',
    'CFBundleURLTypes': [{'CFBundleURLName': 'Tiny links', 'CFBundleURLSchemes': ['tiny']}],
    'CFBundleDocumentTypes': [
        {'CFBundleTypeName': 'Tiny Document', 'CFBundleTypeRole': 'Editor', 'LSHandlerRank': 'Owner', 'CFBundleTypeExtensions': ['tiny']},
        {'CFBundleTypeName': 'Plain Text', 'CFBundleTypeRole': 'Viewer', 'LSItemContentTypes': ['public.plain-text']},
    ],
    'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
    'SUFeedURL': 'https://example.com/tiny/appcast.xml',
})
save('Appex-Info.plist', {
    'CFBundleExecutable': 'TinyPreview', 'CFBundleIdentifier': 'com.scorchy.greece.fixture.tiny.preview', 'CFBundleName': 'TinyPreview',
    'CFBundleDisplayName': 'Tiny Preview', 'CFBundlePackageType': 'XPC!', 'CFBundleShortVersionString': '2.1', 'CFBundleVersion': '214',
    'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.quicklook.preview'},
})
save('Helper-Info.plist', {
    'CFBundleExecutable': 'TinyHelper', 'CFBundleIdentifier': 'com.scorchy.greece.fixture.tiny.helper', 'CFBundleName': 'TinyHelper',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0', 'LSBackgroundOnly': True,
})
save('Tiny.entitlements', {
    'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True, 'com.apple.security.device.camera': True,
    'com.apple.security.device.audio-input': True, 'com.apple.security.files.user-selected.read-write': True,
    'com.apple.security.automation.apple-events': True,
    'com.apple.security.application-groups': ['FIXTURE01.com.scorchy.greece.fixture'],
})
save('tool.entitlements', {'com.apple.security.cs.allow-jit': True, 'com.apple.security.cs.disable-library-validation': True})
save('tool-info.plist', {'CFBundleIdentifier': 'com.scorchy.greece.fixture.tool', 'CFBundleName': 'greece-tool',
                         'CFBundleShortVersionString': '1.4', 'CFBundleVersion': '14'})
save('iOS.entitlements', {
    'application-identifier': 'FIXTURE01.com.scorchy.greece.fixture.tiny', 'com.apple.developer.team-identifier': 'FIXTURE01',
    'get-task-allow': True, 'aps-environment': 'development', 'com.apple.developer.associated-domains': ['applinks:example.com'],
})
save('PrivacyInfo.xcprivacy', {
    'NSPrivacyTracking': False,
    'NSPrivacyCollectedDataTypes': [
        {'NSPrivacyCollectedDataType': 'NSPrivacyCollectedDataTypeEmailAddress', 'NSPrivacyCollectedDataTypeLinked': True,
         'NSPrivacyCollectedDataTypeTracking': False, 'NSPrivacyCollectedDataTypePurposes': ['NSPrivacyCollectedDataTypePurposeAppFunctionality']},
        {'NSPrivacyCollectedDataType': 'NSPrivacyCollectedDataTypeCrashData', 'NSPrivacyCollectedDataTypeLinked': False,
         'NSPrivacyCollectedDataTypeTracking': False, 'NSPrivacyCollectedDataTypePurposes': ['NSPrivacyCollectedDataTypePurposeAnalytics']},
    ],
    'NSPrivacyAccessedAPITypes': [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults', 'NSPrivacyAccessedAPITypeReasons': ['CA92.1']}],
})
save('Archive-Info.plist', {
    'ApplicationProperties': {
        'ApplicationPath': 'Applications/Tiny.app', 'Architectures': ['arm64', 'x86_64'], 'CFBundleIdentifier': 'com.scorchy.greece.fixture.tiny',
        'CFBundleShortVersionString': '2.1', 'CFBundleVersion': '214', 'SigningIdentity': 'Apple Development: Greece Fixture (FIXTURE01)',
        'Team': 'FIXTURE01',
    },
    'ArchiveVersion': 2, 'CreationDate': datetime.datetime(2026, 11, 20, 10, 0, 0), 'Name': 'Tiny', 'SchemeName': 'Tiny',
})
save('iOS-Info.plist', {
    'CFBundleExecutable': 'Tiny', 'CFBundleIdentifier': 'com.scorchy.greece.fixture.tiny', 'CFBundleName': 'Tiny', 'CFBundleDisplayName': 'Tiny',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '2.1', 'CFBundleVersion': '214', 'CFBundleSupportedPlatforms': ['iPhoneOS'],
    'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1, 2], 'DTPlatformName': 'iphoneos', 'DTSDKName': 'iphoneos26.5',
    'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60'], 'CFBundleIconName': 'AppIcon'}},
    'NSCameraUsageDescription': 'Tiny scans documents with the camera.',
    'NSLocationWhenInUseUsageDescription': 'Tiny tags notes with where you took them.',
    'NSUserTrackingUsageDescription': 'Tiny never tracks you; this string exists for testing.',
    'CFBundleURLTypes': [{'CFBundleURLSchemes': ['tiny']}],
})
print('plists written')
