#if defined(__linux__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <utime.h>

#if !defined(_WIN32)
#include <dirent.h>
#include <pthread.h>
#endif

#if defined(__linux__)
#include <fcntl.h>
#include <unistd.h>
#include <sys/xattr.h>
#endif
#if defined(__APPLE__)
#include <fcntl.h>
#include <unistd.h>
#include <sys/xattr.h>
#endif
#if defined(_WIN32)
#include <direct.h>
#include <io.h>
#include <windows.h>
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
	char *source_path;
	uint32_t mode_bits;
	int64_t mtime_unix;
} input_owned;

typedef struct {
	char *source_path;
	char *archive_name;
} discovered_input;

typedef struct {
	bool has_mode;
	uint32_t mode_bits;
	bool has_uid;
	uint32_t uid;
	bool has_gid;
	uint32_t gid;
	bool has_atime;
	int64_t atime_unix;
	uint32_t atime_ns;
	bool has_mtime;
	int64_t mtime_unix;
	uint32_t mtime_ns;
	bool has_ctime;
	int64_t ctime_unix;
	uint32_t ctime_ns;
	bool has_birthtime;
	int64_t birthtime_unix;
	uint32_t birthtime_ns;
	bool has_flags;
	uint32_t flags;
	bool has_win_file_attrs;
	uint32_t win_file_attrs;
	bool has_win_creation_time;
	uint64_t win_creation_time_100ns;
	bool has_win_last_access_time;
	uint64_t win_last_access_time_100ns;
	bool has_win_last_write_time;
	uint64_t win_last_write_time_100ns;
} meta_attrs;

typedef enum {
	META_KIND_FILE = 1,
	META_KIND_DIR = 2,
} meta_kind;

typedef struct {
	char *path;
	uint8_t kind;
	meta_attrs attrs;
} meta_record;

typedef struct {
	uint32_t parent_index;
	uint8_t kind;
	char *name;
	meta_attrs attrs;
} meta_node;

typedef struct {
	char *archive_path;
	char *output_path;
	int depth;
} dir_restore_target;

enum {
	META_ATTR_MODE = 1u << 0,
	META_ATTR_UID = 1u << 1,
	META_ATTR_GID = 1u << 2,
	META_ATTR_ATIME = 1u << 3,
	META_ATTR_MTIME = 1u << 4,
	META_ATTR_CTIME = 1u << 5,
	META_ATTR_BIRTHTIME = 1u << 6,
	META_ATTR_FLAGS = 1u << 7,
	META_ATTR_WIN_FILE_ATTRS = 1u << 8,
	META_ATTR_WIN_CTIME = 1u << 9,
	META_ATTR_WIN_ATIME = 1u << 10,
	META_ATTR_WIN_MTIME = 1u << 11,
};

static const uint8_t meta_magic_v1[8] = { 'C', 'P', 'M', 'E', 'T', 'A', '1', '\n' };
static const uint8_t meta_magic_v2[8] = { 'C', 'P', 'M', 'E', 'T', 'A', '2', '\n' };
static const uint8_t meta_trailer_magic[8] = { 'C', 'P', 'X', 'T', 'R', 'L', 'R', '1' };
static const uint32_t meta_trailer_version = 1;
static const uint32_t meta_root_index = 0xFFFFFFFFu;

typedef struct {
	bool enabled;
	bool live;
	const char *label;
	size_t total;
	size_t done;
	double started_at;
	double last_emit_at;
} progress_state;

typedef struct {
	bool enabled;
	bool live;
	bool running;
	const char *label;
	double started_at;
	atomic_bool stop;
#if defined(_WIN32)
	HANDLE thread;
#else
	pthread_t thread;
#endif
} phase_heartbeat;

