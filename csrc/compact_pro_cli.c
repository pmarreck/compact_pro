#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <utime.h>

#if defined(__linux__)
#include <sys/xattr.h>
#endif
#if defined(_WIN32)
#include <direct.h>
#endif

#include "compact_pro.h"

typedef enum {
	RSRC_DEFAULT = 0,
	RSRC_SIDECAR,
	RSRC_EXPLICIT,
	RSRC_XATTR,
} rsrc_mode;

typedef struct {
	rsrc_mode mode;
	const char *rsrc_path;
	const char *xattr_name;
} selectors;

typedef struct {
	uint8_t *data;
	size_t data_len;
	uint8_t *resource;
	size_t resource_len;
	char *archive_name;
	uint32_t mode_bits;
	int64_t mtime_unix;
} input_owned;

typedef struct {
	const uint8_t *name_ptr;
	size_t name_len;
	uint32_t mode_bits;
	int64_t mtime_unix;
} meta_source;

typedef struct {
	char *name;
	uint32_t mode_bits;
	int64_t mtime_unix;
} meta_record;

static const uint8_t meta_magic[8] = { 'C', 'P', 'M', 'E', 'T', 'A', '1', '\n' };
static const uint8_t meta_trailer_magic[8] = { 'C', 'P', 'X', 'T', 'R', 'L', 'R', '1' };
static const uint32_t meta_trailer_version = 1;

static void print_help(void) {
	puts("compact-pro");
	puts("");
	puts("Usage:");
	puts("  compact-pro compress [--sidecar|--rsrc <path>|--xattr <name>] -o <archive.cpt> <file...>");
	puts("  compact-pro expand [--sidecar|--rsrc <path>|--xattr <name>] <archive.cpt> [-d <outdir>] [--path <entry> ...]");
	puts("  compact-pro add [--sidecar|--rsrc <path>|--xattr <name>] <archive.cpt> <file...>");
	puts("  compact-pro list <archive.cpt>");
	puts("  compact-pro --help");
	puts("");
	puts("Resource fork options:");
	puts("  --sidecar       Read/write AppleDouble sidecar (._<name>)");
	puts("  --rsrc <path>   Read/write explicit sidecar path");
	puts("  --xattr <name>  Linux-only xattr key");
}

static int fail(const char *msg) {
	fprintf(stderr, "error: %s\n", msg);
	return 1;
}

static const char *basename_ptr(const char *path) {
	const char *slash = strrchr(path, '/');
#if defined(_WIN32)
	const char *bslash = strrchr(path, '\\');
	if (bslash != NULL && (slash == NULL || bslash > slash)) slash = bslash;
#endif
	return slash == NULL ? path : slash + 1;
}

static char *xstrdup(const char *s) {
	size_t len = strlen(s);
	char *out = (char *)malloc(len + 1);
	if (out == NULL) return NULL;
	memcpy(out, s, len + 1);
	return out;
}

static char *normalize_archive_name(const char *path) {
	const char *start = path;
	while (start[0] == '.' && start[1] == '/') start += 2;
	if (start[0] == '/') return xstrdup(basename_ptr(path));
	return xstrdup(start);
}

static int ensure_parent_dirs(const char *path) {
	char *tmp = xstrdup(path);
	if (tmp == NULL) return fail("out of memory");

#if defined(_WIN32)
#define PATH_SEP_1 '/'
#define PATH_SEP_2 '\\'
#else
#define PATH_SEP_1 '/'
#define PATH_SEP_2 '/'
#endif

#if defined(_WIN32)
#define MKDIR_PORTABLE(p) _mkdir(p)
#else
#define MKDIR_PORTABLE(p) mkdir((p), 0755)
#endif

	for (char *p = tmp + 1; *p != '\0'; ++p) {
		if (*p != PATH_SEP_1 && *p != PATH_SEP_2) continue;
		*p = '\0';
		if (MKDIR_PORTABLE(tmp) != 0 && errno != EEXIST) {
			fprintf(stderr, "error: mkdir failed for %s: %s\n", tmp, strerror(errno));
			free(tmp);
			return 1;
		}
		*p = PATH_SEP_1;
	}

	free(tmp);

#undef PATH_SEP_1
#undef PATH_SEP_2
#undef MKDIR_PORTABLE
	return 0;
}

static int read_file_optional(const char *path, uint8_t **out, size_t *out_len) {
	*out = NULL;
	*out_len = 0;
	FILE *f = fopen(path, "rb");
	if (f == NULL) {
		if (errno == ENOENT) return 0;
		fprintf(stderr, "error: open failed for %s: %s\n", path, strerror(errno));
		return 1;
	}

	if (fseek(f, 0, SEEK_END) != 0) {
		fprintf(stderr, "error: fseek failed for %s\n", path);
		fclose(f);
		return 1;
	}
	long size = ftell(f);
	if (size < 0) {
		fprintf(stderr, "error: ftell failed for %s\n", path);
		fclose(f);
		return 1;
	}
	if (fseek(f, 0, SEEK_SET) != 0) {
		fprintf(stderr, "error: fseek rewind failed for %s\n", path);
		fclose(f);
		return 1;
	}

	if (size == 0) {
		fclose(f);
		return 0;
	}

	uint8_t *buf = (uint8_t *)malloc((size_t)size);
	if (buf == NULL) {
		fclose(f);
		return fail("out of memory");
	}
	if (fread(buf, 1, (size_t)size, f) != (size_t)size) {
		fprintf(stderr, "error: read failed for %s\n", path);
		free(buf);
		fclose(f);
		return 1;
	}
	fclose(f);
	*out = buf;
	*out_len = (size_t)size;
	return 0;
}

