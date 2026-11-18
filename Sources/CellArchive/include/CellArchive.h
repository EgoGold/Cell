#ifndef CELL_ARCHIVE_H
#define CELL_ARCHIVE_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

// Public libarchive API. macOS ships the library but the SDK omits its headers.
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
unsigned int archive_entry_filetype(struct archive_entry *);
unsigned int archive_entry_perm(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
#endif
