// The subset of libarchive's read API that Greece's archive browser uses.
// The macOS SDK ships /usr/lib/libarchive.tbd (libarchive 3.7) without headers, so these
// prototypes mirror archive.h and archive_entry.h for that version.
#ifndef GREECE_LIBARCHIVE_H
#define GREECE_LIBARCHIVE_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <wchar.h>
#include <time.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF       1
#define ARCHIVE_OK        0
#define ARCHIVE_RETRY   (-10)
#define ARCHIVE_WARN    (-20)
#define ARCHIVE_FAILED  (-25)
#define ARCHIVE_FATAL   (-30)

#define ARCHIVE_FORMAT_BASE_MASK  0xff0000
#define ARCHIVE_FORMAT_CPIO       0x10000
#define ARCHIVE_FORMAT_TAR        0x30000
#define ARCHIVE_FORMAT_ISO9660    0x40000
#define ARCHIVE_FORMAT_ZIP        0x50000
#define ARCHIVE_FORMAT_EMPTY      0x60000
#define ARCHIVE_FORMAT_AR         0x70000
#define ARCHIVE_FORMAT_RAW        0x90000
#define ARCHIVE_FORMAT_XAR        0xA0000
#define ARCHIVE_FORMAT_LHA        0xB0000
#define ARCHIVE_FORMAT_CAB        0xC0000
#define ARCHIVE_FORMAT_RAR        0xD0000
#define ARCHIVE_FORMAT_7ZIP       0xE0000
#define ARCHIVE_FORMAT_WARC       0xF0000
#define ARCHIVE_FORMAT_RAR_V5     0x100000

#define ARCHIVE_FILTER_NONE      0
#define ARCHIVE_FILTER_GZIP      1
#define ARCHIVE_FILTER_BZIP2     2
#define ARCHIVE_FILTER_COMPRESS  3
#define ARCHIVE_FILTER_LZMA      5
#define ARCHIVE_FILTER_XZ        6
#define ARCHIVE_FILTER_UU        7
#define ARCHIVE_FILTER_RPM       8
#define ARCHIVE_FILTER_LZIP      9

#define ARCHIVE_READ_FORMAT_ENCRYPTION_UNSUPPORTED  (-2)
#define ARCHIVE_READ_FORMAT_ENCRYPTION_DONT_KNOW    (-1)

typedef ssize_t archive_read_callback(struct archive *, void *client_data, const void **buffer);
typedef int64_t archive_skip_callback(struct archive *, void *client_data, int64_t request);
typedef int64_t archive_seek_callback(struct archive *, void *client_data, int64_t offset, int whence);
typedef int archive_open_callback(struct archive *, void *client_data);
typedef int archive_close_callback(struct archive *, void *client_data);

struct archive *archive_read_new(void);
int archive_read_free(struct archive *);

// Filters that decode in process. zstd, lz4, lzop, grzip and lrzip are deliberately absent: this
// build of libarchive would run external programs for them, which a sandboxed preview must never do.
int archive_read_support_filter_none(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_filter_lzma(struct archive *);
int archive_read_support_filter_lzip(struct archive *);
int archive_read_support_filter_compress(struct archive *);
int archive_read_support_filter_uu(struct archive *);
int archive_read_support_filter_rpm(struct archive *);

int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_ar(struct archive *);
int archive_read_support_format_cab(struct archive *);
int archive_read_support_format_cpio(struct archive *);
int archive_read_support_format_empty(struct archive *);
int archive_read_support_format_iso9660(struct archive *);
int archive_read_support_format_lha(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_xar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_format_zip_seekable(struct archive *);

int archive_read_set_options(struct archive *, const char *options);

int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_open_filenames(struct archive *, const char **filenames, size_t block_size);
int archive_read_open_memory(struct archive *, const void *buffer, size_t size);

int archive_read_set_open_callback(struct archive *, archive_open_callback *);
int archive_read_set_read_callback(struct archive *, archive_read_callback *);
int archive_read_set_seek_callback(struct archive *, archive_seek_callback *);
int archive_read_set_skip_callback(struct archive *, archive_skip_callback *);
int archive_read_set_close_callback(struct archive *, archive_close_callback *);
int archive_read_set_callback_data(struct archive *, void *client_data);
int archive_read_open1(struct archive *);

int archive_read_next_header(struct archive *, struct archive_entry **);
int64_t archive_read_header_position(struct archive *);
ssize_t archive_read_data(struct archive *, void *buffer, size_t size);
int archive_read_data_skip(struct archive *);
int archive_read_has_encrypted_entries(struct archive *);

int archive_errno(struct archive *);
const char *archive_error_string(struct archive *);
int archive_format(struct archive *);
const char *archive_format_name(struct archive *);
int archive_filter_count(struct archive *);
int archive_filter_code(struct archive *, int index);
int archive_file_count(struct archive *);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const wchar_t *archive_entry_pathname_w(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
const char *archive_entry_uname(struct archive_entry *);
const char *archive_entry_gname(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
int archive_entry_is_data_encrypted(struct archive_entry *);
int archive_entry_is_metadata_encrypted(struct archive_entry *);

#endif
