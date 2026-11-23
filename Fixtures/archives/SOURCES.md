# Archive fixtures

Small samples for `GreeceKitTests/ArchivesTests.swift` and visual checks. Formats macOS can write
(ZIP, 7z, tar and its compressors, cpio, xar, ISO, split and spanned ZIPs, encrypted ZIPs) are made by the
tests themselves with `/usr/bin/tar`, `/usr/bin/zip` and friends, so they aren't stored here.

## packages/ and comics/

Made from scratch for these tests: the packages are fictional ("harbourmaster", "Lighthouse Keeper",
"Tide Clock"…), and the icons and comic pages are drawn with SF Symbols and Core Graphics. Rebuild them with:

```sh
swift Fixtures/archives/make-images.swift /tmp/greece-images
python3 -I Fixtures/archives/make-packages.py /tmp/greece-images Fixtures/archives
```

`make-packages.py` writes every format by hand (wheel, sdist, JAR, nupkg, VSIX, XPI, CRX3, an APK with binary
XML, an AAB with protobuf XML, gem, a .deb with a zstd data member, an RPM with a zstd payload, an npm
tarball, CBZ/CBT, and CB7 through `/usr/bin/tar`). It needs `zstd` on the PATH.

## libarchive/

Copied from libarchive's own test suite, tag `v3.7.4`, `libarchive/test/*.uu` (uudecoded, renamed).
libarchive is BSD-2-Clause: <https://github.com/libarchive/libarchive/blob/v3.7.4/COPYING>.

| File | Original |
|---|---|
| `rar4.rar` | `test_read_format_rar.rar` |
| `rar4-unicode.rar` | `test_read_format_rar_unicode.rar` |
| `rar4-encrypted-header.rar` | `test_read_format_rar_encryption_header.rar` |
| `rar4-encrypted-data.rar` | `test_read_format_rar_encryption_data.rar` |
| `rar5.rar` | `test_read_format_rar5_multiple_files.rar` |
| `rar5-solid.rar` | `test_read_format_rar5_solid.rar` |
| `rar5-unicode.rar` | `test_read_format_rar5_unicode.rar` |
| `rar-volumes/volumes.part1-6.rar` | `test_rar_multivolume_multiple_files.part1-6.rar` |
| `7z-encrypted-header.7z` | `test_read_format_7zip_encryption_header.7z` |
| `7z-encrypted-data.7z` | `test_read_format_7zip_encryption.7z` |
| `7z-ppmd.7z` | `test_read_format_7zip_ppmd.7z` |
| `mszip.cab`, `lzx.cab` | `test_read_format_cab_2.cab`, `test_read_format_cab_3.cab` |
| `lh6.lzh`, `cp932.lzh` | `test_read_format_lha_lh6.lzh`, `test_read_format_lha_filename_cp932.lzh` |
| `koi8r.cpio` | `test_read_format_cpio_filename_koi8r.cpio` |
| `cp866.zip`, `cp932.zip` | `test_read_format_zip_filename_cp866.zip`, `test_read_format_zip_filename_cp932.zip` |
| `encrypted-header.zip`, `aes256.zip` | `test_read_format_zip_encryption_header.zip`, `test_read_format_zip_winzip_aes256.zip` |
| `zstd.zipx`, `lzma.zipx` | `test_read_format_zip_zstd.zipx`, `test_read_format_zip_lzma.zipx` |
| `gzip-payload.rpm` | `test_read_format_cpio_svr4_gzip_rpm.rpm` |
| `compat.tar.zst` | `test_compat_zstd_1.tar.zst` |
