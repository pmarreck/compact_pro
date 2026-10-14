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
	CP_ERR_READ_FAILED = 16,
	CP_ERR_SINK_ABORTED = 17,
	CP_ERR_LZH_INVALID_CODEBOOK = 18,
	CP_ERR_LZH_INVALID_HUFFMAN_CODE = 19,
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

/* Like cp_archive_extract, but decodes entries on up to `workers` threads
 * (0 = CPU count, capped at 16). Results and error codes are identical to
 * cp_archive_extract. */
int cp_archive_extract_parallel(
	const uint8_t *archive,
	size_t archive_len,
	int strict_crc,
	size_t workers,
	cp_archive_output *out_archive
);

int cp_archive_list(
	const uint8_t *archive,
	size_t archive_len,
	int strict_crc,
	cp_archive_listing *out_listing
);

enum {
	CP_FORK_DATA = 0,
	CP_FORK_RESOURCE = 1
};

/* Copies up to `length` bytes at `offset` into `buffer` and stores the count
 * in `*out_read`. Return 0 on success, nonzero on I/O failure. A zero count
 * before `size` is reached is treated as CP_ERR_READ_FAILED. */
typedef int (*cp_read_at_fn)(void *ctx, uint64_t offset, uint8_t *buffer, size_t length, size_t *out_read);

/* Receives decoded fork bytes in order. Bytes are unverified until the call
 * that produced them returns CP_OK. Return 0 to continue, nonzero to stop
 * with CP_ERR_SINK_ABORTED. */
typedef int (*cp_fork_sink_fn)(void *ctx, size_t entry_index, int fork_kind, const uint8_t *bytes, size_t length);

typedef struct {
	cp_read_at_fn read_at;
	void *ctx;
	uint64_t size;
} cp_range_source;

/* On failure, error_offset is the archive offset just past the last byte
 * consumed when the error was raised (for a header or file CRC mismatch, the
 * start of the covered region). It is CP_NO_ERROR_OFFSET when unknown or on
 * success. */
#define CP_NO_ERROR_OFFSET UINT64_MAX
typedef struct {
	size_t entry_count;
	uint64_t total_uncompressed;
	uint64_t error_offset;
} cp_verify_summary;

/* Bounded-memory verification: reads the archive through `source`, decodes
 * every fork and checks CRCs like cp_archive_extract (same error codes),
 * without retaining the archive or its output. `sink` may be NULL;
 * `out_summary` may be NULL. */
int cp_archive_verify_stream(
	const cp_range_source *source,
	int strict_crc,
	cp_fork_sink_fn sink,
	void *sink_ctx,
	cp_verify_summary *out_summary
);

/* Like cp_archive_verify_stream without a sink, but verifies entries on up
 * to `workers` threads (0 = CPU count, capped at 16). Heap use is about
 * workers x 128 KiB plus the entry table. source->read_at is called from several threads at
 * once and must be thread-safe. The return code and out_summary (including
 * error_offset) equal those of the sequential call. */
int cp_archive_verify_stream_parallel(
	const cp_range_source *source,
	int strict_crc,
	size_t workers,
	cp_verify_summary *out_summary
);

void cp_buffer_free(cp_buffer *buffer);
void cp_archive_output_free(cp_archive_output *archive);
void cp_archive_listing_free(cp_archive_listing *listing);
const char *cp_error_string(int code);

#ifdef __cplusplus
}
#endif

#endif