static void print_help(void) {
	puts("compact-pro");
	puts("");
	puts("Usage:");
	puts("  compact-pro compress [--sidecar|--rsrc <path>|--xattr <name>] [--progress|--no-progress] [--force|-f] [-o <archive.cpt|->] <file...|->");
	puts("  compact-pro expand [--sidecar|--rsrc <path>|--xattr <name>] [--progress|--no-progress] <archive.cpt> [-d <outdir>] [--path <entry> ...]");
	puts("  compact-pro add [--sidecar|--rsrc <path>|--xattr <name>] [--progress|--no-progress] <archive.cpt> <file...>");
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

static bool stderr_is_tty(void) {
#if defined(_WIN32)
	return _isatty(_fileno(stderr)) != 0;
#else
	return isatty(fileno(stderr)) != 0;
#endif
}

static double now_seconds(void) {
#if defined(TIME_UTC)
	struct timespec ts;
	if (timespec_get(&ts, TIME_UTC) == TIME_UTC) {
		return (double)ts.tv_sec + ((double)ts.tv_nsec / 1000000000.0);
	}
#endif
	return (double)time(NULL);
}

static double mb_per_second(size_t bytes, double elapsed_s) {
	if (elapsed_s <= 0.0) return 0.0;
	return ((double)bytes / 1000000.0) / elapsed_s;
}

#if defined(_WIN32)
static DWORD WINAPI phase_heartbeat_thread(LPVOID arg) {
	phase_heartbeat *h = (phase_heartbeat *)arg;
	while (!atomic_load_explicit(&h->stop, memory_order_relaxed)) {
		Sleep(250);
		if (atomic_load_explicit(&h->stop, memory_order_relaxed)) break;
		double elapsed = now_seconds() - h->started_at;
		if (elapsed < 0.0) elapsed = 0.0;
		fprintf(stderr, "\rprogress: %s elapsed=%.0fs", h->label, elapsed);
		fflush(stderr);
	}
	return 0;
}
#else
static void *phase_heartbeat_thread(void *arg) {
	phase_heartbeat *h = (phase_heartbeat *)arg;
	while (!atomic_load_explicit(&h->stop, memory_order_relaxed)) {
		struct timespec ts = { .tv_sec = 0, .tv_nsec = 250000000 };
		nanosleep(&ts, NULL);
		if (atomic_load_explicit(&h->stop, memory_order_relaxed)) break;
		double elapsed = now_seconds() - h->started_at;
		if (elapsed < 0.0) elapsed = 0.0;
		fprintf(stderr, "\rprogress: %s elapsed=%.0fs", h->label, elapsed);
		fflush(stderr);
	}
	return NULL;
}
#endif

static void phase_heartbeat_begin(phase_heartbeat *h, const char *label) {
	if (h == NULL || !h->enabled) return;
	h->label = label;
	h->started_at = now_seconds();
	h->running = false;
	atomic_store_explicit(&h->stop, false, memory_order_relaxed);
	if (h->live) {
		fprintf(stderr, "\rprogress: %s elapsed=0s", h->label);
		fflush(stderr);
#if defined(_WIN32)
		h->thread = CreateThread(NULL, 0, phase_heartbeat_thread, h, 0, NULL);
		h->running = (h->thread != NULL);
#else
		h->running = (pthread_create(&h->thread, NULL, phase_heartbeat_thread, h) == 0);
#endif
	} else {
		fprintf(stderr, "progress: %s elapsed=0s\n", h->label);
	}
}

static void phase_heartbeat_end(phase_heartbeat *h) {
	if (h == NULL || !h->enabled) return;
	if (h->running) {
		atomic_store_explicit(&h->stop, true, memory_order_relaxed);
#if defined(_WIN32)
		WaitForSingleObject(h->thread, INFINITE);
		CloseHandle(h->thread);
#else
		pthread_join(h->thread, NULL);
#endif
		h->running = false;
	}
	double elapsed = now_seconds() - h->started_at;
	if (elapsed < 0.0) elapsed = 0.0;
	if (h->live) {
		fprintf(stderr, "\rprogress: %s elapsed=%.0fs done\n", h->label, elapsed);
	} else {
		fprintf(stderr, "progress: %s elapsed=%.0fs done\n", h->label, elapsed);
	}
}

static void print_compress_stats(size_t input_bytes, size_t compressed_bytes, double elapsed_s) {
	double percent = 0.0;
	if (input_bytes > 0) {
		percent = ((double)compressed_bytes * 100.0) / (double)input_bytes;
	}
	fprintf(stderr,
		"stats: compress input=%zu compressed=%zu percent=%.2f%% throughput=%.2f MB/s elapsed=%.3fs\n",
		input_bytes,
		compressed_bytes,
		percent,
		mb_per_second(input_bytes, elapsed_s),
		elapsed_s);
}

static void print_expand_stats(size_t compressed_bytes, size_t expanded_bytes, double elapsed_s) {
	double ratio = 0.0;
	if (compressed_bytes > 0) {
		ratio = (double)expanded_bytes / (double)compressed_bytes;
	}
	fprintf(stderr,
		"stats: expand compressed=%zu -> expanded=%zu ratio=%.2fx throughput=%.2f MB/s elapsed=%.3fs\n",
		compressed_bytes,
		expanded_bytes,
		ratio,
		mb_per_second(expanded_bytes, elapsed_s),
		elapsed_s);
}

static void progress_begin(progress_state *p, const char *label, size_t total) {
	if (p == NULL || !p->enabled) return;
	p->label = label;
	p->total = total == 0 ? 1 : total;
	p->done = 0;
	p->started_at = now_seconds();
	p->last_emit_at = 0.0;
	if (!p->live) {
		fprintf(stderr, "progress: %s 0/%zu\n", p->label, p->total);
	}
}

static void render_progress_bar(char *out, size_t out_len, size_t done, size_t total) {
	const size_t width = 20;
	if (out_len < width + 1) return;
	if (total == 0) total = 1;
	if (done > total) done = total;
	size_t filled = (done * width) / total;
	if (filled > width) filled = width;
	for (size_t i = 0; i < width; ++i) out[i] = '-';
	if (filled >= width) {
		for (size_t i = 0; i < width; ++i) out[i] = '=';
	} else if (filled > 0) {
		for (size_t i = 0; i + 1 < filled; ++i) out[i] = '=';
		out[filled - 1] = '>';
	}
	out[width] = '\0';
}

static void progress_update(progress_state *p, size_t done) {
	if (p == NULL || !p->enabled) return;
	if (done > p->total) done = p->total;
	p->done = done;
	double now = now_seconds();
	double elapsed = now - p->started_at;
	if (elapsed < 0.0) elapsed = 0.0;
	double eta = -1.0;
	if (p->done > 0 && p->done < p->total && elapsed > 0.0) {
		double rate = (double)p->done / elapsed;
		if (rate > 0.0) eta = (double)(p->total - p->done) / rate;
	}
	double percent = (p->total == 0) ? 100.0 : ((double)p->done * 100.0) / (double)p->total;
	char bar[21];
	render_progress_bar(bar, sizeof(bar), p->done, p->total);

	if (p->live && p->done < p->total && (now - p->last_emit_at) < 0.1) return;
	p->last_emit_at = now;
	if (p->live) {
		if (eta >= 0.0) {
			fprintf(stderr, "\rprogress: %s [%s] %3.0f%% (%zu/%zu) (ETA: %.0fs) elapsed=%.0fs", p->label, bar, percent, p->done, p->total, eta, elapsed);
		} else {
			fprintf(stderr, "\rprogress: %s [%s] %3.0f%% (%zu/%zu) (ETA: --) elapsed=%.0fs", p->label, bar, percent, p->done, p->total, elapsed);
		}
		fflush(stderr);
	} else {
		if (eta >= 0.0) {
			fprintf(stderr, "progress: %s [%s] %3.0f%% (%zu/%zu) (ETA: %.0fs) elapsed=%.0fs\n", p->label, bar, percent, p->done, p->total, eta, elapsed);
		} else {
			fprintf(stderr, "progress: %s [%s] %3.0f%% (%zu/%zu) (ETA: --) elapsed=%.0fs\n", p->label, bar, percent, p->done, p->total, elapsed);
		}
	}
}

static void progress_end(progress_state *p) {
	if (p == NULL || !p->enabled) return;
	progress_update(p, p->total);
	if (p->live) fprintf(stderr, "\n");
}

static void archive_encode_progress_callback(void *ctx, size_t done, size_t total) {
	progress_state *p = (progress_state *)ctx;
	if (p == NULL) return;
	if (total == 0) total = 1;
	p->total = total;
	progress_update(p, done);
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

static char *expand_tilde_path(const char *path) {
	if (path == NULL) return NULL;
	if (path[0] != '~') return xstrdup(path);
	if (path[1] != '\0' && path[1] != '/' && path[1] != '\\') return xstrdup(path);

	const char *home = getenv("HOME");
#if defined(_WIN32)
	if (home == NULL || home[0] == '\0') home = getenv("USERPROFILE");
#endif
	if (home == NULL || home[0] == '\0') return xstrdup(path);

	size_t home_len = strlen(home);
	size_t rest_len = strlen(path + 1);
	char *out = (char *)malloc(home_len + rest_len + 1);
	if (out == NULL) return NULL;
	memcpy(out, home, home_len);
	memcpy(out + home_len, path + 1, rest_len + 1);
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

static int ensure_dir_exists(const char *path) {
	char *resolved = expand_tilde_path(path);
	if (resolved == NULL) return fail("out of memory");
	if (ensure_parent_dirs(resolved) != 0) {
		free(resolved);
		return 1;
	}
#if defined(_WIN32)
	if (_mkdir(resolved) != 0 && errno != EEXIST) {
#else
	if (mkdir(resolved, 0755) != 0 && errno != EEXIST) {
#endif
		fprintf(stderr, "error: mkdir failed for %s: %s\n", path, strerror(errno));
		free(resolved);
		return 1;
	}
	free(resolved);
	return 0;
}

static int read_file_optional(const char *path, uint8_t **out, size_t *out_len) {
	*out = NULL;
	*out_len = 0;
	char *resolved = expand_tilde_path(path);
	if (resolved == NULL) return fail("out of memory");

	if (strcmp(resolved, "-") == 0) {
		size_t cap = 0;
		size_t len = 0;
		uint8_t *buf = NULL;
		for (;;) {
			if (len == cap) {
				size_t next_cap = cap == 0 ? 8192 : cap * 2;
				uint8_t *next = (uint8_t *)realloc(buf, next_cap);
				if (next == NULL) {
					free(buf);
					free(resolved);
					return fail("out of memory");
				}
				buf = next;
				cap = next_cap;
			}
			size_t got = fread(buf + len, 1, cap - len, stdin);
			len += got;
			if (got == 0) {
				if (ferror(stdin)) {
					fprintf(stderr, "error: read failed for stdin\n");
					free(buf);
					free(resolved);
					return 1;
				}
				break;
			}
		}
		if (len == 0) {
			free(buf);
			buf = NULL;
		}
		*out = buf;
		*out_len = len;
		free(resolved);
		return 0;
	}

	FILE *f = fopen(resolved, "rb");
	if (f == NULL) {
		if (errno == ENOENT) {
			free(resolved);
			return 0;
		}
		fprintf(stderr, "error: open failed for %s: %s\n", path, strerror(errno));
		free(resolved);
		return 1;
	}

	if (fseek(f, 0, SEEK_END) != 0) {
		fprintf(stderr, "error: fseek failed for %s\n", path);
		fclose(f);
		free(resolved);
		return 1;
	}
	long size = ftell(f);
	if (size < 0) {
		fprintf(stderr, "error: ftell failed for %s\n", path);
		fclose(f);
		free(resolved);
		return 1;
	}
	if (fseek(f, 0, SEEK_SET) != 0) {
		fprintf(stderr, "error: fseek rewind failed for %s\n", path);
		fclose(f);
		free(resolved);
		return 1;
	}

	if (size == 0) {
		fclose(f);
		free(resolved);
		return 0;
	}

	uint8_t *buf = (uint8_t *)malloc((size_t)size);
	if (buf == NULL) {
		fclose(f);
		free(resolved);
		return fail("out of memory");
	}
	if (fread(buf, 1, (size_t)size, f) != (size_t)size) {
		fprintf(stderr, "error: read failed for %s\n", path);
		free(buf);
		fclose(f);
		free(resolved);
		return 1;
	}
	fclose(f);
	*out = buf;
	*out_len = (size_t)size;
	free(resolved);
	return 0;
}

static int read_file_required(const char *path, uint8_t **out, size_t *out_len) {
	if (read_file_optional(path, out, out_len) != 0) return 1;
	if (strcmp(path, "-") == 0) return 0;
	if (*out == NULL && *out_len == 0) {
		char *resolved = expand_tilde_path(path);
		if (resolved == NULL) return fail("out of memory");
		FILE *f = fopen(resolved, "rb");
		if (f == NULL) {
			fprintf(stderr, "error: file not found: %s\n", path);
			free(resolved);
			return 1;
		}
		fclose(f);
		free(resolved);
	}
	return 0;
}

static int write_file(const char *path, const uint8_t *data, size_t len) {
	char *resolved = expand_tilde_path(path);
	if (resolved == NULL) return fail("out of memory");

	if (strcmp(resolved, "-") == 0) {
		if (len > 0 && fwrite(data, 1, len, stdout) != len) {
			fprintf(stderr, "error: write failed for stdout\n");
			free(resolved);
			return 1;
		}
		if (fflush(stdout) != 0) {
			fprintf(stderr, "error: flush failed for stdout\n");
			free(resolved);
			return 1;
		}
		free(resolved);
		return 0;
	}

	if (ensure_parent_dirs(resolved) != 0) {
		free(resolved);
		return 1;
	}
	FILE *f = fopen(resolved, "wb");
	if (f == NULL) {
		fprintf(stderr, "error: open for write failed for %s: %s\n", path, strerror(errno));
		free(resolved);
		return 1;
	}
	if (len > 0 && fwrite(data, 1, len, f) != len) {
		fprintf(stderr, "error: write failed for %s\n", path);
		fclose(f);
		free(resolved);
		return 1;
	}
	if (fclose(f) != 0) {
		fprintf(stderr, "error: close failed for %s\n", path);
		free(resolved);
		return 1;
	}
	free(resolved);
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

static bool has_cpt_extension(const char *path) {
	size_t len = strlen(path);
	if (len < 4) return false;
	return strcmp(path + len - 4, ".cpt") == 0;
}

static char *append_cpt_extension(const char *path) {
	if (strcmp(path, "-") == 0) return xstrdup(path);
	if (has_cpt_extension(path)) return xstrdup(path);
	size_t len = strlen(path);
	char *out = (char *)malloc(len + 4 + 1);
	if (out == NULL) return NULL;
	memcpy(out, path, len);
	memcpy(out + len, ".cpt", 5);
	return out;
}

static char *default_output_archive_name(char **inputs, size_t input_count) {
	const char *base = "archive";
	if (input_count == 1) {
		base = strcmp(inputs[0], "-") == 0 ? "stdin" : basename_ptr(inputs[0]);
	} else {
		char cwd[4096];
#if defined(_WIN32)
		if (_getcwd(cwd, sizeof(cwd)) != NULL) base = basename_ptr(cwd);
#else
		if (getcwd(cwd, sizeof(cwd)) != NULL) base = basename_ptr(cwd);
#endif
	}
	char *tmp = (char *)malloc(strlen(base) + 1);
	if (tmp == NULL) return NULL;
	memcpy(tmp, base, strlen(base) + 1);
	char *out = append_cpt_extension(tmp);
	free(tmp);
	return out;
}

static bool path_exists(const char *path) {
	char *resolved = expand_tilde_path(path);
	if (resolved == NULL) return false;
	struct stat st;
	bool exists = (stat(resolved, &st) == 0);
	free(resolved);
	return exists;
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

static void write_u64_le(uint8_t *dst, uint64_t v) {
	for (size_t i = 0; i < 8; ++i) dst[i] = (uint8_t)((v >> (8 * i)) & 0xFFu);
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

static uint64_t read_u64_le(const uint8_t *src) {
	uint64_t u = 0;
	for (size_t i = 0; i < 8; ++i) u |= ((uint64_t)src[i]) << (8 * i);
	return u;
}

static void free_meta_records(meta_record *records, size_t count) {
	if (records == NULL) return;
	for (size_t i = 0; i < count; ++i) free(records[i].path);
	free(records);
}

static void free_meta_nodes(meta_node *nodes, size_t count) {
	if (nodes == NULL) return;
	for (size_t i = 0; i < count; ++i) free(nodes[i].name);
	free(nodes);
}

static meta_attrs default_file_metadata(void) {
	meta_attrs attrs;
	memset(&attrs, 0, sizeof(attrs));
	attrs.has_mode = true;
	attrs.mode_bits = 0644u;
	attrs.has_mtime = true;
	attrs.mtime_unix = 0;
	attrs.mtime_ns = 0;
	return attrs;
}

static uint32_t meta_attrs_mask(const meta_attrs *attrs) {
	uint32_t mask = 0;
	if (attrs->has_mode) mask |= META_ATTR_MODE;
	if (attrs->has_uid) mask |= META_ATTR_UID;
	if (attrs->has_gid) mask |= META_ATTR_GID;
	if (attrs->has_atime) mask |= META_ATTR_ATIME;
	if (attrs->has_mtime) mask |= META_ATTR_MTIME;
	if (attrs->has_ctime) mask |= META_ATTR_CTIME;
	if (attrs->has_birthtime) mask |= META_ATTR_BIRTHTIME;
	if (attrs->has_flags) mask |= META_ATTR_FLAGS;
	if (attrs->has_win_file_attrs) mask |= META_ATTR_WIN_FILE_ATTRS;
	if (attrs->has_win_creation_time) mask |= META_ATTR_WIN_CTIME;
	if (attrs->has_win_last_access_time) mask |= META_ATTR_WIN_ATIME;
	if (attrs->has_win_last_write_time) mask |= META_ATTR_WIN_MTIME;
	return mask;
}

static size_t meta_attrs_encoded_len(uint32_t mask) {
	size_t len = 0;
	if (mask & META_ATTR_MODE) len += 4;
	if (mask & META_ATTR_UID) len += 4;
	if (mask & META_ATTR_GID) len += 4;
	if (mask & META_ATTR_ATIME) len += 12;
	if (mask & META_ATTR_MTIME) len += 12;
	if (mask & META_ATTR_CTIME) len += 12;
	if (mask & META_ATTR_BIRTHTIME) len += 12;
	if (mask & META_ATTR_FLAGS) len += 4;
	if (mask & META_ATTR_WIN_FILE_ATTRS) len += 4;
	if (mask & META_ATTR_WIN_CTIME) len += 8;
	if (mask & META_ATTR_WIN_ATIME) len += 8;
	if (mask & META_ATTR_WIN_MTIME) len += 8;
	return len;
}

static void encode_meta_attrs(uint8_t *buf, size_t *off, const meta_attrs *attrs, uint32_t mask) {
	if (mask & META_ATTR_MODE) {
		write_u32_le(buf + *off, attrs->mode_bits);
		*off += 4;
	}
	if (mask & META_ATTR_UID) {
		write_u32_le(buf + *off, attrs->uid);
		*off += 4;
	}
	if (mask & META_ATTR_GID) {
		write_u32_le(buf + *off, attrs->gid);
		*off += 4;
	}
	if (mask & META_ATTR_ATIME) {
		write_i64_le(buf + *off, attrs->atime_unix);
		*off += 8;
		write_u32_le(buf + *off, attrs->atime_ns);
		*off += 4;
	}
	if (mask & META_ATTR_MTIME) {
		write_i64_le(buf + *off, attrs->mtime_unix);
		*off += 8;
		write_u32_le(buf + *off, attrs->mtime_ns);
		*off += 4;
	}
	if (mask & META_ATTR_CTIME) {
		write_i64_le(buf + *off, attrs->ctime_unix);
		*off += 8;
		write_u32_le(buf + *off, attrs->ctime_ns);
		*off += 4;
	}
	if (mask & META_ATTR_BIRTHTIME) {
		write_i64_le(buf + *off, attrs->birthtime_unix);
		*off += 8;
		write_u32_le(buf + *off, attrs->birthtime_ns);
		*off += 4;
	}
	if (mask & META_ATTR_FLAGS) {
		write_u32_le(buf + *off, attrs->flags);
		*off += 4;
	}
	if (mask & META_ATTR_WIN_FILE_ATTRS) {
		write_u32_le(buf + *off, attrs->win_file_attrs);
		*off += 4;
	}
	if (mask & META_ATTR_WIN_CTIME) {
		write_u64_le(buf + *off, attrs->win_creation_time_100ns);
		*off += 8;
	}
	if (mask & META_ATTR_WIN_ATIME) {
		write_u64_le(buf + *off, attrs->win_last_access_time_100ns);
		*off += 8;
	}
	if (mask & META_ATTR_WIN_MTIME) {
		write_u64_le(buf + *off, attrs->win_last_write_time_100ns);
		*off += 8;
	}
}

static bool decode_meta_attrs(const uint8_t *blob, size_t blob_len, size_t *off, uint32_t mask, meta_attrs *out) {
	memset(out, 0, sizeof(*out));
	if ((mask & META_ATTR_MODE) && *off + 4 > blob_len) return false;
	if (mask & META_ATTR_MODE) {
		out->has_mode = true;
		out->mode_bits = read_u32_le(blob + *off);
		*off += 4;
	}
	if ((mask & META_ATTR_UID) && *off + 4 > blob_len) return false;
	if (mask & META_ATTR_UID) {
		out->has_uid = true;
		out->uid = read_u32_le(blob + *off);
		*off += 4;
	}
	if ((mask & META_ATTR_GID) && *off + 4 > blob_len) return false;
	if (mask & META_ATTR_GID) {
		out->has_gid = true;
		out->gid = read_u32_le(blob + *off);
		*off += 4;
	}
	if ((mask & META_ATTR_ATIME) && *off + 12 > blob_len) return false;
	if (mask & META_ATTR_ATIME) {
		out->has_atime = true;
		out->atime_unix = read_i64_le(blob + *off);
		*off += 8;
		out->atime_ns = read_u32_le(blob + *off);
		*off += 4;
	}
	if ((mask & META_ATTR_MTIME) && *off + 12 > blob_len) return false;
	if (mask & META_ATTR_MTIME) {
		out->has_mtime = true;
		out->mtime_unix = read_i64_le(blob + *off);
		*off += 8;
		out->mtime_ns = read_u32_le(blob + *off);
		*off += 4;
	}
	if ((mask & META_ATTR_CTIME) && *off + 12 > blob_len) return false;
	if (mask & META_ATTR_CTIME) {
		out->has_ctime = true;
		out->ctime_unix = read_i64_le(blob + *off);
		*off += 8;
		out->ctime_ns = read_u32_le(blob + *off);
		*off += 4;
	}
	if ((mask & META_ATTR_BIRTHTIME) && *off + 12 > blob_len) return false;
	if (mask & META_ATTR_BIRTHTIME) {
		out->has_birthtime = true;
		out->birthtime_unix = read_i64_le(blob + *off);
		*off += 8;
		out->birthtime_ns = read_u32_le(blob + *off);
		*off += 4;
	}
	if ((mask & META_ATTR_FLAGS) && *off + 4 > blob_len) return false;
	if (mask & META_ATTR_FLAGS) {
		out->has_flags = true;
		out->flags = read_u32_le(blob + *off);
		*off += 4;
	}
	if ((mask & META_ATTR_WIN_FILE_ATTRS) && *off + 4 > blob_len) return false;
	if (mask & META_ATTR_WIN_FILE_ATTRS) {
		out->has_win_file_attrs = true;
		out->win_file_attrs = read_u32_le(blob + *off);
		*off += 4;
	}
	if ((mask & META_ATTR_WIN_CTIME) && *off + 8 > blob_len) return false;
	if (mask & META_ATTR_WIN_CTIME) {
		out->has_win_creation_time = true;
		out->win_creation_time_100ns = read_u64_le(blob + *off);
		*off += 8;
	}
	if ((mask & META_ATTR_WIN_ATIME) && *off + 8 > blob_len) return false;
	if (mask & META_ATTR_WIN_ATIME) {
		out->has_win_last_access_time = true;
		out->win_last_access_time_100ns = read_u64_le(blob + *off);
		*off += 8;
	}
	if ((mask & META_ATTR_WIN_MTIME) && *off + 8 > blob_len) return false;
	if (mask & META_ATTR_WIN_MTIME) {
		out->has_win_last_write_time = true;
		out->win_last_write_time_100ns = read_u64_le(blob + *off);
		*off += 8;
	}
	return true;
}

static bool path_component_next(const char *path, size_t *off, const char **comp_ptr, size_t *comp_len, bool *is_last) {
	size_t n = strlen(path);
	size_t i = *off;
	while (i < n && path[i] == '/') i++;
	if (i >= n) return false;
	size_t start = i;
	while (i < n && path[i] != '/') i++;
	*comp_ptr = path + start;
	*comp_len = i - start;
	while (i < n && path[i] == '/') i++;
	*is_last = (i >= n);
	*off = i;
	return true;
}

static bool meta_record_path_eq_bytes(const meta_record *rec, const uint8_t *path_ptr, size_t path_len, uint8_t kind) {
	if (rec->kind != kind) return false;
	size_t rec_len = strlen(rec->path);
	if (rec_len != path_len) return false;
	return memcmp(rec->path, path_ptr, path_len) == 0;
}

static bool meta_record_path_eq_cstr(const meta_record *rec, const char *path, uint8_t kind) {
	if (rec->kind != kind) return false;
	return strcmp(rec->path, path) == 0;
}

static const meta_record *find_meta_record_by_bytes(const meta_record *records, size_t count, const uint8_t *path_ptr, size_t path_len, uint8_t kind) {
	for (size_t i = 0; i < count; ++i) {
		if (meta_record_path_eq_bytes(&records[i], path_ptr, path_len, kind)) return &records[i];
	}
	return NULL;
}

static const meta_record *find_meta_record_by_cstr(const meta_record *records, size_t count, const char *path, uint8_t kind) {
	for (size_t i = 0; i < count; ++i) {
		if (meta_record_path_eq_cstr(&records[i], path, kind)) return &records[i];
	}
	return NULL;
}

static int upsert_meta_record(meta_record **records, size_t *count, const char *path, uint8_t kind, const meta_attrs *attrs, bool overwrite_attrs) {
	for (size_t i = 0; i < *count; ++i) {
		if ((*records)[i].kind != kind) continue;
		if (strcmp((*records)[i].path, path) != 0) continue;
		if (overwrite_attrs && attrs != NULL) (*records)[i].attrs = *attrs;
		return 0;
	}

	meta_record *next = (meta_record *)realloc(*records, (*count + 1) * sizeof(**records));
	if (next == NULL) return fail("out of memory");
	*records = next;
	meta_record *rec = &(*records)[*count];
	rec->path = xstrdup(path);
	if (rec->path == NULL) return fail("out of memory");
	rec->kind = kind;
	memset(&rec->attrs, 0, sizeof(rec->attrs));
	if (attrs != NULL) rec->attrs = *attrs;
	(*count)++;
	return 0;
}

static bool path_to_parent_in_place(char *path) {
	size_t len = strlen(path);
	if (len == 0) return false;
	while (len > 1 && path[len - 1] == '/') len--;
	while (len > 1 && path[len - 1] != '/') len--;
	if (len == 1 && path[0] == '/') {
		path[1] = '\0';
		return false;
	}
	while (len > 1 && path[len - 1] == '/') len--;
	path[len] = '\0';
	return len > 0;
}

static bool capture_metadata_for_path(const char *path, meta_attrs *out_attrs) {
	memset(out_attrs, 0, sizeof(*out_attrs));
	struct stat st;
	if (stat(path, &st) != 0) return false;

	out_attrs->has_mode = true;
	out_attrs->mode_bits = (uint32_t)(st.st_mode & 07777u);

#if defined(__APPLE__) || defined(__linux__)
	out_attrs->has_uid = true;
	out_attrs->uid = (uint32_t)st.st_uid;
	out_attrs->has_gid = true;
	out_attrs->gid = (uint32_t)st.st_gid;
#endif

#if defined(__APPLE__)
	out_attrs->has_atime = true;
	out_attrs->atime_unix = (int64_t)st.st_atimespec.tv_sec;
	out_attrs->atime_ns = (uint32_t)st.st_atimespec.tv_nsec;
	out_attrs->has_mtime = true;
	out_attrs->mtime_unix = (int64_t)st.st_mtimespec.tv_sec;
	out_attrs->mtime_ns = (uint32_t)st.st_mtimespec.tv_nsec;
	out_attrs->has_ctime = true;
	out_attrs->ctime_unix = (int64_t)st.st_ctimespec.tv_sec;
	out_attrs->ctime_ns = (uint32_t)st.st_ctimespec.tv_nsec;
	out_attrs->has_birthtime = true;
	out_attrs->birthtime_unix = (int64_t)st.st_birthtimespec.tv_sec;
	out_attrs->birthtime_ns = (uint32_t)st.st_birthtimespec.tv_nsec;
	out_attrs->has_flags = true;
	out_attrs->flags = (uint32_t)st.st_flags;
#elif defined(__linux__)
	out_attrs->has_atime = true;
	out_attrs->atime_unix = (int64_t)st.st_atim.tv_sec;
	out_attrs->atime_ns = (uint32_t)st.st_atim.tv_nsec;
	out_attrs->has_mtime = true;
	out_attrs->mtime_unix = (int64_t)st.st_mtim.tv_sec;
	out_attrs->mtime_ns = (uint32_t)st.st_mtim.tv_nsec;
	out_attrs->has_ctime = true;
	out_attrs->ctime_unix = (int64_t)st.st_ctim.tv_sec;
	out_attrs->ctime_ns = (uint32_t)st.st_ctim.tv_nsec;
#else
	out_attrs->has_atime = true;
	out_attrs->atime_unix = (int64_t)st.st_atime;
	out_attrs->atime_ns = 0;
	out_attrs->has_mtime = true;
	out_attrs->mtime_unix = (int64_t)st.st_mtime;
	out_attrs->mtime_ns = 0;
	out_attrs->has_ctime = true;
	out_attrs->ctime_unix = (int64_t)st.st_ctime;
	out_attrs->ctime_ns = 0;
#endif

#if defined(_WIN32)
	WIN32_FILE_ATTRIBUTE_DATA fad;
	if (GetFileAttributesExA(path, GetFileExInfoStandard, &fad) != 0) {
		ULARGE_INTEGER q;
		out_attrs->has_win_file_attrs = true;
		out_attrs->win_file_attrs = fad.dwFileAttributes;
		out_attrs->has_win_creation_time = true;
		q.LowPart = fad.ftCreationTime.dwLowDateTime;
		q.HighPart = fad.ftCreationTime.dwHighDateTime;
		out_attrs->win_creation_time_100ns = q.QuadPart;
		out_attrs->has_win_last_access_time = true;
		q.LowPart = fad.ftLastAccessTime.dwLowDateTime;
		q.HighPart = fad.ftLastAccessTime.dwHighDateTime;
		out_attrs->win_last_access_time_100ns = q.QuadPart;
		out_attrs->has_win_last_write_time = true;
		q.LowPart = fad.ftLastWriteTime.dwLowDateTime;
		q.HighPart = fad.ftLastWriteTime.dwHighDateTime;
		out_attrs->win_last_write_time_100ns = q.QuadPart;
	}
#endif
	return true;
}

static int collect_metadata_for_input(meta_record **records, size_t *count, const char *source_path, const char *archive_path) {
	meta_attrs file_attrs;
	if (!capture_metadata_for_path(source_path, &file_attrs)) file_attrs = default_file_metadata();
	if (upsert_meta_record(records, count, archive_path, META_KIND_FILE, &file_attrs, true) != 0) return 1;

	size_t slash_count = 0;
	for (const char *p = archive_path; *p != '\0'; ++p) {
		if (*p == '/') slash_count++;
	}
	if (slash_count == 0) return 0;

	char *src_cursor = xstrdup(source_path);
	if (src_cursor == NULL) return fail("out of memory");
	if (!path_to_parent_in_place(src_cursor)) {
		free(src_cursor);
		return 0;
	}

	for (ssize_t i = (ssize_t)strlen(archive_path) - 1; i >= 0; --i) {
		if (archive_path[(size_t)i] != '/') continue;
		if (i == 0) continue;

		size_t prefix_len = (size_t)i;
		char *prefix = (char *)malloc(prefix_len + 1);
		if (prefix == NULL) {
			free(src_cursor);
			return fail("out of memory");
		}
		memcpy(prefix, archive_path, prefix_len);
		prefix[prefix_len] = '\0';

		meta_attrs dir_attrs;
		bool got = capture_metadata_for_path(src_cursor, &dir_attrs);
		int rc = upsert_meta_record(records, count, prefix, META_KIND_DIR, got ? &dir_attrs : NULL, got);
		free(prefix);
		if (rc != 0) {
			free(src_cursor);
			return rc;
		}
		if (!path_to_parent_in_place(src_cursor)) break;
	}

	free(src_cursor);
	return 0;
}

static int meta_node_upsert(meta_node **nodes, size_t *count, uint32_t parent_index, uint8_t kind, const char *name_ptr, size_t name_len, const meta_attrs *attrs, bool overwrite_attrs, uint32_t *out_index) {
	for (size_t i = 0; i < *count; ++i) {
		if ((*nodes)[i].parent_index != parent_index) continue;
		if ((*nodes)[i].kind != kind) continue;
		if (strlen((*nodes)[i].name) != name_len) continue;
		if (memcmp((*nodes)[i].name, name_ptr, name_len) != 0) continue;
		if (overwrite_attrs && attrs != NULL) (*nodes)[i].attrs = *attrs;
		if (out_index != NULL) *out_index = (uint32_t)i;
		return 0;
	}

	meta_node *next = (meta_node *)realloc(*nodes, (*count + 1) * sizeof(**nodes));
	if (next == NULL) return fail("out of memory");
	*nodes = next;
	meta_node *node = &(*nodes)[*count];
	node->parent_index = parent_index;
	node->kind = kind;
	node->name = (char *)malloc(name_len + 1);
	if (node->name == NULL) return fail("out of memory");
	memcpy(node->name, name_ptr, name_len);
	node->name[name_len] = '\0';
	memset(&node->attrs, 0, sizeof(node->attrs));
	if (attrs != NULL) node->attrs = *attrs;
	if (out_index != NULL) *out_index = (uint32_t)(*count);
	(*count)++;
	return 0;
}

static int build_metadata_nodes_from_records(const meta_record *records, size_t record_count, meta_node **out_nodes, size_t *out_count) {
	*out_nodes = NULL;
	*out_count = 0;
	for (size_t r = 0; r < record_count; ++r) {
		const meta_record *rec = &records[r];
		uint32_t parent = meta_root_index;
		size_t off = 0;
		const char *comp_ptr = NULL;
		size_t comp_len = 0;
		bool is_last = false;
		while (path_component_next(rec->path, &off, &comp_ptr, &comp_len, &is_last)) {
			uint8_t kind = is_last ? rec->kind : META_KIND_DIR;
			const meta_attrs *attrs = is_last ? &rec->attrs : NULL;
			bool overwrite_attrs = is_last;
			uint32_t idx = meta_root_index;
			if (meta_node_upsert(out_nodes, out_count, parent, kind, comp_ptr, comp_len, attrs, overwrite_attrs, &idx) != 0) {
				free_meta_nodes(*out_nodes, *out_count);
				*out_nodes = NULL;
				*out_count = 0;
				return 1;
			}
			parent = idx;
		}
	}
	return 0;
}

static int build_metadata_blob(const meta_record *records, size_t count, uint8_t **out_blob, size_t *out_len) {
	*out_blob = NULL;
	*out_len = 0;

	meta_node *nodes = NULL;
	size_t node_count = 0;
	if (build_metadata_nodes_from_records(records, count, &nodes, &node_count) != 0) return 1;

	size_t total = 8 + 4;
	for (size_t i = 0; i < node_count; ++i) {
		uint32_t mask = meta_attrs_mask(&nodes[i].attrs);
		total += 4 + 1 + 4 + strlen(nodes[i].name) + 4 + meta_attrs_encoded_len(mask);
	}

	uint8_t *buf = (uint8_t *)malloc(total);
	if (buf == NULL) {
		free_meta_nodes(nodes, node_count);
		return fail("out of memory");
	}

	size_t off = 0;
	memcpy(buf + off, meta_magic_v2, 8);
	off += 8;
	write_u32_le(buf + off, (uint32_t)node_count);
	off += 4;
	for (size_t i = 0; i < node_count; ++i) {
		uint32_t mask = meta_attrs_mask(&nodes[i].attrs);
		size_t name_len = strlen(nodes[i].name);
		write_u32_le(buf + off, nodes[i].parent_index);
		off += 4;
		buf[off++] = nodes[i].kind;
		write_u32_le(buf + off, (uint32_t)name_len);
		off += 4;
		memcpy(buf + off, nodes[i].name, name_len);
		off += name_len;
		write_u32_le(buf + off, mask);
		off += 4;
		encode_meta_attrs(buf, &off, &nodes[i].attrs, mask);
	}

	free_meta_nodes(nodes, node_count);
	*out_blob = buf;
	*out_len = off;
	return 0;
}

static int parse_metadata_blob_v1(const uint8_t *blob, size_t blob_len, meta_record **out_records, size_t *out_count) {
	*out_records = NULL;
	*out_count = 0;
	if (blob_len < 12) return 0;
	if (memcmp(blob, meta_magic_v1, 8) != 0) return 0;
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
		records[i].path = (char *)malloc(name_len + 1);
		if (records[i].path == NULL) {
			free_meta_records(records, i);
			return fail("out of memory");
		}
		memcpy(records[i].path, blob + off, name_len);
		records[i].path[name_len] = '\0';
		off += name_len;
		records[i].kind = META_KIND_FILE;
		memset(&records[i].attrs, 0, sizeof(records[i].attrs));
		records[i].attrs.has_mode = true;
		records[i].attrs.mode_bits = read_u32_le(blob + off);
		off += 4;
		records[i].attrs.has_mtime = true;
		records[i].attrs.mtime_unix = read_i64_le(blob + off);
		records[i].attrs.mtime_ns = 0;
		off += 8;
	}

	*out_records = records;
	*out_count = (size_t)count_u32;
	return 0;
}

static int parse_metadata_blob_v2(const uint8_t *blob, size_t blob_len, meta_record **out_records, size_t *out_count) {
	*out_records = NULL;
	*out_count = 0;
	if (blob_len < 12) return 0;
	if (memcmp(blob, meta_magic_v2, 8) != 0) return 0;

	size_t off = 8;
	uint32_t count_u32 = read_u32_le(blob + off);
	off += 4;
	size_t count = (size_t)count_u32;
	meta_node *nodes = (meta_node *)calloc(count, sizeof(*nodes));
	char **full_paths = (char **)calloc(count, sizeof(*full_paths));
	meta_record *records = (meta_record *)calloc(count, sizeof(*records));
	if ((count > 0) && (nodes == NULL || full_paths == NULL || records == NULL)) {
		free(nodes);
		free(full_paths);
		free(records);
		return fail("out of memory");
	}

	for (size_t i = 0; i < count; ++i) {
		if (off + 4 + 1 + 4 > blob_len) {
			free_meta_nodes(nodes, i);
			for (size_t k = 0; k < count; ++k) free(full_paths[k]);
			free(full_paths);
			free_meta_records(records, i);
			return 0;
		}
		nodes[i].parent_index = read_u32_le(blob + off);
		off += 4;
		nodes[i].kind = blob[off++];
		uint32_t name_len_u32 = read_u32_le(blob + off);
		off += 4;
		size_t name_len = (size_t)name_len_u32;
		if (off + name_len + 4 > blob_len) {
			free_meta_nodes(nodes, i);
			for (size_t k = 0; k < count; ++k) free(full_paths[k]);
			free(full_paths);
			free_meta_records(records, i);
			return 0;
		}
		nodes[i].name = (char *)malloc(name_len + 1);
		if (nodes[i].name == NULL) {
			free_meta_nodes(nodes, i);
			for (size_t k = 0; k < count; ++k) free(full_paths[k]);
			free(full_paths);
			free_meta_records(records, i);
			return fail("out of memory");
		}
		memcpy(nodes[i].name, blob + off, name_len);
		nodes[i].name[name_len] = '\0';
		off += name_len;
		uint32_t mask = read_u32_le(blob + off);
		off += 4;
		if (!decode_meta_attrs(blob, blob_len, &off, mask, &nodes[i].attrs)) {
			free_meta_nodes(nodes, i + 1);
			for (size_t k = 0; k < count; ++k) free(full_paths[k]);
			free(full_paths);
			free_meta_records(records, i);
			return 0;
		}
		if (nodes[i].kind != META_KIND_FILE && nodes[i].kind != META_KIND_DIR) {
			free_meta_nodes(nodes, i + 1);
			for (size_t k = 0; k < count; ++k) free(full_paths[k]);
			free(full_paths);
			free_meta_records(records, i);
			return 0;
		}
		if (nodes[i].parent_index != meta_root_index && nodes[i].parent_index >= i) {
			free_meta_nodes(nodes, i + 1);
			for (size_t k = 0; k < count; ++k) free(full_paths[k]);
			free(full_paths);
			free_meta_records(records, i);
			return 0;
		}
	}

	for (size_t i = 0; i < count; ++i) {
		if (nodes[i].parent_index == meta_root_index) {
			full_paths[i] = xstrdup(nodes[i].name);
		} else {
			full_paths[i] = join_path(full_paths[nodes[i].parent_index], nodes[i].name);
		}
		if (full_paths[i] == NULL) {
			free_meta_nodes(nodes, count);
			for (size_t k = 0; k < count; ++k) free(full_paths[k]);
			free(full_paths);
			free_meta_records(records, i);
			return fail("out of memory");
		}
		records[i].path = full_paths[i];
		records[i].kind = nodes[i].kind;
		records[i].attrs = nodes[i].attrs;
	}

	free_meta_nodes(nodes, count);
	free(full_paths);
	*out_records = records;
	*out_count = count;
	return 0;
}

static int parse_metadata_blob(const uint8_t *blob, size_t blob_len, meta_record **out_records, size_t *out_count) {
	if (parse_metadata_blob_v2(blob, blob_len, out_records, out_count) != 0) return 1;
	if (*out_records != NULL || *out_count != 0) return 0;
	return parse_metadata_blob_v1(blob, blob_len, out_records, out_count);
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
	size_t *meta_blob_len,
	size_t *trailer_total_len
) {
	*base_archive = archive;
	*base_archive_len = archive_len;
	*meta_blob = NULL;
	*meta_blob_len = 0;
	if (trailer_total_len != NULL) *trailer_total_len = 0;

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
	if (trailer_total_len != NULL) *trailer_total_len = payload_len + footer_len;
}

static int path_depth(const char *path) {
	int depth = 0;
	for (const char *p = path; *p != '\0'; ++p) {
		if (*p == '/') depth++;
	}
	return depth + 1;
}

static void warn_metadata_restore(const char *path, const char *field) {
	fprintf(stderr, "warning: metadata restore skipped for %s (%s)\n", path, field);
}

static int append_dir_restore_target(const char *archive_path, const char *out_dir, dir_restore_target **targets, size_t *count) {
	for (size_t i = 0; i < *count; ++i) {
		if (strcmp((*targets)[i].archive_path, archive_path) == 0) return 0;
	}
	dir_restore_target *next = (dir_restore_target *)realloc(*targets, (*count + 1) * sizeof(**targets));
	if (next == NULL) return fail("out of memory");
	*targets = next;
	(*targets)[*count].archive_path = xstrdup(archive_path);
	if ((*targets)[*count].archive_path == NULL) return fail("out of memory");
	(*targets)[*count].output_path = join_path(out_dir, archive_path);
	if ((*targets)[*count].output_path == NULL) {
		free((*targets)[*count].archive_path);
		return fail("out of memory");
	}
	(*targets)[*count].depth = path_depth(archive_path);
	(*count)++;
	return 0;
}

static int add_dir_restore_targets_for_entry(const char *archive_path, const char *out_dir, dir_restore_target **targets, size_t *count) {
	size_t len = strlen(archive_path);
	for (size_t i = 0; i < len; ++i) {
		if (archive_path[i] != '/') continue;
		if (i == 0) continue;
		char *prefix = (char *)malloc(i + 1);
		if (prefix == NULL) return fail("out of memory");
		memcpy(prefix, archive_path, i);
		prefix[i] = '\0';
		int rc = append_dir_restore_target(prefix, out_dir, targets, count);
		free(prefix);
		if (rc != 0) return rc;
	}
	return 0;
}

static void free_dir_restore_targets(dir_restore_target *targets, size_t count) {
	if (targets == NULL) return;
	for (size_t i = 0; i < count; ++i) {
		free(targets[i].archive_path);
		free(targets[i].output_path);
	}
	free(targets);
}

static int compare_dir_restore_targets_desc(const void *lhs, const void *rhs) {
	const dir_restore_target *a = (const dir_restore_target *)lhs;
	const dir_restore_target *b = (const dir_restore_target *)rhs;
	if (a->depth == b->depth) return strcmp(b->archive_path, a->archive_path);
	return b->depth - a->depth;
}

#if defined(_WIN32)
static FILETIME filetime_from_u64(uint64_t v) {
	FILETIME ft;
	ft.dwLowDateTime = (DWORD)(v & 0xFFFFFFFFu);
	ft.dwHighDateTime = (DWORD)(v >> 32);
	return ft;
}
#endif

static void restore_metadata_for_path(const char *path, const meta_record *rec) {
#if defined(__APPLE__) || defined(__linux__) || defined(_WIN32)
	if (rec->attrs.has_mode) {
		if (chmod(path, (mode_t)(rec->attrs.mode_bits & 07777u)) != 0) warn_metadata_restore(path, "mode");
	}

#if defined(__APPLE__) || defined(__linux__)
	if (rec->attrs.has_uid || rec->attrs.has_gid) {
		uid_t uid = rec->attrs.has_uid ? (uid_t)rec->attrs.uid : (uid_t)-1;
		gid_t gid = rec->attrs.has_gid ? (gid_t)rec->attrs.gid : (gid_t)-1;
		if (chown(path, uid, gid) != 0) warn_metadata_restore(path, "uid/gid");
	}
#else
	if (rec->attrs.has_uid) warn_metadata_restore(path, "uid");
	if (rec->attrs.has_gid) warn_metadata_restore(path, "gid");
#endif

	if (rec->attrs.has_atime || rec->attrs.has_mtime) {
		struct utimbuf tb;
		time_t at = rec->attrs.has_atime ? (time_t)rec->attrs.atime_unix : (time_t)rec->attrs.mtime_unix;
		time_t mt = rec->attrs.has_mtime ? (time_t)rec->attrs.mtime_unix : at;
		tb.actime = at;
		tb.modtime = mt;
		if (utime(path, &tb) != 0) warn_metadata_restore(path, "atime/mtime");
	}

	if (rec->attrs.has_ctime) warn_metadata_restore(path, "ctime");
	if (rec->attrs.has_birthtime) warn_metadata_restore(path, "birthtime");

#if defined(__APPLE__)
	if (rec->attrs.has_flags) {
		if (chflags(path, rec->attrs.flags) != 0) warn_metadata_restore(path, "apple flags");
	}
#else
	if (rec->attrs.has_flags) warn_metadata_restore(path, "apple flags");
#endif

#if defined(_WIN32)
	if (rec->attrs.has_win_file_attrs) {
		if (SetFileAttributesA(path, rec->attrs.win_file_attrs) == 0) warn_metadata_restore(path, "ntfs file attributes");
	}
	if (rec->attrs.has_win_creation_time || rec->attrs.has_win_last_access_time || rec->attrs.has_win_last_write_time) {
		HANDLE h = CreateFileA(path, FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
		if (h == INVALID_HANDLE_VALUE) {
			warn_metadata_restore(path, "ntfs timestamps");
		} else {
			FILETIME ftc;
			FILETIME fta;
			FILETIME ftm;
			FILETIME *pftc = NULL;
			FILETIME *pfta = NULL;
			FILETIME *pftm = NULL;
			if (rec->attrs.has_win_creation_time) {
				ftc = filetime_from_u64(rec->attrs.win_creation_time_100ns);
				pftc = &ftc;
			}
			if (rec->attrs.has_win_last_access_time) {
				fta = filetime_from_u64(rec->attrs.win_last_access_time_100ns);
				pfta = &fta;
			}
			if (rec->attrs.has_win_last_write_time) {
				ftm = filetime_from_u64(rec->attrs.win_last_write_time_100ns);
				pftm = &ftm;
			}
			if (SetFileTime(h, pftc, pfta, pftm) == 0) warn_metadata_restore(path, "ntfs timestamps");
			CloseHandle(h);
		}
	}
#else
	if (rec->attrs.has_win_file_attrs) warn_metadata_restore(path, "ntfs file attributes");
	if (rec->attrs.has_win_creation_time) warn_metadata_restore(path, "ntfs creation time");
	if (rec->attrs.has_win_last_access_time) warn_metadata_restore(path, "ntfs access time");
	if (rec->attrs.has_win_last_write_time) warn_metadata_restore(path, "ntfs write time");
#endif
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

#if defined(__APPLE__)
static int read_macos_resource_fork_optional(const char *path, uint8_t **out, size_t *out_len) {
	*out = NULL;
	*out_len = 0;

	errno = 0;
	ssize_t need = getxattr(path, "com.apple.ResourceFork", NULL, 0, 0, 0);
	if (need < 0) {
		if (errno == ENOATTR || errno == ENODATA || errno == ENOTSUP) return 0;
		fprintf(stderr, "error: getxattr failed for %s (com.apple.ResourceFork): %s\n", path, strerror(errno));
		return 1;
	}
	if (need == 0) return 0;

	uint8_t *buf = (uint8_t *)malloc((size_t)need);
	if (buf == NULL) return fail("out of memory");
	ssize_t got = getxattr(path, "com.apple.ResourceFork", buf, (size_t)need, 0, 0);
	if (got < 0) {
		fprintf(stderr, "error: getxattr read failed for %s (com.apple.ResourceFork): %s\n", path, strerror(errno));
		free(buf);
		return 1;
	}
	*out = buf;
	*out_len = (size_t)got;
	return 0;
}
#endif

static int read_resource_for_input(const char *data_path, const selectors *s, uint8_t **out, size_t *out_len) {
	*out = NULL;
	*out_len = 0;
	if (strcmp(data_path, "-") == 0) return 0;
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
	return read_macos_resource_fork_optional(data_path, out, out_len);
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

static void free_discovered_inputs(discovered_input *items, size_t count) {
	if (items == NULL) return;
	for (size_t i = 0; i < count; ++i) {
		free(items[i].source_path);
		free(items[i].archive_name);
	}
	free(items);
}

static int append_discovered_input(discovered_input **items, size_t *count, const char *source_path, const char *archive_name) {
	discovered_input *next = (discovered_input *)realloc(*items, (*count + 1) * sizeof(**items));
	if (next == NULL) return fail("out of memory");
	*items = next;
	(*items)[*count].source_path = xstrdup(source_path);
	(*items)[*count].archive_name = xstrdup(archive_name);
	if ((*items)[*count].source_path == NULL || (*items)[*count].archive_name == NULL) return fail("out of memory");
	(*count)++;
	return 0;
}

static int cmp_string_ptr(const void *lhs, const void *rhs) {
	const char *const *a = (const char *const *)lhs;
	const char *const *b = (const char *const *)rhs;
	return strcmp(*a, *b);
}

static int collect_discovered_from_directory(const char *fs_dir, const char *archive_dir, discovered_input **items, size_t *count);

#if defined(_WIN32)
static int collect_discovered_from_directory_windows(const char *fs_dir, const char *archive_dir, discovered_input **items, size_t *count) {
	size_t dir_len = strlen(fs_dir);
	bool needs_sep = dir_len > 0 && fs_dir[dir_len - 1] != '/' && fs_dir[dir_len - 1] != '\\';
	char *pattern = (char *)malloc(dir_len + (needs_sep ? 1 : 0) + 1 + 1);
	if (pattern == NULL) return fail("out of memory");
	memcpy(pattern, fs_dir, dir_len);
	size_t idx = dir_len;
	if (needs_sep) pattern[idx++] = '\\';
	pattern[idx++] = '*';
	pattern[idx] = '\0';

	WIN32_FIND_DATAA find_data;
	HANDLE h = FindFirstFileA(pattern, &find_data);
	free(pattern);
	if (h == INVALID_HANDLE_VALUE) {
		fprintf(stderr, "error: list failed for %s\n", fs_dir);
		return 1;
	}

	char **names = NULL;
	size_t name_count = 0;
	do {
		const char *name = find_data.cFileName;
		if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
		char **next_names = (char **)realloc(names, (name_count + 1) * sizeof(*names));
		if (next_names == NULL) {
			for (size_t i = 0; i < name_count; ++i) free(names[i]);
			free(names);
			FindClose(h);
			return fail("out of memory");
		}
		names = next_names;
		names[name_count] = xstrdup(name);
		if (names[name_count] == NULL) {
			for (size_t i = 0; i < name_count; ++i) free(names[i]);
			free(names);
			FindClose(h);
			return fail("out of memory");
		}
		name_count++;
	} while (FindNextFileA(h, &find_data) != 0);
	DWORD find_err = GetLastError();
	FindClose(h);
	if (find_err != ERROR_NO_MORE_FILES) {
		for (size_t i = 0; i < name_count; ++i) free(names[i]);
		free(names);
		fprintf(stderr, "error: list failed for %s\n", fs_dir);
		return 1;
	}

	qsort(names, name_count, sizeof(*names), cmp_string_ptr);
	for (size_t i = 0; i < name_count; ++i) {
		char *fs_child = join_path(fs_dir, names[i]);
		char *archive_child = join_path(archive_dir, names[i]);
		if (fs_child == NULL || archive_child == NULL) {
			free(fs_child);
			free(archive_child);
			for (size_t j = i; j < name_count; ++j) free(names[j]);
			free(names);
			return fail("out of memory");
		}

		DWORD attrs = GetFileAttributesA(fs_child);
		if (attrs == INVALID_FILE_ATTRIBUTES) {
			fprintf(stderr, "error: stat failed for %s\n", fs_child);
			free(fs_child);
			free(archive_child);
			for (size_t j = i; j < name_count; ++j) free(names[j]);
			free(names);
			return 1;
		}
		int rc = 0;
		if ((attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
			rc = collect_discovered_from_directory(fs_child, archive_child, items, count);
		} else {
			rc = append_discovered_input(items, count, fs_child, archive_child);
		}
		free(fs_child);
		free(archive_child);
		free(names[i]);
		if (rc != 0) {
			for (size_t j = i + 1; j < name_count; ++j) free(names[j]);
			free(names);
			return rc;
		}
	}
	free(names);
	return 0;
}
#else
static int collect_discovered_from_directory_posix(const char *fs_dir, const char *archive_dir, discovered_input **items, size_t *count) {
	DIR *dir = opendir(fs_dir);
	if (dir == NULL) {
		fprintf(stderr, "error: open directory failed for %s: %s\n", fs_dir, strerror(errno));
		return 1;
	}

	char **names = NULL;
	size_t name_count = 0;
	for (;;) {
		struct dirent *entry = readdir(dir);
		if (entry == NULL) break;
		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
		char **next_names = (char **)realloc(names, (name_count + 1) * sizeof(*names));
		if (next_names == NULL) {
			for (size_t i = 0; i < name_count; ++i) free(names[i]);
			free(names);
			closedir(dir);
			return fail("out of memory");
		}
		names = next_names;
		names[name_count] = xstrdup(entry->d_name);
		if (names[name_count] == NULL) {
			for (size_t i = 0; i < name_count; ++i) free(names[i]);
			free(names);
			closedir(dir);
			return fail("out of memory");
		}
		name_count++;
	}
	closedir(dir);

	qsort(names, name_count, sizeof(*names), cmp_string_ptr);
	for (size_t i = 0; i < name_count; ++i) {
		char *fs_child = join_path(fs_dir, names[i]);
		char *archive_child = join_path(archive_dir, names[i]);
		if (fs_child == NULL || archive_child == NULL) {
			free(fs_child);
			free(archive_child);
			for (size_t j = i; j < name_count; ++j) free(names[j]);
			free(names);
			return fail("out of memory");
		}

		struct stat st;
		if (stat(fs_child, &st) != 0) {
			fprintf(stderr, "error: stat failed for %s: %s\n", fs_child, strerror(errno));
			free(fs_child);
			free(archive_child);
			for (size_t j = i; j < name_count; ++j) free(names[j]);
			free(names);
			return 1;
		}

		int rc = 0;
		if (S_ISDIR(st.st_mode)) {
			rc = collect_discovered_from_directory(fs_child, archive_child, items, count);
		} else if (S_ISREG(st.st_mode)) {
			rc = append_discovered_input(items, count, fs_child, archive_child);
		} else {
			fprintf(stderr, "error: unsupported input type: %s\n", fs_child);
			rc = 1;
		}
		free(fs_child);
		free(archive_child);
		free(names[i]);
		if (rc != 0) {
			for (size_t j = i + 1; j < name_count; ++j) free(names[j]);
			free(names);
			return rc;
		}
	}
	free(names);
	return 0;
}
#endif

static int collect_discovered_from_directory(const char *fs_dir, const char *archive_dir, discovered_input **items, size_t *count) {
#if defined(_WIN32)
	return collect_discovered_from_directory_windows(fs_dir, archive_dir, items, count);
#else
	return collect_discovered_from_directory_posix(fs_dir, archive_dir, items, count);
#endif
}

static int collect_directory_metadata_recursive(meta_record **records, size_t *count, const char *fs_dir, const char *archive_dir);

#if defined(_WIN32)
static int collect_directory_metadata_recursive_windows(meta_record **records, size_t *count, const char *fs_dir, const char *archive_dir) {
	meta_attrs attrs;
	if (!capture_metadata_for_path(fs_dir, &attrs)) attrs = default_file_metadata();
	if (upsert_meta_record(records, count, archive_dir, META_KIND_DIR, &attrs, true) != 0) return 1;

	size_t dir_len = strlen(fs_dir);
	bool needs_sep = dir_len > 0 && fs_dir[dir_len - 1] != '/' && fs_dir[dir_len - 1] != '\\';
	char *pattern = (char *)malloc(dir_len + (needs_sep ? 1 : 0) + 1 + 1);
	if (pattern == NULL) return fail("out of memory");
	memcpy(pattern, fs_dir, dir_len);
	size_t idx = dir_len;
	if (needs_sep) pattern[idx++] = '\\';
	pattern[idx++] = '*';
	pattern[idx] = '\0';

	WIN32_FIND_DATAA find_data;
	HANDLE h = FindFirstFileA(pattern, &find_data);
	free(pattern);
	if (h == INVALID_HANDLE_VALUE) {
		fprintf(stderr, "error: list failed for %s\n", fs_dir);
		return 1;
	}

	char **names = NULL;
	size_t name_count = 0;
	do {
		const char *name = find_data.cFileName;
		if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
		char **next_names = (char **)realloc(names, (name_count + 1) * sizeof(*names));
		if (next_names == NULL) {
			for (size_t i = 0; i < name_count; ++i) free(names[i]);
			free(names);
			FindClose(h);
			return fail("out of memory");
		}
		names = next_names;
		names[name_count] = xstrdup(name);
		if (names[name_count] == NULL) {
			for (size_t i = 0; i < name_count; ++i) free(names[i]);
			free(names);
			FindClose(h);
			return fail("out of memory");
		}
		name_count++;
	} while (FindNextFileA(h, &find_data) != 0);
	DWORD find_err = GetLastError();
	FindClose(h);
	if (find_err != ERROR_NO_MORE_FILES) {
		for (size_t i = 0; i < name_count; ++i) free(names[i]);
		free(names);
		fprintf(stderr, "error: list failed for %s\n", fs_dir);
		return 1;
	}

	qsort(names, name_count, sizeof(*names), cmp_string_ptr);
	for (size_t i = 0; i < name_count; ++i) {
		char *fs_child = join_path(fs_dir, names[i]);
		char *archive_child = join_path(archive_dir, names[i]);
		if (fs_child == NULL || archive_child == NULL) {
			free(fs_child);
			free(archive_child);
			for (size_t j = i; j < name_count; ++j) free(names[j]);
			free(names);
			return fail("out of memory");
		}
		DWORD child_attrs = GetFileAttributesA(fs_child);
		if (child_attrs == INVALID_FILE_ATTRIBUTES) {
			fprintf(stderr, "error: stat failed for %s\n", fs_child);
			free(fs_child);
			free(archive_child);
			for (size_t j = i; j < name_count; ++j) free(names[j]);
			free(names);
			return 1;
		}
		int rc = 0;
		if ((child_attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
			rc = collect_directory_metadata_recursive(records, count, fs_child, archive_child);
		}
		free(fs_child);
		free(archive_child);
		free(names[i]);
		if (rc != 0) {
			for (size_t j = i + 1; j < name_count; ++j) free(names[j]);
			free(names);
			return rc;
		}
	}
	free(names);
	return 0;
}
#else
static int collect_directory_metadata_recursive_posix(meta_record **records, size_t *count, const char *fs_dir, const char *archive_dir) {
	meta_attrs attrs;
	if (!capture_metadata_for_path(fs_dir, &attrs)) attrs = default_file_metadata();
	if (upsert_meta_record(records, count, archive_dir, META_KIND_DIR, &attrs, true) != 0) return 1;

	DIR *dir = opendir(fs_dir);
	if (dir == NULL) {
		fprintf(stderr, "error: open directory failed for %s: %s\n", fs_dir, strerror(errno));
		return 1;
	}

	char **names = NULL;
	size_t name_count = 0;
	for (;;) {
		struct dirent *entry = readdir(dir);
		if (entry == NULL) break;
		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
		char **next_names = (char **)realloc(names, (name_count + 1) * sizeof(*names));
		if (next_names == NULL) {
			for (size_t i = 0; i < name_count; ++i) free(names[i]);
			free(names);
			closedir(dir);
			return fail("out of memory");
		}
		names = next_names;
		names[name_count] = xstrdup(entry->d_name);
		if (names[name_count] == NULL) {
			for (size_t i = 0; i < name_count; ++i) free(names[i]);
			free(names);
			closedir(dir);
			return fail("out of memory");
		}
		name_count++;
	}
	closedir(dir);

	qsort(names, name_count, sizeof(*names), cmp_string_ptr);
	for (size_t i = 0; i < name_count; ++i) {
		char *fs_child = join_path(fs_dir, names[i]);
		char *archive_child = join_path(archive_dir, names[i]);
		if (fs_child == NULL || archive_child == NULL) {
			free(fs_child);
			free(archive_child);
			for (size_t j = i; j < name_count; ++j) free(names[j]);
			free(names);
			return fail("out of memory");
		}

		struct stat st;
		if (stat(fs_child, &st) != 0) {
			fprintf(stderr, "error: stat failed for %s: %s\n", fs_child, strerror(errno));
			free(fs_child);
			free(archive_child);
			for (size_t j = i; j < name_count; ++j) free(names[j]);
			free(names);
			return 1;
		}
		int rc = 0;
		if (S_ISDIR(st.st_mode)) {
			rc = collect_directory_metadata_recursive(records, count, fs_child, archive_child);
		}
		free(fs_child);
		free(archive_child);
		free(names[i]);
		if (rc != 0) {
			for (size_t j = i + 1; j < name_count; ++j) free(names[j]);
			free(names);
			return rc;
		}
	}
	free(names);
	return 0;
}
#endif

static int collect_directory_metadata_recursive(meta_record **records, size_t *count, const char *fs_dir, const char *archive_dir) {
#if defined(_WIN32)
	return collect_directory_metadata_recursive_windows(records, count, fs_dir, archive_dir);
#else
	return collect_directory_metadata_recursive_posix(records, count, fs_dir, archive_dir);
#endif
}

static int collect_directory_metadata_for_inputs(meta_record **records, size_t *count, char **paths, size_t path_count) {
	for (size_t i = 0; i < path_count; ++i) {
		char *resolved = expand_tilde_path(paths[i]);
		if (resolved == NULL) return fail("out of memory");
		if (strcmp(resolved, "-") == 0) {
			free(resolved);
			continue;
		}
		struct stat st;
		if (stat(resolved, &st) != 0) {
			free(resolved);
			continue;
		}
		if (!S_ISDIR(st.st_mode)) {
			free(resolved);
			continue;
		}
		char *archive_root = normalize_archive_name(resolved);
		if (archive_root == NULL) {
			free(resolved);
			return fail("out of memory");
		}
		int rc = collect_directory_metadata_recursive(records, count, resolved, archive_root);
		free(archive_root);
		free(resolved);
		if (rc != 0) return rc;
	}
	return 0;
}

static int discover_inputs(char **paths, size_t path_count, discovered_input **out_items, size_t *out_count) {
	*out_items = NULL;
	*out_count = 0;
	if (path_count == 0) return fail("no input files provided");

	for (size_t i = 0; i < path_count; ++i) {
		char *resolved = expand_tilde_path(paths[i]);
		if (resolved == NULL) {
			free_discovered_inputs(*out_items, *out_count);
			*out_items = NULL;
			*out_count = 0;
			return fail("out of memory");
		}
		if (strcmp(resolved, "-") == 0) {
			if (append_discovered_input(out_items, out_count, "-", "-") != 0) {
				free(resolved);
				free_discovered_inputs(*out_items, *out_count);
				*out_items = NULL;
				*out_count = 0;
				return 1;
			}
			free(resolved);
			continue;
		}

		struct stat st;
		if (stat(resolved, &st) != 0) {
			fprintf(stderr, "error: file not found: %s\n", resolved);
			free(resolved);
			free_discovered_inputs(*out_items, *out_count);
			*out_items = NULL;
			*out_count = 0;
			return 1;
		}

		if (S_ISDIR(st.st_mode)) {
			char *archive_root = normalize_archive_name(resolved);
			if (archive_root == NULL) {
				free(resolved);
				free_discovered_inputs(*out_items, *out_count);
				*out_items = NULL;
				*out_count = 0;
				return fail("out of memory");
			}
			int rc = collect_discovered_from_directory(resolved, archive_root, out_items, out_count);
			free(archive_root);
			free(resolved);
			if (rc != 0) {
				free_discovered_inputs(*out_items, *out_count);
				*out_items = NULL;
				*out_count = 0;
				return 1;
			}
			continue;
		}
		if (!S_ISREG(st.st_mode)) {
			fprintf(stderr, "error: unsupported input type: %s\n", resolved);
			free(resolved);
			free_discovered_inputs(*out_items, *out_count);
			*out_items = NULL;
			*out_count = 0;
			return 1;
		}

		char *archive_name = normalize_archive_name(resolved);
		if (archive_name == NULL) {
			free(resolved);
			free_discovered_inputs(*out_items, *out_count);
			*out_items = NULL;
			*out_count = 0;
			return fail("out of memory");
		}
		int rc = append_discovered_input(out_items, out_count, resolved, archive_name);
		free(archive_name);
		free(resolved);
		if (rc != 0) {
			free_discovered_inputs(*out_items, *out_count);
			*out_items = NULL;
			*out_count = 0;
			return 1;
		}
	}

	return 0;
}

static void free_owned_partial(input_owned *owned, size_t count) {
	if (owned == NULL) return;
	for (size_t i = 0; i < count; ++i) {
		free(owned[i].data);
		free(owned[i].resource);
		free(owned[i].archive_name);
		free(owned[i].source_path);
	}
}

static int build_entries_from_inputs(
	const selectors *s,
	char **paths,
	size_t count,
	cp_entry_input **out_entries,
	input_owned **out_owned,
	size_t *out_count,
	progress_state *progress
) {
	*out_entries = NULL;
	*out_owned = NULL;
	*out_count = 0;
	discovered_input *discovered = NULL;
	size_t discovered_count = 0;
	if (discover_inputs(paths, count, &discovered, &discovered_count) != 0) return 1;

	cp_entry_input *entries = (cp_entry_input *)calloc(discovered_count, sizeof(*entries));
	input_owned *owned = (input_owned *)calloc(discovered_count, sizeof(*owned));
	if ((discovered_count > 0) && (entries == NULL || owned == NULL)) {
		free(entries);
		free(owned);
		free_discovered_inputs(discovered, discovered_count);
		return fail("out of memory");
	}

	if (progress != NULL && progress->enabled) {
		size_t estimated_total = 0;
		for (size_t i = 0; i < discovered_count; ++i) {
			if (strcmp(discovered[i].source_path, "-") == 0) continue;
			struct stat st_est;
			if (stat(discovered[i].source_path, &st_est) == 0 && S_ISREG(st_est.st_mode) && st_est.st_size > 0) {
				estimated_total += (size_t)st_est.st_size;
			}
		}
		progress->total = estimated_total == 0 ? (discovered_count == 0 ? 1 : discovered_count) : estimated_total;
	}

	size_t bytes_done = 0;
	bool byte_mode = (progress != NULL && progress->enabled && progress->total > discovered_count);
	for (size_t i = 0; i < discovered_count; ++i) {
		if (read_file_required(discovered[i].source_path, &owned[i].data, &owned[i].data_len) != 0) {
			free_discovered_inputs(discovered, discovered_count);
			free_owned_partial(owned, discovered_count);
			free(owned);
			free(entries);
			return 1;
		}
		if (read_resource_for_input(discovered[i].source_path, s, &owned[i].resource, &owned[i].resource_len) != 0) {
			free_discovered_inputs(discovered, discovered_count);
			free_owned_partial(owned, discovered_count);
			free(owned);
			free(entries);
			return 1;
		}
		owned[i].source_path = xstrdup(discovered[i].source_path);
		owned[i].archive_name = xstrdup(discovered[i].archive_name);
		if (owned[i].source_path == NULL || owned[i].archive_name == NULL) {
			free_discovered_inputs(discovered, discovered_count);
			free_owned_partial(owned, discovered_count);
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
		if (stat(discovered[i].source_path, &st) == 0) {
			owned[i].mode_bits = (uint32_t)(st.st_mode & 07777u);
			owned[i].mtime_unix = (int64_t)st.st_mtime;
		} else {
			owned[i].mode_bits = 0644u;
			owned[i].mtime_unix = 0;
		}
		if (byte_mode) {
			bytes_done += owned[i].data_len + owned[i].resource_len;
			progress_update(progress, bytes_done);
		} else {
			progress_update(progress, i + 1);
		}
	}

	free_discovered_inputs(discovered, discovered_count);
	*out_entries = entries;
	*out_owned = owned;
	*out_count = discovered_count;
	return 0;
}

static void free_built_entries(cp_entry_input *entries, input_owned *owned, size_t count) {
	(void)entries;
	if (owned != NULL) {
			for (size_t i = 0; i < count; ++i) {
				free(owned[i].data);
				free(owned[i].resource);
				free(owned[i].archive_name);
				free(owned[i].source_path);
			}
		free(owned);
	}
	free(entries);
}

static int cmd_compress(int argc, char **argv) {
	selectors s = { .mode = RSRC_DEFAULT, .rsrc_path = NULL, .xattr_name = NULL };
	const char *output_arg = NULL;
	char *output_path = NULL;
	bool force_overwrite = false;
	double started_at = now_seconds();
	bool progress_enabled = stderr_is_tty();
	bool progress_live = stderr_is_tty();
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
		} else if (strcmp(argv[i], "--progress") == 0) {
			progress_enabled = true;
		} else if (strcmp(argv[i], "--no-progress") == 0) {
			progress_enabled = false;
		} else if (strcmp(argv[i], "--force") == 0 || strcmp(argv[i], "-f") == 0) {
			force_overwrite = true;
		} else if (strcmp(argv[i], "-o") == 0) {
			if (i + 1 >= argc) {
				free(inputs);
				return fail("-o requires output path");
			}
			output_arg = argv[++i];
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
	if (input_count == 0) {
		free(inputs);
		return fail("compress requires at least one input file");
	}
	if (s.mode == RSRC_EXPLICIT && input_count != 1) {
		free(inputs);
		return fail("--rsrc requires exactly one input file");
	}
	if (output_arg == NULL) {
		output_path = default_output_archive_name(inputs, input_count);
		if (output_path == NULL) {
			free(inputs);
			return fail("out of memory");
		}
	} else {
		char *expanded = expand_tilde_path(output_arg);
		if (expanded == NULL) {
			free(inputs);
			return fail("out of memory");
		}
		output_path = append_cpt_extension(expanded);
		free(expanded);
		if (output_path == NULL) {
			free(inputs);
			return fail("out of memory");
		}
	}
	if (strcmp(output_path, "-") != 0 && !force_overwrite && path_exists(output_path)) {
		free(output_path);
		free(inputs);
		return fail("output archive already exists (use --force to overwrite)");
	}

	cp_entry_input *entries = NULL;
	input_owned *owned = NULL;
	size_t built_count = 0;
	if (build_entries_from_inputs(&s, inputs, input_count, &entries, &owned, &built_count, NULL) != 0) {
		free(output_path);
		free(inputs);
		return 1;
	}
	if (s.mode == RSRC_EXPLICIT && built_count != 1) {
		free_built_entries(entries, owned, built_count);
		free(output_path);
		free(inputs);
		return fail("--rsrc requires exactly one file input");
	}

	size_t input_bytes_total = 0;
	for (size_t i = 0; i < built_count; ++i) {
		input_bytes_total += entries[i].data_len + entries[i].resource_len;
	}

	meta_record *meta_records = NULL;
	size_t meta_count = 0;
	if (collect_directory_metadata_for_inputs(&meta_records, &meta_count, inputs, input_count) != 0) {
		free_meta_records(meta_records, meta_count);
		free_built_entries(entries, owned, built_count);
		free(output_path);
		free(inputs);
		return 1;
	}
	for (size_t i = 0; i < built_count; ++i) {
		if (collect_metadata_for_input(&meta_records, &meta_count, owned[i].source_path, owned[i].archive_name) != 0) {
			free_meta_records(meta_records, meta_count);
			free_built_entries(entries, owned, built_count);
			free(output_path);
			free(inputs);
			return 1;
		}
	}
	uint8_t *meta_blob = NULL;
	size_t meta_blob_len = 0;
	if (build_metadata_blob(meta_records, meta_count, &meta_blob, &meta_blob_len) != 0) {
		free_meta_records(meta_records, meta_count);
		free_built_entries(entries, owned, built_count);
		free(output_path);
		free(inputs);
		return 1;
	}
	free_meta_records(meta_records, meta_count);

	cp_buffer archive = {0};
	progress_state encode_progress = {
		.enabled = progress_enabled,
		.live = progress_live,
		.label = "compress-encode",
		.total = 1,
		.done = 0,
		.started_at = 0,
		.last_emit_at = 0,
	};
	size_t encode_total_work = input_bytes_total > (SIZE_MAX / 2) ? SIZE_MAX : (input_bytes_total * 2);
	progress_begin(&encode_progress, "compress-encode", encode_total_work == 0 ? 1 : encode_total_work);
	int rc = cp_archive_create_with_progress(entries, built_count, NULL, 0, &archive, archive_encode_progress_callback, &encode_progress);
	progress_end(&encode_progress);
	if (rc != CP_OK) {
		fprintf(stderr, "error: cp_archive_create failed: %s\n", cp_error_string(rc));
		free(meta_blob);
		free_built_entries(entries, owned, built_count);
		free(output_path);
		free(inputs);
		return 1;
	}

	uint8_t *archive_with_meta = NULL;
	size_t archive_with_meta_len = 0;
	if (append_metadata_trailer(archive.ptr, archive.len, meta_blob, meta_blob_len, &archive_with_meta, &archive_with_meta_len) != 0) {
		cp_buffer_free(&archive);
		free(meta_blob);
		free_built_entries(entries, owned, built_count);
		free(output_path);
		free(inputs);
		return 1;
	}

	int write_rc = write_file(output_path, archive_with_meta, archive_with_meta_len);
	cp_buffer_free(&archive);
	free(archive_with_meta);
	free(meta_blob);
	free_built_entries(entries, owned, built_count);
	free(output_path);
	free(inputs);
	if (write_rc == 0) {
		double elapsed_s = now_seconds() - started_at;
		if (elapsed_s < 0.0) elapsed_s = 0.0;
		print_compress_stats(input_bytes_total, archive_with_meta_len, elapsed_s);
	}
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
	double started_at = now_seconds();
	bool progress_enabled = stderr_is_tty();
	bool progress_live = stderr_is_tty();
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
		} else if (strcmp(argv[i], "--progress") == 0) {
			progress_enabled = true;
		} else if (strcmp(argv[i], "--no-progress") == 0) {
			progress_enabled = false;
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
	split_archive_and_metadata(archive_bytes, archive_len, &base_archive, &base_archive_len, &meta_blob, &meta_blob_len, NULL);

	meta_record *meta_records = NULL;
	size_t meta_count = 0;
	dir_restore_target *dir_targets = NULL;
	size_t dir_target_count = 0;
	if (meta_blob != NULL && parse_metadata_blob(meta_blob, meta_blob_len, &meta_records, &meta_count) != 0) {
		free(archive_bytes);
		free(paths);
		free(path_found);
		return 1;
	}

	cp_archive_output extracted = {0};
	phase_heartbeat decode_hb = {
		.enabled = progress_enabled,
		.live = progress_live,
		.running = false,
		.label = NULL,
		.started_at = 0,
	};
	phase_heartbeat_begin(&decode_hb, "expand-decode");
	int rc = cp_archive_extract(base_archive, base_archive_len, 1, &extracted);
	phase_heartbeat_end(&decode_hb);
	free(archive_bytes);
	if (rc != CP_OK) {
		fprintf(stderr, "error: cp_archive_extract failed: %s\n", cp_error_string(rc));
		free_meta_records(meta_records, meta_count);
		free_dir_restore_targets(dir_targets, dir_target_count);
		free(paths);
		free(path_found);
		return 1;
	}

	if (s.mode == RSRC_EXPLICIT && path_count > 1) {
		cp_archive_output_free(&extracted);
		free_meta_records(meta_records, meta_count);
		free_dir_restore_targets(dir_targets, dir_target_count);
		free(paths);
		free(path_found);
		return fail("--rsrc supports one output path target");
	}
	if (s.mode == RSRC_EXPLICIT && path_count == 0 && extracted.entry_count != 1) {
		cp_archive_output_free(&extracted);
		free_meta_records(meta_records, meta_count);
		free_dir_restore_targets(dir_targets, dir_target_count);
		free(paths);
		free(path_found);
		return fail("--rsrc requires archive with exactly one entry for expand");
	}

	progress_state progress = {
		.enabled = progress_enabled,
		.live = progress_live,
		.label = "expand",
		.total = 1,
		.done = 0,
		.started_at = 0,
	};
	progress_begin(&progress, "expand-write", extracted.entry_count == 0 ? 1 : extracted.entry_count);
	size_t expanded_bytes_total = 0;

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
			progress_update(&progress, i + 1);
				if (!is_safe_archive_name(entry->name_ptr, entry->name_len)) {
				cp_archive_output_free(&extracted);
				free_meta_records(meta_records, meta_count);
				free_dir_restore_targets(dir_targets, dir_target_count);
				free(paths);
				free(path_found);
				return fail("unsafe entry name in archive");
			}
			char *name = copy_name(entry->name_ptr, entry->name_len);
				if (name == NULL) {
				cp_archive_output_free(&extracted);
				free_meta_records(meta_records, meta_count);
				free_dir_restore_targets(dir_targets, dir_target_count);
				free(paths);
				free(path_found);
				return fail("out of memory");
				}
			char *output_path = join_path(out_dir, name);
				if (output_path == NULL) {
					free(name);
				cp_archive_output_free(&extracted);
				free_meta_records(meta_records, meta_count);
				free_dir_restore_targets(dir_targets, dir_target_count);
				free(paths);
				free(path_found);
				return fail("out of memory");
			}
			if (write_file(output_path, entry->data_ptr, entry->data_len) != 0) {
				free(name);
				free(output_path);
				cp_archive_output_free(&extracted);
				free_meta_records(meta_records, meta_count);
				free_dir_restore_targets(dir_targets, dir_target_count);
				free(paths);
				free(path_found);
				return 1;
			}
			if (entry->resource_len > 0) {
				if (write_resource_for_output(output_path, &s, entry->resource_ptr, entry->resource_len) != 0) {
					free(name);
					free(output_path);
					cp_archive_output_free(&extracted);
					free_meta_records(meta_records, meta_count);
					free_dir_restore_targets(dir_targets, dir_target_count);
					free(paths);
					free(path_found);
					return 1;
				}
			}
			if (add_dir_restore_targets_for_entry(name, out_dir, &dir_targets, &dir_target_count) != 0) {
				free(name);
				free(output_path);
				cp_archive_output_free(&extracted);
				free_meta_records(meta_records, meta_count);
				free_dir_restore_targets(dir_targets, dir_target_count);
				free(paths);
				free(path_found);
				return 1;
			}
			const meta_record *rec = find_meta_record_by_bytes(meta_records, meta_count, entry->name_ptr, entry->name_len, META_KIND_FILE);
			if (rec != NULL) restore_metadata_for_path(output_path, rec);
			expanded_bytes_total += entry->data_len + entry->resource_len;
			free(name);
			free(output_path);
		}

	for (size_t i = 0; i < path_count; ++i) {
			if (!path_found[i]) {
				fprintf(stderr, "error: requested path not found in archive: %s\n", paths[i]);
				cp_archive_output_free(&extracted);
				free_meta_records(meta_records, meta_count);
				free_dir_restore_targets(dir_targets, dir_target_count);
				free(paths);
				free(path_found);
				return 1;
			}
		}
		progress_end(&progress);
		if (path_count == 0) {
			for (size_t i = 0; i < meta_count; ++i) {
				if (meta_records[i].kind != META_KIND_DIR) continue;
				char *output_path = join_path(out_dir, meta_records[i].path);
				if (output_path == NULL) {
					cp_archive_output_free(&extracted);
					free_meta_records(meta_records, meta_count);
					free_dir_restore_targets(dir_targets, dir_target_count);
					free(paths);
					free(path_found);
					return fail("out of memory");
				}
				if (ensure_dir_exists(output_path) != 0) {
					free(output_path);
					cp_archive_output_free(&extracted);
					free_meta_records(meta_records, meta_count);
					free_dir_restore_targets(dir_targets, dir_target_count);
					free(paths);
					free(path_found);
					return 1;
				}
				if (append_dir_restore_target(meta_records[i].path, out_dir, &dir_targets, &dir_target_count) != 0) {
					free(output_path);
					cp_archive_output_free(&extracted);
					free_meta_records(meta_records, meta_count);
					free_dir_restore_targets(dir_targets, dir_target_count);
					free(paths);
					free(path_found);
					return 1;
				}
				free(output_path);
			}
		}

		if (dir_target_count > 1) {
			qsort(dir_targets, dir_target_count, sizeof(*dir_targets), compare_dir_restore_targets_desc);
		}
		for (size_t i = 0; i < dir_target_count; ++i) {
			const meta_record *rec = find_meta_record_by_cstr(meta_records, meta_count, dir_targets[i].archive_path, META_KIND_DIR);
			if (rec != NULL) restore_metadata_for_path(dir_targets[i].output_path, rec);
		}
		double elapsed_s = now_seconds() - started_at;
		if (elapsed_s < 0.0) elapsed_s = 0.0;
		print_expand_stats(archive_len, expanded_bytes_total, elapsed_s);

		cp_archive_output_free(&extracted);
		free_meta_records(meta_records, meta_count);
		free_dir_restore_targets(dir_targets, dir_target_count);
		free(paths);
		free(path_found);
		return 0;
}

static int cmd_add(int argc, char **argv) {
	selectors s = { .mode = RSRC_DEFAULT, .rsrc_path = NULL, .xattr_name = NULL };
	bool progress_enabled = stderr_is_tty();
	bool progress_live = stderr_is_tty();
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
		} else if (strcmp(argv[i], "--progress") == 0) {
			progress_enabled = true;
		} else if (strcmp(argv[i], "--no-progress") == 0) {
			progress_enabled = false;
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
	split_archive_and_metadata(archive_bytes, archive_len, &base_archive, &base_archive_len, &meta_blob_in, &meta_blob_in_len, NULL);

	meta_record *old_meta = NULL;
	size_t old_meta_count = 0;
	if (meta_blob_in != NULL && parse_metadata_blob(meta_blob_in, meta_blob_in_len, &old_meta, &old_meta_count) != 0) {
		free(archive_bytes);
		free(inputs);
		return 1;
	}

	cp_entry_input *entries = NULL;
	input_owned *owned = NULL;
	size_t built_count = 0;
	progress_state progress = {
		.enabled = progress_enabled,
		.live = progress_live,
		.label = "add",
		.total = 1,
		.done = 0,
		.started_at = 0,
	};
	progress_begin(&progress, "add-read", input_count);
	if (build_entries_from_inputs(&s, inputs, input_count, &entries, &owned, &built_count, &progress) != 0) {
		free(archive_bytes);
		free_meta_records(old_meta, old_meta_count);
		free(inputs);
		return 1;
	}
	progress_end(&progress);
	if (s.mode == RSRC_EXPLICIT && built_count != 1) {
		free(archive_bytes);
		free_meta_records(old_meta, old_meta_count);
		free_built_entries(entries, owned, built_count);
		free(inputs);
		return fail("--rsrc requires exactly one file input");
	}

	cp_archive_output existing = {0};
	phase_heartbeat decode_hb = {
		.enabled = progress_enabled,
		.live = progress_live,
		.running = false,
		.label = NULL,
		.started_at = 0,
	};
	phase_heartbeat_begin(&decode_hb, "add-decode");
	int rc = cp_archive_extract(base_archive, base_archive_len, 1, &existing);
	phase_heartbeat_end(&decode_hb);
	free(archive_bytes);
	if (rc != CP_OK) {
		fprintf(stderr, "error: cp_archive_extract failed: %s\n", cp_error_string(rc));
		free_meta_records(old_meta, old_meta_count);
		free_built_entries(entries, owned, built_count);
		free(inputs);
		return 1;
	}

	size_t combined_count = existing.entry_count + built_count;
	cp_entry_input *combined = (cp_entry_input *)calloc(combined_count, sizeof(*combined));
	if (combined == NULL) {
		free(combined);
		free_meta_records(old_meta, old_meta_count);
		cp_archive_output_free(&existing);
		free_built_entries(entries, owned, built_count);
		free(inputs);
		return fail("out of memory");
	}

	meta_record *meta_records = NULL;
	size_t meta_count = 0;
	for (size_t i = 0; i < old_meta_count; ++i) {
		if (upsert_meta_record(&meta_records, &meta_count, old_meta[i].path, old_meta[i].kind, &old_meta[i].attrs, true) != 0) {
			free(combined);
			free_meta_records(meta_records, meta_count);
			free_meta_records(old_meta, old_meta_count);
			cp_archive_output_free(&existing);
			free_built_entries(entries, owned, built_count);
			free(inputs);
			return 1;
		}
	}
	if (collect_directory_metadata_for_inputs(&meta_records, &meta_count, inputs, input_count) != 0) {
		free(combined);
		free_meta_records(meta_records, meta_count);
		free_meta_records(old_meta, old_meta_count);
		cp_archive_output_free(&existing);
		free_built_entries(entries, owned, built_count);
		free(inputs);
		return 1;
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

		const meta_record *rec = find_meta_record_by_bytes(old_meta, old_meta_count, entry->name_ptr, entry->name_len, META_KIND_FILE);
		meta_attrs attrs = rec != NULL ? rec->attrs : default_file_metadata();
		char *name = copy_name(entry->name_ptr, entry->name_len);
		if (name == NULL) {
			free(combined);
			free_meta_records(meta_records, meta_count);
			free_meta_records(old_meta, old_meta_count);
			cp_archive_output_free(&existing);
			free_built_entries(entries, owned, built_count);
			free(inputs);
			return fail("out of memory");
		}
		int upsert_rc = upsert_meta_record(&meta_records, &meta_count, name, META_KIND_FILE, &attrs, true);
		free(name);
		if (upsert_rc != 0) {
			free(combined);
			free_meta_records(meta_records, meta_count);
			free_meta_records(old_meta, old_meta_count);
			cp_archive_output_free(&existing);
			free_built_entries(entries, owned, built_count);
			free(inputs);
			return 1;
		}
		out_idx++;
	}

	for (size_t i = 0; i < built_count; ++i) {
		combined[out_idx] = entries[i];
		if (collect_metadata_for_input(&meta_records, &meta_count, owned[i].source_path, owned[i].archive_name) != 0) {
			free(combined);
			free_meta_records(meta_records, meta_count);
			free_meta_records(old_meta, old_meta_count);
			cp_archive_output_free(&existing);
			free_built_entries(entries, owned, built_count);
			free(inputs);
			return 1;
		}
		out_idx++;
	}

	uint8_t *meta_blob_out = NULL;
	size_t meta_blob_out_len = 0;
	if (build_metadata_blob(meta_records, meta_count, &meta_blob_out, &meta_blob_out_len) != 0) {
		free(combined);
		free_meta_records(meta_records, meta_count);
		free_meta_records(old_meta, old_meta_count);
		cp_archive_output_free(&existing);
		free_built_entries(entries, owned, built_count);
		free(inputs);
		return 1;
	}
	free_meta_records(meta_records, meta_count);

	cp_buffer out_archive = {0};
	progress_state encode_progress = {
		.enabled = progress_enabled,
		.live = progress_live,
		.label = "add-encode",
		.total = 1,
		.done = 0,
		.started_at = 0,
		.last_emit_at = 0,
	};
	size_t add_input_bytes_total = 0;
	for (size_t i = 0; i < combined_count; ++i) {
		add_input_bytes_total += combined[i].data_len + combined[i].resource_len;
	}
	size_t add_encode_total_work = add_input_bytes_total > (SIZE_MAX / 2) ? SIZE_MAX : (add_input_bytes_total * 2);
	progress_begin(&encode_progress, "add-encode", add_encode_total_work == 0 ? 1 : add_encode_total_work);
	rc = cp_archive_create_with_progress(
		combined,
		combined_count,
		existing.comment_ptr,
		existing.comment_len,
		&out_archive,
		archive_encode_progress_callback,
		&encode_progress);
	progress_end(&encode_progress);
	free(combined);
	free_meta_records(old_meta, old_meta_count);
	if (rc != CP_OK) {
		fprintf(stderr, "error: cp_archive_create failed: %s\n", cp_error_string(rc));
		free(meta_blob_out);
		cp_archive_output_free(&existing);
		free_built_entries(entries, owned, built_count);
		free(inputs);
		return 1;
	}

	uint8_t *archive_with_meta = NULL;
	size_t archive_with_meta_len = 0;
	if (append_metadata_trailer(out_archive.ptr, out_archive.len, meta_blob_out, meta_blob_out_len, &archive_with_meta, &archive_with_meta_len) != 0) {
		cp_buffer_free(&out_archive);
		free(meta_blob_out);
		cp_archive_output_free(&existing);
		free_built_entries(entries, owned, built_count);
		free(inputs);
		return 1;
	}

	int write_rc = write_file(archive_path, archive_with_meta, archive_with_meta_len);
	free(archive_with_meta);
	cp_buffer_free(&out_archive);
	free(meta_blob_out);
	cp_archive_output_free(&existing);
	free_built_entries(entries, owned, built_count);
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
	size_t trailer_total_len = 0;
	split_archive_and_metadata(archive_bytes, archive_len, &base_archive, &base_archive_len, &meta_blob, &meta_blob_len, &trailer_total_len);
	(void)meta_blob;

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

	printf("trailer_size=%zu\ttrailer_payload=%zu\n", trailer_total_len, meta_blob_len);

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
