# Writes small v1 multi-file, single-file and hybrid v2 torrents.
import sys, hashlib
out = sys.argv[1]


def enc(v):
    if isinstance(v, int):
        return b'i%de' % v
    if isinstance(v, str):
        v = v.encode()
    if isinstance(v, bytes):
        return b'%d:%s' % (len(v), v)
    if isinstance(v, list):
        return b'l' + b''.join(enc(x) for x in v) + b'e'
    if isinstance(v, dict):
        keys = sorted(v, key=lambda k: k.encode() if isinstance(k, str) else k)
        return b'd' + b''.join(enc(k) + enc(v[k]) for k in keys) + b'e'
    raise TypeError(v)


multi = {
    'announce': 'udp://tracker.example.org:1337/announce',
    'announce-list': [['udp://tracker.example.org:1337/announce'], ['https://tracker.example.net/announce', 'http://backup.example.com/announce']],
    'comment': 'Greece fixture: a multi-file torrent.',
    'created by': 'Greece Fixtures 1.0',
    'creation date': 1795000000,
    'url-list': ['https://mirror.example.com/files/'],
    'info': {
        'name': 'Aegean Photos',
        'piece length': 262144,
        'pieces': hashlib.sha1(b'a').digest() + hashlib.sha1(b'b').digest() + hashlib.sha1(b'c').digest(),
        'private': 1,
        'source': 'GRC',
        'files': [
            {'length': 310000, 'path': ['Santorini', 'Oia sunset.jpg']},
            {'length': 205000, 'path': ['Santorini', 'Caldera.heic']},
            {'length': 52000, 'path': ['Naxos', 'Portara.png']},
            {'length': 1200, 'path': ['README.txt']},
        ],
    },
}
open(out + '/Aegean Photos.torrent', 'wb').write(enc(multi))
single = {
    'announce': 'http://tracker.example.org/announce',
    'creation date': 1790000000,
    'info': {'name': 'ubuntu-like.iso', 'length': 4700000000, 'piece length': 4194304, 'pieces': hashlib.sha1(b'x').digest() * 2},
}
open(out + '/Single File.torrent', 'wb').write(enc(single))
hybrid = {
    'announce': 'udp://tracker.example.org:1337/announce',
    'created by': 'qBittorrent v5',
    'info': {
        'name': 'Hybrid Set',
        'meta version': 2,
        'piece length': 16384,
        'pieces': hashlib.sha1(b'h').digest(),
        'files': [{'length': 9000, 'path': ['a.txt']}, {'length': 7000, 'path': ['b.txt']}],
        'file tree': {'a.txt': {'': {'length': 9000, 'pieces root': b'\x00' * 32}}, 'b.txt': {'': {'length': 7000, 'pieces root': b'\x01' * 32}}},
    },
}
open(out + '/Hybrid Set.torrent', 'wb').write(enc(hybrid))
