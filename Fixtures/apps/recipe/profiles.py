import plistlib, sys, datetime
cert = open(sys.argv[1], 'rb').read()
out = sys.argv[2]
now = datetime.datetime(2026, 11, 20, 10, 0, 0)


def profile(name, created, expires, devices, debuggable, uid):
    return {
        'AppIDName': 'Tiny', 'ApplicationIdentifierPrefix': ['FIXTURE01'], 'CreationDate': created,
        'Platform': ['iOS', 'xrOS'], 'IsXcodeManaged': True, 'DeveloperCertificates': [cert],
        'Entitlements': {'application-identifier': 'FIXTURE01.com.scorchy.greece.fixture.tiny', 'keychain-access-groups': ['FIXTURE01.*'],
                         'get-task-allow': debuggable, 'com.apple.developer.team-identifier': 'FIXTURE01', 'aps-environment': 'development'},
        'ExpirationDate': expires, 'Name': name, 'ProvisionedDevices': devices, 'TeamIdentifier': ['FIXTURE01'],
        'TeamName': 'Greece Fixtures', 'TimeToLive': 365, 'UUID': uid, 'Version': 1,
    }


devices = ['00008110-000A1B2C3D4E5F60', '00008120-001122334455667A', '00008030-000F0E0D0C0B0A09']
p = profile('iOS Team Provisioning Profile: com.scorchy.greece.fixture.tiny', now, datetime.datetime(2036, 11, 20, 10, 0, 0), devices, True,
            'A1B2C3D4-0000-4000-8000-000000000001')
plistlib.dump(p, open(out + '/profile.plist', 'wb'))
e = profile('Tiny Ad Hoc', datetime.datetime(2024, 1, 5), datetime.datetime(2025, 1, 5), devices[:2], False, 'A1B2C3D4-0000-4000-8000-000000000002')
plistlib.dump(e, open(out + '/expired.plist', 'wb'))
config = {
    'PayloadDisplayName': 'Greece Office', 'PayloadOrganization': 'Greece Fixtures', 'PayloadIdentifier': 'com.scorchy.greece.fixture.profile',
    'PayloadDescription': 'Wi-Fi, a web clip and restrictions for testing.', 'PayloadType': 'Configuration',
    'PayloadUUID': '9E1F2A3B-0000-4000-8000-0000000000AA', 'PayloadVersion': 1, 'PayloadScope': 'System', 'PayloadRemovalDisallowed': False,
    'PayloadContent': [
        {'PayloadType': 'com.apple.wifi.managed', 'PayloadDisplayName': 'Office Wi-Fi', 'PayloadIdentifier': 'wifi', 'PayloadUUID': 'B1',
         'PayloadVersion': 1, 'SSID_STR': 'Greece-Office', 'EncryptionType': 'WPA2', 'AutoJoin': True},
        {'PayloadType': 'com.apple.webClip.managed', 'PayloadIdentifier': 'clip', 'PayloadUUID': 'B2', 'PayloadVersion': 1, 'Label': 'Intranet',
         'URL': 'https://intranet.example.com'},
        {'PayloadType': 'com.apple.security.root', 'PayloadDisplayName': 'Greece Root CA', 'PayloadIdentifier': 'root', 'PayloadUUID': 'B3',
         'PayloadVersion': 1, 'PayloadContent': cert},
        {'PayloadType': 'com.apple.applicationaccess', 'PayloadIdentifier': 'restrictions', 'PayloadUUID': 'B4', 'PayloadVersion': 1,
         'allowCamera': False, 'allowAirDrop': False},
    ],
}
plistlib.dump(config, open(out + '/config.plist', 'wb'))