static int read_file_required(const char *path, uint8_t **out, size_t *out_len) {
	if (read_file_optional(path, out, out_len) != 0) return 1;
	if (*out == NULL && *out_len == 0) {
		FILE *f = fopen(path, "rb");
		if (f == NULL) {
			fprintf(stderr, "error: file not found: %s\n", path);
			return 1;
		}
		fclose(f);
	}
	return 0;
}

static int write_file(const char *path, const uint8_t *data, size_t len) {
	if (ensure_parent_dirs(path) != 0) return 1;
	FILE *f = fopen(path, "wb");
	if (f == NULL) {
		fprintf(stderr, "error: open for write failed for %s: %s\n", path, strerror(errno));
		return 1;
	}
	if (len > 0 && fwrite(data, 1, len, f) != len) {
		fprintf(stderr, "error: write failed for %s\n", path);
		fclose(f);
		return 1;
	}
	if (fclose(f) != 0) {
		fprintf(stderr, "error: close failed for %s\n", path);
		return 1;
	}
	return 0;
}

static char *join_path(const char *left, const char *right) {
	size_t left_len = strlen(left);
	size_t right_len = strlen(right);
	bool add_sep = left_len > 0 && left[left_len - 1] != '/';
	size_t total = left_len + (add_sep ? 1 : 0) + right_len + 1;
	char *out = (char *)malloc(total);
	if (out == NULL) return NULL;
	memcpy(out, left, left_len);
	size_t idx = left_len;
	if (add_sep) out[idx++] = '/';
	memcpy(out + idx, right, right_len);
	out[idx + right_len] = '\0';
	return out;
}

static void write_u32_le(uint8_t *dst, uint32_t v) {
	dst[0] = (uint8_t)(v & 0xFFu);
	dst[1] = (uint8_t)((v >> 8) & 0xFFu);
	dst[2] = (uint8_t)((v >> 16) & 0xFFu);
	dst[3] = (uint8_t)((v >> 24) & 0xFFu);
}

static void write_i64_le(uint8_t *dst, int64_t v) {
	uint64_t u = (uint64_t)v;
	for (size_t i = 0; i < 8; ++i) dst[i] = (uint8_t)((u >> (8 * i)) & 0xFFu);
}

static uint32_t read_u32_le(const uint8_t *src) {
	return (uint32_t)src[0] |
		((uint32_t)src[1] << 8) |
		((uint32_t)src[2] << 16) |
		((uint32_t)src[3] << 24);
}

static int64_t read_i64_le(const uint8_t *src) {
	uint64_t u = 0;
	for (size_t i = 0; i < 8; ++i) u |= ((uint64_t)src[i]) << (8 * i);
	return (int64_t)u;
}

static int build_metadata_blob(const meta_source *sources, size_t count, uint8_t **out_blob, size_t *out_len) {
	*out_blob = NULL;
	*out_len = 0;
	size_t total = 8 + 4;
	for (size_t i = 0; i < count; ++i) {
		total += 4 + sources[i].name_len + 4 + 8;
	}
	uint8_t *buf = (uint8_t *)malloc(total);
	if (buf == NULL) return fail("out of memory");
	size_t off = 0;
	memcpy(buf + off, meta_magic, 8);
	off += 8;
	write_u32_le(buf + off, (uint32_t)count);
	off += 4;
	for (size_t i = 0; i < count; ++i) {
		write_u32_le(buf + off, (uint32_t)sources[i].name_len);
		off += 4;
		memcpy(buf + off, sources[i].name_ptr, sources[i].name_len);
		off += sources[i].name_len;
		write_u32_le(buf + off, sources[i].mode_bits);
		off += 4;
		write_i64_le(buf + off, sources[i].mtime_unix);
		off += 8;
	}
	*out_blob = buf;
	*out_len = total;
	return 0;
}

static void free_meta_records(meta_record *records, size_t count) {
	if (records == NULL) return;
	for (size_t i = 0; i < count; ++i) free(records[i].name);
	free(records);
}

static int parse_metadata_blob(const uint8_t *blob, size_t blob_len, meta_record **out_records, size_t *out_count) {
	*out_records = NULL;
	*out_count = 0;
	if (blob_len < 12) return 0;
	if (memcmp(blob, meta_magic, 8) != 0) return 0;
	size_t off = 8;
	uint32_t count_u32 = read_u32_le(blob + off);
	off += 4;
	meta_record *records = (meta_record *)calloc((size_t)count_u32, sizeof(*records));
	if (count_u32 > 0 && records == NULL) return fail("out of memory");

	for (uint32_t i = 0; i < count_u32; ++i) {
		if (off + 4 > blob_len) {
			free_meta_records(records, i);
			return 0;
		}
		uint32_t name_len_u32 = read_u32_le(blob + off);
		off += 4;
		size_t name_len = (size_t)name_len_u32;
		if (off + name_len + 4 + 8 > blob_len) {
			free_meta_records(records, i);
			return 0;
		}
		records[i].name = (char *)malloc(name_len + 1);
		if (records[i].name == NULL) {
			free_meta_records(records, i);
			return fail("out of memory");
		}
		memcpy(records[i].name, blob + off, name_len);
		records[i].name[name_len] = '\0';
		off += name_len;
		records[i].mode_bits = read_u32_le(blob + off);
		off += 4;
		records[i].mtime_unix = read_i64_le(blob + off);
		off += 8;
	}

	*out_records = records;
	*out_count = (size_t)count_u32;
	return 0;
}

