#ifndef COMPACT_PRO_H
#define COMPACT_PRO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
	CP_OK = 0,
	CP_ERR_INVALID_ARGUMENT = 1,
	CP_ERR_INVALID_MARKER = 2,
	CP_ERR_TRUNCATED = 3,
	CP_ERR_INVALID_HEADER_OFFSET = 4,
	CP_ERR_HEADER_CRC_MISMATCH = 5,
	CP_ERR_UNSUPPORTED_ENCRYPTED = 6,
	CP_ERR_UNSUPPORTED_LZH = 7,
	CP_ERR_INVALID_NAME_LENGTH = 8,
	CP_ERR_TOO_MANY_ENTRIES = 9,
	CP_ERR_COMMENT_TOO_LONG = 10,
	CP_ERR_OFFSET_OUT_OF_RANGE = 11,
	CP_ERR_FILE_CRC_MISMATCH = 12,
	CP_ERR_INVALID_RUN_LENGTH_ONE = 13,
	CP_ERR_OUTPUT_LENGTH_MISMATCH = 14,
	CP_ERR_UNEXPECTED_END_OF_STREAM = 15,
	CP_ERR_OUT_OF_MEMORY = 100,
	CP_ERR_UNKNOWN = 255
};

typedef struct {
	const uint8_t *name_ptr;
	size_t name_len;
	const uint8_t *data_ptr;
	size_t data_len;
	const uint8_t *resource_ptr;
	size_t resource_len;
	uint32_t file_type;
	uint32_t creator;
	uint32_t created;
	uint32_t modified;
	uint16_t finder_flags;
} cp_entry_input;

typedef struct {
	uint8_t *ptr;
	size_t len;
} cp_buffer;

typedef struct {
	uint8_t *name_ptr;
	size_t name_len;
	uint8_t *data_ptr;
	size_t data_len;
	uint8_t *resource_ptr;
	size_t resource_len;
	uint32_t file_type;
	uint32_t creator;
	uint32_t created;
	uint32_t modified;
	uint16_t finder_flags;
} cp_entry_output;

typedef struct {
	uint8_t *comment_ptr;
	size_t comment_len;
	cp_entry_output *entries_ptr;
	size_t entry_count;
} cp_archive_output;

typedef struct {
	uint8_t *name_ptr;
	size_t name_len;
	uint32_t resource_uncompressed_len;
	uint32_t data_uncompressed_len;
	uint16_t flags;
} cp_list_entry;

typedef struct {
	uint8_t *comment_ptr;
	size_t comment_len;
	cp_list_entry *entries_ptr;
	size_t entry_count;
} cp_archive_listing;

typedef void (*cp_progress_fn)(void *ctx, size_t done, size_t total);

int cp_archive_create_with_progress(
	const cp_entry_input *entries,
	size_t entry_count,
	const uint8_t *comment,
	size_t comment_len,
	cp_buffer *out_archive,
	cp_progress_fn progress_cb,
	void *progress_ctx
);

int cp_archive_create(
	const cp_entry_input *entries,
	size_t entry_count,
	const uint8_t *comment,
	size_t comment_len,
	cp_buffer *out_archive
);

int cp_archive_add(
	const uint8_t *archive,
	size_t archive_len,
	const cp_entry_input *entries,
	size_t entry_count,
	cp_buffer *out_archive
);

int cp_archive_extract(
	const uint8_t *archive,
	size_t archive_len,
	int strict_crc,
	cp_archive_output *out_archive
);

int cp_archive_list(
	const uint8_t *archive,
	size_t archive_len,
	int strict_crc,
	cp_archive_listing *out_listing
);

void cp_buffer_free(cp_buffer *buffer);
void cp_archive_output_free(cp_archive_output *archive);
void cp_archive_listing_free(cp_archive_listing *listing);
const char *cp_error_string(int code);

#ifdef __cplusplus
}
#endif

#endif