static int append_metadata_trailer(
	const uint8_t *archive,
	size_t archive_len,
	const uint8_t *meta_blob,
	size_t meta_blob_len,
	uint8_t **out_archive,
	size_t *out_len
) {
	*out_archive = NULL;
	*out_len = 0;
	const size_t footer_len = 8 + 4 + 4;
	size_t total_len = archive_len + meta_blob_len + footer_len;
	uint8_t *buf = (uint8_t *)malloc(total_len);
	if (buf == NULL) return fail("out of memory");

	size_t off = 0;
	memcpy(buf + off, archive, archive_len);
	off += archive_len;
	memcpy(buf + off, meta_blob, meta_blob_len);
	off += meta_blob_len;
	memcpy(buf + off, meta_trailer_magic, 8);
	off += 8;
	write_u32_le(buf + off, (uint32_t)meta_blob_len);
	off += 4;
	write_u32_le(buf + off, meta_trailer_version);
	off += 4;

	*out_archive = buf;
	*out_len = off;
	return 0;
}

static void split_archive_and_metadata(
	const uint8_t *archive,
	size_t archive_len,
	const uint8_t **base_archive,
	size_t *base_archive_len,
	const uint8_t **meta_blob,
	size_t *meta_blob_len
) {
	*base_archive = archive;
	*base_archive_len = archive_len;
	*meta_blob = NULL;
	*meta_blob_len = 0;

	const size_t footer_len = 8 + 4 + 4;
	if (archive_len < footer_len) return;
	size_t footer_at = archive_len - footer_len;
	if (memcmp(archive + footer_at, meta_trailer_magic, 8) != 0) return;

	uint32_t payload_len_u32 = read_u32_le(archive + footer_at + 8);
	uint32_t version_u32 = read_u32_le(archive + footer_at + 12);
	if (version_u32 != meta_trailer_version) return;

	size_t payload_len = (size_t)payload_len_u32;
	if (payload_len > footer_at) return;
	size_t payload_at = footer_at - payload_len;

	*base_archive_len = payload_at;
	*meta_blob = archive + payload_at;
	*meta_blob_len = payload_len;
}

static const meta_record *find_meta_record(const meta_record *records, size_t count, const uint8_t *name_ptr, size_t name_len) {
	for (size_t i = 0; i < count; ++i) {
		size_t rec_len = strlen(records[i].name);
		if (rec_len != name_len) continue;
		if (memcmp(records[i].name, name_ptr, name_len) == 0) return &records[i];
	}
	return NULL;
}

static void warn_metadata_restore(const char *path, const char *field) {
	fprintf(stderr, "warning: metadata restore skipped for %s (%s)\\n", path, field);
}

static void restore_metadata_for_path(const char *path, const meta_record *rec) {
#if defined(__APPLE__) || defined(__linux__)
	if (chmod(path, (mode_t)(rec->mode_bits & 07777u)) != 0) {
		warn_metadata_restore(path, "chmod");
	}
	struct utimbuf tb;
	tb.actime = (time_t)rec->mtime_unix;
	tb.modtime = (time_t)rec->mtime_unix;
	if (utime(path, &tb) != 0) {
		warn_metadata_restore(path, "utime");
	}
#else
	(void)rec;
	warn_metadata_restore(path, "unsupported platform");
#endif
}

static char *sidecar_path_for(const char *data_path) {
	const char *base = basename_ptr(data_path);
	size_t dir_len = (size_t)(base - data_path);
	if (dir_len == 0) {
		size_t total = 2 + strlen(base) + 1;
		char *out = (char *)malloc(total);
		if (out == NULL) return NULL;
		out[0] = '.';
		out[1] = '_';
		memcpy(out + 2, base, strlen(base) + 1);
		return out;
	}
	size_t base_len = strlen(base);
	char *out = (char *)malloc(dir_len + 2 + base_len + 1);
	if (out == NULL) return NULL;
	memcpy(out, data_path, dir_len);
	out[dir_len] = '.';
	out[dir_len + 1] = '_';
	memcpy(out + dir_len + 2, base, base_len + 1);
	return out;
}

#if defined(__APPLE__)
static char *namedfork_path_for(const char *data_path) {
	const char suffix[] = "/..namedfork/rsrc";
	size_t len = strlen(data_path);
	char *out = (char *)malloc(len + sizeof(suffix));
	if (out == NULL) return NULL;
	memcpy(out, data_path, len);
	memcpy(out + len, suffix, sizeof(suffix));
	return out;
}
#endif

static int selector_set_mode(selectors *s, rsrc_mode mode, const char *arg) {
	if (s->mode != RSRC_DEFAULT && s->mode != mode) return fail("resource selector conflict");
	s->mode = mode;
	if (mode == RSRC_EXPLICIT) s->rsrc_path = arg;
	if (mode == RSRC_XATTR) s->xattr_name = arg;
	return 0;
}

static int ensure_mode_supported(const selectors *s) {
	if (s->mode == RSRC_XATTR) {
#if defined(__linux__)
		return 0;
#else
		return fail("--xattr is only supported on Linux");
#endif
	}
	return 0;
}

static int read_linux_xattr_optional(const char *path, const char *name, uint8_t **out, size_t *out_len) {
	*out = NULL;
	*out_len = 0;
#if defined(__linux__)
	ssize_t need = getxattr(path, name, NULL, 0);
	if (need < 0) {
		if (errno == ENODATA || errno == ENOENT) return 0;
		fprintf(stderr, "error: getxattr failed for %s (%s): %s\n", path, name, strerror(errno));
		return 1;
	}
	if (need == 0) return 0;
	uint8_t *buf = (uint8_t *)malloc((size_t)need);
	if (buf == NULL) return fail("out of memory");
	ssize_t got = getxattr(path, name, buf, (size_t)need);
	if (got < 0) {
		fprintf(stderr, "error: getxattr read failed for %s (%s): %s\n", path, name, strerror(errno));
		free(buf);
		return 1;
	}
	*out = buf;
	*out_len = (size_t)got;
	return 0;
#else
	(void)path;
	(void)name;
	return fail("--xattr is only supported on Linux");
#endif
}

static int write_linux_xattr(const char *path, const char *name, const uint8_t *buf, size_t len) {
#if defined(__linux__)
	if (setxattr(path, name, buf, len, 0) != 0) {
		fprintf(stderr, "error: setxattr failed for %s (%s): %s\n", path, name, strerror(errno));
		return 1;
	}
	return 0;
#else
	(void)path;
	(void)name;
	(void)buf;
	(void)len;
	return fail("--xattr is only supported on Linux");
#endif
}

static int read_resource_for_input(const char *data_path, const selectors *s, uint8_t **out, size_t *out_len) {
	*out = NULL;
	*out_len = 0;
	if (s->mode == RSRC_EXPLICIT) {
		return read_file_optional(s->rsrc_path, out, out_len);
	}
	if (s->mode == RSRC_SIDECAR) {
		char *sidecar = sidecar_path_for(data_path);
		if (sidecar == NULL) return fail("out of memory");
		int rc = read_file_optional(sidecar, out, out_len);
		free(sidecar);
		return rc;
	}
	if (s->mode == RSRC_XATTR) {
		return read_linux_xattr_optional(data_path, s->xattr_name, out, out_len);
	}
#if defined(__APPLE__)
	char *named = namedfork_path_for(data_path);
	if (named == NULL) return fail("out of memory");
	int rc = read_file_optional(named, out, out_len);
	free(named);
	return rc;
#else
	return 0;
#endif
}

static int write_resource_for_output(const char *data_path, const selectors *s, const uint8_t *buf, size_t len) {
	if (len == 0) return 0;
	if (s->mode == RSRC_EXPLICIT) {
		return write_file(s->rsrc_path, buf, len);
	}
	if (s->mode == RSRC_SIDECAR) {
		char *sidecar = sidecar_path_for(data_path);
		if (sidecar == NULL) return fail("out of memory");
		int rc = write_file(sidecar, buf, len);
		free(sidecar);
		return rc;
	}
	if (s->mode == RSRC_XATTR) {
		return write_linux_xattr(data_path, s->xattr_name, buf, len);
	}
#if defined(__APPLE__)
	char *named = namedfork_path_for(data_path);
	if (named == NULL) return fail("out of memory");
	int rc = write_file(named, buf, len);
	free(named);
	return rc;
#else
	char *sidecar = sidecar_path_for(data_path);
	if (sidecar == NULL) return fail("out of memory");
	int rc = write_file(sidecar, buf, len);
	free(sidecar);
	return rc;
#endif
}

static int build_entries_from_inputs(const selectors *s, char **paths, size_t count, cp_entry_input **out_entries, input_owned **out_owned) {
	*out_entries = NULL;
	*out_owned = NULL;
	if (count == 0) return fail("no input files provided");

	cp_entry_input *entries = (cp_entry_input *)calloc(count, sizeof(*entries));
	input_owned *owned = (input_owned *)calloc(count, sizeof(*owned));
	if (entries == NULL || owned == NULL) {
		free(entries);
		free(owned);
		return fail("out of memory");
	}

	for (size_t i = 0; i < count; ++i) {
		if (read_file_required(paths[i], &owned[i].data, &owned[i].data_len) != 0) {
			for (size_t j = 0; j <= i; ++j) {
				free(owned[j].data);
				free(owned[j].resource);
			}
			free(owned);
			free(entries);
			return 1;
		}
		if (read_resource_for_input(paths[i], s, &owned[i].resource, &owned[i].resource_len) != 0) {
			for (size_t j = 0; j <= i; ++j) {
				free(owned[j].data);
				free(owned[j].resource);
			}
			free(owned);
			free(entries);
			return 1;
		}
		owned[i].archive_name = normalize_archive_name(paths[i]);
		if (owned[i].archive_name == NULL) {
			for (size_t j = 0; j <= i; ++j) {
				free(owned[j].data);
				free(owned[j].resource);
				free(owned[j].archive_name);
			}
			free(owned);
			free(entries);
			return fail("out of memory");
		}
		entries[i].name_ptr = (const uint8_t *)owned[i].archive_name;
		entries[i].name_len = strlen(owned[i].archive_name);
		entries[i].data_ptr = owned[i].data;
		entries[i].data_len = owned[i].data_len;
		entries[i].resource_ptr = owned[i].resource;
		entries[i].resource_len = owned[i].resource_len;

		struct stat st;
		if (stat(paths[i], &st) == 0) {
			owned[i].mode_bits = (uint32_t)(st.st_mode & 07777u);
			owned[i].mtime_unix = (int64_t)st.st_mtime;
		} else {
			owned[i].mode_bits = 0644u;
			owned[i].mtime_unix = 0;
		}
	}

	*out_entries = entries;
	*out_owned = owned;
	return 0;
}

static void free_built_entries(cp_entry_input *entries, input_owned *owned, size_t count) {
	(void)entries;
	if (owned != NULL) {
		for (size_t i = 0; i < count; ++i) {
			free(owned[i].data);
			free(owned[i].resource);
			free(owned[i].archive_name);
		}
		free(owned);
	}
	free(entries);
}

static int cmd_compress(int argc, char **argv) {
	selectors s = { .mode = RSRC_DEFAULT, .rsrc_path = NULL, .xattr_name = NULL };
	const char *output_path = NULL;
	char **inputs = (char **)calloc((size_t)argc, sizeof(char *));
	if (inputs == NULL) return fail("out of memory");
	size_t input_count = 0;

	for (int i = 2; i < argc; ++i) {
		if (strcmp(argv[i], "--sidecar") == 0) {
			if (selector_set_mode(&s, RSRC_SIDECAR, NULL) != 0) {
				free(inputs);
				return 1;
			}
		} else if (strcmp(argv[i], "--rsrc") == 0) {
			if (i + 1 >= argc) {
				free(inputs);
				return fail("--rsrc requires a path");
			}
			if (selector_set_mode(&s, RSRC_EXPLICIT, argv[++i]) != 0) {
				free(inputs);
				return 1;
			}
		} else if (strcmp(argv[i], "--xattr") == 0) {
			if (i + 1 >= argc) {
				free(inputs);
				return fail("--xattr requires a name");
			}
			if (selector_set_mode(&s, RSRC_XATTR, argv[++i]) != 0) {
				free(inputs);
				return 1;
			}
		} else if (strcmp(argv[i], "-o") == 0) {
			if (i + 1 >= argc) {
				free(inputs);
				return fail("-o requires output path");
			}
			output_path = argv[++i];
		} else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
			print_help();
			free(inputs);
			return 0;
		} else {
			inputs[input_count++] = argv[i];
		}
	}

	if (ensure_mode_supported(&s) != 0) {
		free(inputs);
		return 1;
	}
	if (output_path == NULL) {
		free(inputs);
		return fail("compress requires -o <archive>");
	}
	if (input_count == 0) {
		free(inputs);
		return fail("compress requires at least one input file");
	}
	if (s.mode == RSRC_EXPLICIT && input_count != 1) {
		free(inputs);
		return fail("--rsrc requires exactly one input file");
	}

	cp_entry_input *entries = NULL;
	input_owned *owned = NULL;
	if (build_entries_from_inputs(&s, inputs, input_count, &entries, &owned) != 0) {
		free(inputs);
		return 1;
	}

	meta_source *meta_sources = (meta_source *)calloc(input_count, sizeof(*meta_sources));
	if (meta_sources == NULL) {
		free_built_entries(entries, owned, input_count);
		free(inputs);
		return fail("out of memory");
	}
	for (size_t i = 0; i < input_count; ++i) {
		meta_sources[i].name_ptr = (const uint8_t *)owned[i].archive_name;
		meta_sources[i].name_len = strlen(owned[i].archive_name);
		meta_sources[i].mode_bits = owned[i].mode_bits;
		meta_sources[i].mtime_unix = owned[i].mtime_unix;
	}
	uint8_t *meta_blob = NULL;
	size_t meta_blob_len = 0;
	if (build_metadata_blob(meta_sources, input_count, &meta_blob, &meta_blob_len) != 0) {
		free(meta_sources);
		free_built_entries(entries, owned, input_count);
		free(inputs);
		return 1;
	}
	free(meta_sources);

	cp_buffer archive = {0};
	int rc = cp_archive_create(entries, input_count, NULL, 0, &archive);
	if (rc != CP_OK) {
		fprintf(stderr, "error: cp_archive_create failed: %s\n", cp_error_string(rc));
		free(meta_blob);
		free_built_entries(entries, owned, input_count);
		free(inputs);
		return 1;
	}

	uint8_t *archive_with_meta = NULL;
	size_t archive_with_meta_len = 0;
	if (append_metadata_trailer(archive.ptr, archive.len, meta_blob, meta_blob_len, &archive_with_meta, &archive_with_meta_len) != 0) {
		cp_buffer_free(&archive);
		free(meta_blob);
		free_built_entries(entries, owned, input_count);
		free(inputs);
		return 1;
	}

	int write_rc = write_file(output_path, archive_with_meta, archive_with_meta_len);
	cp_buffer_free(&archive);
	free(archive_with_meta);
	free(meta_blob);
	free_built_entries(entries, owned, input_count);
	free(inputs);
	return write_rc;
}

static bool is_safe_archive_name(const uint8_t *name_ptr, size_t name_len) {
	if (name_len == 0) return false;
	if (name_ptr[0] == '/') return false;
	for (size_t i = 0; i < name_len; ++i) {
		if (name_ptr[i] == '\0') return false;
		if (name_ptr[i] == '/' && i + 2 < name_len && name_ptr[i + 1] == '.' && name_ptr[i + 2] == '.') return false;
		if (name_ptr[i] == '.' && i + 1 < name_len && name_ptr[i + 1] == '/' && i == 0) return false;
	}
	return true;
}

static char *copy_name(const uint8_t *name_ptr, size_t name_len) {
	char *out = (char *)malloc(name_len + 1);
	if (out == NULL) return NULL;
	memcpy(out, name_ptr, name_len);
	out[name_len] = '\0';
	return out;
}

static bool matches_requested_path(const uint8_t *name_ptr, size_t name_len, const char *path) {
	size_t path_len = strlen(path);
	if (path_len != name_len) return false;
	return memcmp(name_ptr, path, name_len) == 0;
}

static int cmd_expand(int argc, char **argv) {
	selectors s = { .mode = RSRC_DEFAULT, .rsrc_path = NULL, .xattr_name = NULL };
	const char *archive_path = NULL;
	const char *out_dir = ".";
	char **paths = (char **)calloc((size_t)argc, sizeof(char *));
	bool *path_found = (bool *)calloc((size_t)argc, sizeof(bool));
	size_t path_count = 0;
	if (paths == NULL || path_found == NULL) {
		free(paths);
		free(path_found);
		return fail("out of memory");
	}

	for (int i = 2; i < argc; ++i) {
		if (strcmp(argv[i], "--sidecar") == 0) {
			if (selector_set_mode(&s, RSRC_SIDECAR, NULL) != 0) return 1;
		} else if (strcmp(argv[i], "--rsrc") == 0) {
			if (i + 1 >= argc) return fail("--rsrc requires a path");
			if (selector_set_mode(&s, RSRC_EXPLICIT, argv[++i]) != 0) return 1;
		} else if (strcmp(argv[i], "--xattr") == 0) {
			if (i + 1 >= argc) return fail("--xattr requires a name");
			if (selector_set_mode(&s, RSRC_XATTR, argv[++i]) != 0) return 1;
		} else if (strcmp(argv[i], "--path") == 0) {
			if (i + 1 >= argc) {
				free(paths);
				free(path_found);
				return fail("--path requires an archive entry path");
			}
			paths[path_count++] = argv[++i];
		} else if (strcmp(argv[i], "-d") == 0) {
			if (i + 1 >= argc) return fail("-d requires output directory");
			out_dir = argv[++i];
		} else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
			print_help();
			free(paths);
			free(path_found);
			return 0;
		} else {
			archive_path = argv[i];
		}
	}

	if (ensure_mode_supported(&s) != 0) {
		free(paths);
		free(path_found);
		return 1;
	}
	if (archive_path == NULL) {
		free(paths);
		free(path_found);
		return fail("expand requires archive path");
	}

	uint8_t *archive_bytes = NULL;
	size_t archive_len = 0;
	if (read_file_required(archive_path, &archive_bytes, &archive_len) != 0) {
		free(paths);
		free(path_found);
		return 1;
	}

	const uint8_t *base_archive = archive_bytes;
	size_t base_archive_len = archive_len;
	const uint8_t *meta_blob = NULL;
	size_t meta_blob_len = 0;
	split_archive_and_metadata(archive_bytes, archive_len, &base_archive, &base_archive_len, &meta_blob, &meta_blob_len);

	meta_record *meta_records = NULL;
	size_t meta_count = 0;
	if (meta_blob != NULL && parse_metadata_blob(meta_blob, meta_blob_len, &meta_records, &meta_count) != 0) {
		free(archive_bytes);
		free(paths);
		free(path_found);
		return 1;
	}

	cp_archive_output extracted = {0};
	int rc = cp_archive_extract(base_archive, base_archive_len, 1, &extracted);
	free(archive_bytes);
	if (rc != CP_OK) {
		fprintf(stderr, "error: cp_archive_extract failed: %s\n", cp_error_string(rc));
		free_meta_records(meta_records, meta_count);
		free(paths);
		free(path_found);
		return 1;
	}

	if (s.mode == RSRC_EXPLICIT && path_count > 1) {
		cp_archive_output_free(&extracted);
		free_meta_records(meta_records, meta_count);
		free(paths);
		free(path_found);
		return fail("--rsrc supports one output path target");
	}
	if (s.mode == RSRC_EXPLICIT && path_count == 0 && extracted.entry_count != 1) {
		cp_archive_output_free(&extracted);
		free_meta_records(meta_records, meta_count);
		free(paths);
		free(path_found);
		return fail("--rsrc requires archive with exactly one entry for expand");
	}

	for (size_t i = 0; i < extracted.entry_count; ++i) {
		cp_entry_output *entry = &extracted.entries_ptr[i];
		if (path_count > 0) {
			bool matched = false;
			for (size_t p = 0; p < path_count; ++p) {
				if (matches_requested_path(entry->name_ptr, entry->name_len, paths[p])) {
					path_found[p] = true;
					matched = true;
				}
			}
			if (!matched) continue;
		}
		if (!is_safe_archive_name(entry->name_ptr, entry->name_len)) {
			cp_archive_output_free(&extracted);
			free_meta_records(meta_records, meta_count);
			free(paths);
			free(path_found);
			return fail("unsafe entry name in archive");
		}
		char *name = copy_name(entry->name_ptr, entry->name_len);
		if (name == NULL) {
			cp_archive_output_free(&extracted);
			free_meta_records(meta_records, meta_count);
			free(paths);
			free(path_found);
			return fail("out of memory");
		}
		char *output_path = join_path(out_dir, name);
		free(name);
		if (output_path == NULL) {
			cp_archive_output_free(&extracted);
			free_meta_records(meta_records, meta_count);
			free(paths);
			free(path_found);
			return fail("out of memory");
		}
		if (write_file(output_path, entry->data_ptr, entry->data_len) != 0) {
			free(output_path);
			cp_archive_output_free(&extracted);
			free_meta_records(meta_records, meta_count);
			free(paths);
			free(path_found);
			return 1;
		}
		if (entry->resource_len > 0) {
			if (write_resource_for_output(output_path, &s, entry->resource_ptr, entry->resource_len) != 0) {
				free(output_path);
				cp_archive_output_free(&extracted);
				free_meta_records(meta_records, meta_count);
				free(paths);
				free(path_found);
				return 1;
			}
		}
		const meta_record *rec = find_meta_record(meta_records, meta_count, entry->name_ptr, entry->name_len);
		if (rec != NULL) restore_metadata_for_path(output_path, rec);
		free(output_path);
	}

	for (size_t i = 0; i < path_count; ++i) {
		if (!path_found[i]) {
			fprintf(stderr, "error: requested path not found in archive: %s\n", paths[i]);
			cp_archive_output_free(&extracted);
			free_meta_records(meta_records, meta_count);
			free(paths);
			free(path_found);
			return 1;
		}
	}

	cp_archive_output_free(&extracted);
	free_meta_records(meta_records, meta_count);
	free(paths);
	free(path_found);
	return 0;
}

static int cmd_add(int argc, char **argv) {
	selectors s = { .mode = RSRC_DEFAULT, .rsrc_path = NULL, .xattr_name = NULL };
	char **inputs = (char **)calloc((size_t)argc, sizeof(char *));
	if (inputs == NULL) return fail("out of memory");
	size_t input_count = 0;
	const char *archive_path = NULL;

	for (int i = 2; i < argc; ++i) {
		if (strcmp(argv[i], "--sidecar") == 0) {
			if (selector_set_mode(&s, RSRC_SIDECAR, NULL) != 0) {
				free(inputs);
				return 1;
			}
		} else if (strcmp(argv[i], "--rsrc") == 0) {
			if (i + 1 >= argc) {
				free(inputs);
				return fail("--rsrc requires a path");
			}
			if (selector_set_mode(&s, RSRC_EXPLICIT, argv[++i]) != 0) {
				free(inputs);
				return 1;
			}
		} else if (strcmp(argv[i], "--xattr") == 0) {
			if (i + 1 >= argc) {
				free(inputs);
				return fail("--xattr requires a name");
			}
			if (selector_set_mode(&s, RSRC_XATTR, argv[++i]) != 0) {
				free(inputs);
				return 1;
			}
		} else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
			print_help();
			free(inputs);
			return 0;
		} else if (archive_path == NULL) {
			archive_path = argv[i];
		} else {
			inputs[input_count++] = argv[i];
		}
	}

	if (ensure_mode_supported(&s) != 0) {
		free(inputs);
		return 1;
	}
	if (archive_path == NULL) {
		free(inputs);
		return fail("add requires archive path");
	}
	if (input_count == 0) {
		free(inputs);
		return fail("add requires at least one input file");
	}
	if (s.mode == RSRC_EXPLICIT && input_count != 1) {
		free(inputs);
		return fail("--rsrc requires exactly one input file");
	}

	uint8_t *archive_bytes = NULL;
	size_t archive_len = 0;
	if (read_file_required(archive_path, &archive_bytes, &archive_len) != 0) {
		free(inputs);
		return 1;
	}

	const uint8_t *base_archive = archive_bytes;
	size_t base_archive_len = archive_len;
	const uint8_t *meta_blob_in = NULL;
	size_t meta_blob_in_len = 0;
	split_archive_and_metadata(archive_bytes, archive_len, &base_archive, &base_archive_len, &meta_blob_in, &meta_blob_in_len);

	meta_record *old_meta = NULL;
	size_t old_meta_count = 0;
	if (meta_blob_in != NULL && parse_metadata_blob(meta_blob_in, meta_blob_in_len, &old_meta, &old_meta_count) != 0) {
		free(archive_bytes);
		free(inputs);
		return 1;
	}

	cp_entry_input *entries = NULL;
	input_owned *owned = NULL;
	if (build_entries_from_inputs(&s, inputs, input_count, &entries, &owned) != 0) {
		free(archive_bytes);
		free_meta_records(old_meta, old_meta_count);
		free(inputs);
		return 1;
	}

	cp_archive_output existing = {0};
	int rc = cp_archive_extract(base_archive, base_archive_len, 1, &existing);
	free(archive_bytes);
	if (rc != CP_OK) {
		fprintf(stderr, "error: cp_archive_extract failed: %s\n", cp_error_string(rc));
		free_meta_records(old_meta, old_meta_count);
		free_built_entries(entries, owned, input_count);
		free(inputs);
		return 1;
	}

	size_t combined_count = existing.entry_count + input_count;
	meta_source *sources = (meta_source *)calloc(combined_count, sizeof(*sources));
	cp_entry_input *combined = (cp_entry_input *)calloc(combined_count, sizeof(*combined));
	if (sources == NULL || combined == NULL) {
		free(sources);
		free(combined);
		free_meta_records(old_meta, old_meta_count);
		cp_archive_output_free(&existing);
		free_built_entries(entries, owned, input_count);
		free(inputs);
		return fail("out of memory");
	}

	size_t out_idx = 0;
	for (size_t i = 0; i < existing.entry_count; ++i) {
		cp_entry_output *entry = &existing.entries_ptr[i];
		combined[out_idx].name_ptr = entry->name_ptr;
		combined[out_idx].name_len = entry->name_len;
		combined[out_idx].data_ptr = entry->data_ptr;
		combined[out_idx].data_len = entry->data_len;
		combined[out_idx].resource_ptr = entry->resource_ptr;
		combined[out_idx].resource_len = entry->resource_len;
		combined[out_idx].file_type = entry->file_type;
		combined[out_idx].creator = entry->creator;
		combined[out_idx].created = entry->created;
		combined[out_idx].modified = entry->modified;
		combined[out_idx].finder_flags = entry->finder_flags;

		const meta_record *rec = find_meta_record(old_meta, old_meta_count, entry->name_ptr, entry->name_len);
		sources[out_idx].name_ptr = entry->name_ptr;
		sources[out_idx].name_len = entry->name_len;
		sources[out_idx].mode_bits = rec != NULL ? rec->mode_bits : 0644u;
		sources[out_idx].mtime_unix = rec != NULL ? rec->mtime_unix : 0;
		out_idx++;
	}

	for (size_t i = 0; i < input_count; ++i) {
		combined[out_idx] = entries[i];
		sources[out_idx].name_ptr = entries[i].name_ptr;
		sources[out_idx].name_len = entries[i].name_len;
		sources[out_idx].mode_bits = owned[i].mode_bits;
		sources[out_idx].mtime_unix = owned[i].mtime_unix;
		out_idx++;
	}

	uint8_t *meta_blob_out = NULL;
	size_t meta_blob_out_len = 0;
	if (build_metadata_blob(sources, combined_count, &meta_blob_out, &meta_blob_out_len) != 0) {
		free(sources);
		free(combined);
		free_meta_records(old_meta, old_meta_count);
		cp_archive_output_free(&existing);
		free_built_entries(entries, owned, input_count);
		free(inputs);
		return 1;
	}
	free(sources);

	cp_buffer out_archive = {0};
	rc = cp_archive_create(combined, combined_count, existing.comment_ptr, existing.comment_len, &out_archive);
	free(combined);
	free_meta_records(old_meta, old_meta_count);
	if (rc != CP_OK) {
		fprintf(stderr, "error: cp_archive_create failed: %s\n", cp_error_string(rc));
		free(meta_blob_out);
		cp_archive_output_free(&existing);
		free_built_entries(entries, owned, input_count);
		free(inputs);
		return 1;
	}

	uint8_t *archive_with_meta = NULL;
	size_t archive_with_meta_len = 0;
	if (append_metadata_trailer(out_archive.ptr, out_archive.len, meta_blob_out, meta_blob_out_len, &archive_with_meta, &archive_with_meta_len) != 0) {
		cp_buffer_free(&out_archive);
		free(meta_blob_out);
		cp_archive_output_free(&existing);
		free_built_entries(entries, owned, input_count);
		free(inputs);
		return 1;
	}

	int write_rc = write_file(archive_path, archive_with_meta, archive_with_meta_len);
	free(archive_with_meta);
	cp_buffer_free(&out_archive);
	free(meta_blob_out);
	cp_archive_output_free(&existing);
	free_built_entries(entries, owned, input_count);
	free(inputs);
	return write_rc;
}

static int cmd_list(int argc, char **argv) {
	const char *archive_path = NULL;
	for (int i = 2; i < argc; ++i) {
		if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
			print_help();
			return 0;
		}
		archive_path = argv[i];
	}
	if (archive_path == NULL) return fail("list requires archive path");

	uint8_t *archive_bytes = NULL;
	size_t archive_len = 0;
	if (read_file_required(archive_path, &archive_bytes, &archive_len) != 0) return 1;

	const uint8_t *base_archive = archive_bytes;
	size_t base_archive_len = archive_len;
	const uint8_t *meta_blob = NULL;
	size_t meta_blob_len = 0;
	split_archive_and_metadata(archive_bytes, archive_len, &base_archive, &base_archive_len, &meta_blob, &meta_blob_len);
	(void)meta_blob;
	(void)meta_blob_len;

	cp_archive_listing listing = {0};
	int rc = cp_archive_list(base_archive, base_archive_len, 1, &listing);
	free(archive_bytes);
	if (rc != CP_OK) {
		fprintf(stderr, "error: cp_archive_list failed: %s\n", cp_error_string(rc));
		return 1;
	}

	for (size_t i = 0; i < listing.entry_count; ++i) {
		cp_list_entry *entry = &listing.entries_ptr[i];
		char *name = copy_name(entry->name_ptr, entry->name_len);
		if (name == NULL) {
			cp_archive_listing_free(&listing);
			return fail("out of memory");
		}
		printf("%s\tdata=%u\trsrc=%u\tflags=0x%04x\n",
			name,
			(unsigned int)entry->data_uncompressed_len,
			(unsigned int)entry->resource_uncompressed_len,
			(unsigned int)entry->flags);
		free(name);
	}

	cp_archive_listing_free(&listing);
	return 0;
}

int compact_pro_cli_main(int argc, char **argv) {
	if (argc <= 1 || strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
		print_help();
		return 0;
	}
	if (strcmp(argv[1], "compress") == 0) return cmd_compress(argc, argv);
	if (strcmp(argv[1], "expand") == 0) return cmd_expand(argc, argv);
	if (strcmp(argv[1], "add") == 0) return cmd_add(argc, argv);
	if (strcmp(argv[1], "list") == 0) return cmd_list(argc, argv);
	return fail("unknown command (expected: compress, expand, add, list)");
}
