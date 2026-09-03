#if defined(__i386__) || defined(_M_IX86) || defined(__arm__) || \
    (defined(__SIZEOF_POINTER__) && __SIZEOF_POINTER__ == 4)
#error "32-bit platforms are not supported by LeanHttp."
#endif

#include <lean/lean.h>
#include <curl/curl.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "curl_options.h"

#ifdef _WIN32
#define LEANHTTP_API __declspec(dllexport)
#else
#define LEANHTTP_API __attribute__((visibility("default")))
#endif

typedef CURLcode (*global_init_fn)(long);
typedef char *(*version_fn)(void);
typedef CURL *(*easy_init_fn)(void);
typedef void (*easy_cleanup_fn)(CURL *);
typedef void (*easy_reset_fn)(CURL *);
typedef CURLcode (*easy_setopt_fn)(CURL *, CURLoption, ...);
typedef CURLcode (*easy_perform_fn)(CURL *);
typedef CURLcode (*easy_getinfo_fn)(CURL *, CURLINFO, ...);
typedef const char *(*easy_strerror_fn)(CURLcode);
typedef char *(*easy_escape_fn)(CURL *, const char *, int);
typedef void (*curl_free_fn)(void *);
typedef struct curl_slist *(*slist_append_fn)(struct curl_slist *, const char *);
typedef void (*slist_free_all_fn)(struct curl_slist *);

static struct {
  global_init_fn global_init;
  version_fn version;
  easy_init_fn easy_init;
  easy_cleanup_fn easy_cleanup;
  easy_reset_fn easy_reset;
  easy_setopt_fn easy_setopt;
  easy_perform_fn easy_perform;
  easy_getinfo_fn easy_getinfo;
  easy_strerror_fn easy_strerror;
  easy_escape_fn easy_escape;
  curl_free_fn free;
  slist_append_fn slist_append;
  slist_free_all_fn slist_free_all;
} api;

static pthread_once_t load_once = PTHREAD_ONCE_INIT;
static void *curl_lib = NULL;
static int load_ok = 0;
static char load_detail[2048];

static void *symbol(const char *name) {
  void *p = dlsym(curl_lib, name);
  if (p == NULL) {
    snprintf(load_detail, sizeof(load_detail), "missing libcurl symbol %s: %s", name, dlerror());
  }
  return p;
}

#define LOAD(field, name) do { \
  *(void **)(&api.field) = symbol(name); \
  if (api.field == NULL) return; \
} while (0)

static void load_curl(void) {
  const char *forced = getenv("LEANHTTP_LIB");
  const char *names[] = {
    forced,
#ifdef __APPLE__
    "/usr/lib/libcurl.4.dylib", "libcurl.4.dylib", "libcurl.dylib",
#else
    "libcurl.so.4", "libcurl.so",
#endif
    NULL
  };
  load_detail[0] = '\0';
  for (size_t i = 0; names[i] != NULL || i == 0; ++i) {
    const char *name = names[i];
    if (name == NULL || name[0] == '\0') continue;
    curl_lib = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    if (curl_lib != NULL) break;
    const char *err = dlerror();
    snprintf(load_detail, sizeof(load_detail), "tried %s: %s", name, err ? err : "not found");
    if (forced != NULL && forced[0] != '\0') break;
  }
  if (curl_lib == NULL) {
    if (load_detail[0] == '\0') snprintf(load_detail, sizeof(load_detail), "no libcurl candidate found");
    return;
  }
  LOAD(global_init, "curl_global_init");
  LOAD(version, "curl_version");
  LOAD(easy_init, "curl_easy_init");
  LOAD(easy_cleanup, "curl_easy_cleanup");
  LOAD(easy_reset, "curl_easy_reset");
  LOAD(easy_setopt, "curl_easy_setopt");
  LOAD(easy_perform, "curl_easy_perform");
  LOAD(easy_getinfo, "curl_easy_getinfo");
  LOAD(easy_strerror, "curl_easy_strerror");
  LOAD(easy_escape, "curl_easy_escape");
  LOAD(free, "curl_free");
  LOAD(slist_append, "curl_slist_append");
  LOAD(slist_free_all, "curl_slist_free_all");
  CURLcode code = api.global_init(CURL_GLOBAL_DEFAULT);
  if (code != CURLE_OK) {
    snprintf(load_detail, sizeof(load_detail), "curl_global_init failed: %s", api.easy_strerror(code));
    return;
  }
  load_ok = 1;
}

static int ensure_loaded(void) {
  pthread_once(&load_once, load_curl);
  return load_ok;
}

static lean_obj_res io_error(uint32_t code, const char *detail) {
  return lean_io_result_mk_error(lean_mk_io_error_other_error(code, lean_mk_string(detail ? detail : "")));
}

static lean_obj_res library_error(void) {
  ensure_loaded();
  return io_error(9000, load_detail);
}

struct buffer {
  uint8_t *data;
  size_t size;
  size_t capacity;
};

struct leanhttp_handle {
  CURL *easy;
  struct curl_slist *headers;
  uint8_t *post;
  size_t post_len;
  char error[CURL_ERROR_SIZE];
  struct buffer response_headers;
  struct buffer response_body;
  size_t max_body;
  int body_too_large;
};

static void buffer_clear(struct buffer *b) { b->size = 0; }
static void buffer_free(struct buffer *b) { free(b->data); b->data = NULL; b->size = b->capacity = 0; }

static int buffer_append(struct buffer *b, const void *data, size_t size) {
  if (size > SIZE_MAX - b->size) return 0;
  size_t needed = b->size + size;
  if (needed > b->capacity) {
    size_t cap = b->capacity ? b->capacity : 4096;
    while (cap < needed) {
      if (cap > SIZE_MAX / 2) { cap = needed; break; }
      cap *= 2;
    }
    void *next = realloc(b->data, cap);
    if (next == NULL) return 0;
    b->data = next;
    b->capacity = cap;
  }
  memcpy(b->data + b->size, data, size);
  b->size = needed;
  return 1;
}

static size_t write_body(char *ptr, size_t size, size_t nmemb, void *userdata) {
  struct leanhttp_handle *h = userdata;
  if (size != 0 && nmemb > SIZE_MAX / size) return 0;
  size_t count = size * nmemb;
  if (count > h->max_body || h->response_body.size > h->max_body - count) {
    h->body_too_large = 1;
    return 0;
  }
  return buffer_append(&h->response_body, ptr, count) ? count : 0;
}

static size_t write_header(char *ptr, size_t size, size_t nmemb, void *userdata) {
  struct leanhttp_handle *h = userdata;
  if (size != 0 && nmemb > SIZE_MAX / size) return 0;
  size_t count = size * nmemb;
  return buffer_append(&h->response_headers, ptr, count) ? count : 0;
}

static lean_external_class *handle_class = NULL;

static void release_request(struct leanhttp_handle *h) {
  if (h->headers != NULL && api.slist_free_all != NULL) api.slist_free_all(h->headers);
  h->headers = NULL;
  free(h->post);
  h->post = NULL;
  h->post_len = 0;
}

static void handle_finalize(void *data) {
  struct leanhttp_handle *h = data;
  if (h == NULL) return;
  release_request(h);
  if (h->easy != NULL && api.easy_cleanup != NULL) api.easy_cleanup(h->easy);
  buffer_free(&h->response_headers);
  buffer_free(&h->response_body);
  free(h);
}

static void handle_foreach(void *data, b_lean_obj_arg arg) { (void)data; (void)arg; }

static struct leanhttp_handle *get_handle(b_lean_obj_arg object) {
  return (struct leanhttp_handle *)lean_get_external_data(object);
}

static lean_obj_res handle_error(struct leanhttp_handle *h, CURLcode code, const char *where) {
  const char *base = api.easy_strerror ? api.easy_strerror(code) : "libcurl error";
  char detail[1024];
  if (h != NULL && h->error[0] != '\0')
    snprintf(detail, sizeof(detail), "%s: %s: %s", where, base, h->error);
  else
    snprintf(detail, sizeof(detail), "%s: %s", where, base);
  return io_error((uint32_t)code, detail);
}

LEANHTTP_API lean_obj_res leanhttp_initialize(void) {
  handle_class = lean_register_external_class(handle_finalize, handle_foreach);
  return lean_io_result_mk_ok(lean_box(0));
}

LEANHTTP_API lean_obj_res leanhttp_available(void) {
  return lean_io_result_mk_ok(lean_box(ensure_loaded() ? 1 : 0));
}

LEANHTTP_API lean_obj_res leanhttp_version(void) {
  if (!ensure_loaded()) return library_error();
  return lean_io_result_mk_ok(lean_mk_string(api.version()));
}

LEANHTTP_API lean_obj_res leanhttp_easy_init(void) {
  if (!ensure_loaded()) return library_error();
  struct leanhttp_handle *h = calloc(1, sizeof(*h));
  if (h == NULL) return io_error(9001, "allocating LeanHttp handle failed");
  h->easy = api.easy_init();
  h->max_body = SIZE_MAX;
  if (h->easy == NULL) { free(h); return io_error(2, "curl_easy_init returned NULL"); }
  return lean_io_result_mk_ok(lean_alloc_external(handle_class, h));
}

LEANHTTP_API lean_obj_res leanhttp_easy_reset(b_lean_obj_arg object) {
  struct leanhttp_handle *h = get_handle(object);
  if (h->easy == NULL) return io_error(2, "LeanHttp session is closed");
  release_request(h);
  buffer_clear(&h->response_headers);
  buffer_clear(&h->response_body);
  h->error[0] = '\0';
  h->max_body = SIZE_MAX;
  h->body_too_large = 0;
  api.easy_reset(h->easy);
  return lean_io_result_mk_ok(lean_box(0));
}

LEANHTTP_API lean_obj_res leanhttp_setopt_long(b_lean_obj_arg object, uint32_t option, int64_t value) {
  struct leanhttp_handle *h = get_handle(object);
  if (h->easy == NULL) return io_error(2, "LeanHttp session is closed");
  CURLcode code;
  if ((CURLoption)option == CURLOPT_MAXFILESIZE_LARGE) {
    h->max_body = value < 0 ? SIZE_MAX : (size_t)value;
    code = api.easy_setopt(h->easy, (CURLoption)option, (curl_off_t)value);
  } else {
    code = api.easy_setopt(h->easy, (CURLoption)option, (long)value);
  }
  if (code != CURLE_OK) return handle_error(h, code, "curl_easy_setopt(long)");
  return lean_io_result_mk_ok(lean_box(0));
}

LEANHTTP_API lean_obj_res leanhttp_setopt_string(b_lean_obj_arg object, uint32_t option, lean_obj_arg value) {
  struct leanhttp_handle *h = get_handle(object);
  if (h->easy == NULL) { lean_dec(value); return io_error(2, "LeanHttp session is closed"); }
  CURLcode code = api.easy_setopt(h->easy, (CURLoption)option, lean_string_cstr(value));
  lean_dec(value);
  if (code != CURLE_OK) return handle_error(h, code, "curl_easy_setopt(string)");
  return lean_io_result_mk_ok(lean_box(0));
}

LEANHTTP_API lean_obj_res leanhttp_setopt_bytes(b_lean_obj_arg object, uint32_t option, b_lean_obj_arg value) {
  struct leanhttp_handle *h = get_handle(object);
  if (h->easy == NULL) return io_error(2, "LeanHttp session is closed");
  size_t size = lean_sarray_size(value);
  uint8_t *copy = malloc(size ? size : 1);
  if (copy == NULL) return io_error(9001, "allocating request body failed");
  if (size) memcpy(copy, lean_sarray_cptr(value), size);
  free(h->post);
  h->post = copy;
  h->post_len = size;
  CURLcode code = api.easy_setopt(h->easy, (CURLoption)option, h->post);
  if (code == CURLE_OK) code = api.easy_setopt(h->easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)size);
  if (code != CURLE_OK) return handle_error(h, code, "curl_easy_setopt(body)");
  return lean_io_result_mk_ok(lean_box(0));
}

LEANHTTP_API lean_obj_res leanhttp_set_headers(b_lean_obj_arg object, b_lean_obj_arg values) {
  struct leanhttp_handle *h = get_handle(object);
  if (h->easy == NULL) return io_error(2, "LeanHttp session is closed");
  struct curl_slist *next = NULL;
  size_t size = lean_array_size(values);
  for (size_t i = 0; i < size; ++i) {
    b_lean_obj_arg value = lean_array_uget_borrowed(values, i);
    struct curl_slist *appended = api.slist_append(next, lean_string_cstr(value));
    if (appended == NULL) {
      if (next != NULL) api.slist_free_all(next);
      return io_error(9001, "allocating request headers failed");
    }
    next = appended;
  }
  CURLcode code = api.easy_setopt(h->easy, CURLOPT_HTTPHEADER, next);
  if (code != CURLE_OK) {
    if (next != NULL) api.slist_free_all(next);
    return handle_error(h, code, "curl_easy_setopt(headers)");
  }
  if (h->headers != NULL) api.slist_free_all(h->headers);
  h->headers = next;
  return lean_io_result_mk_ok(lean_box(0));
}

LEANHTTP_API lean_obj_res leanhttp_perform(b_lean_obj_arg object) {
  struct leanhttp_handle *h = get_handle(object);
  if (h->easy == NULL) return io_error(2, "LeanHttp session is closed");
  buffer_clear(&h->response_headers);
  buffer_clear(&h->response_body);
  h->body_too_large = 0;
  h->error[0] = '\0';
  CURLcode code = api.easy_setopt(h->easy, CURLOPT_ERRORBUFFER, h->error);
  if (code == CURLE_OK) code = api.easy_setopt(h->easy, CURLOPT_WRITEFUNCTION, write_body);
  if (code == CURLE_OK) code = api.easy_setopt(h->easy, CURLOPT_WRITEDATA, h);
  if (code == CURLE_OK) code = api.easy_setopt(h->easy, CURLOPT_HEADERFUNCTION, write_header);
  if (code == CURLE_OK) code = api.easy_setopt(h->easy, CURLOPT_HEADERDATA, h);
  if (code == CURLE_OK) code = api.easy_setopt(h->easy, CURLOPT_NOSIGNAL, 1L);
  if (code != CURLE_OK) return handle_error(h, code, "configuring transfer callbacks");
  code = api.easy_perform(h->easy);
  if (h->body_too_large) return handle_error(h, CURLE_FILESIZE_EXCEEDED, "response body limit");
  if (code != CURLE_OK) return handle_error(h, code, "curl_easy_perform");
  long status = 0;
  code = api.easy_getinfo(h->easy, CURLINFO_RESPONSE_CODE, &status);
  if (code != CURLE_OK) return handle_error(h, code, "curl_easy_getinfo(status)");
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)status));
}

static lean_obj_res copy_bytes(const struct buffer *b) {
  lean_object *out = lean_alloc_sarray(1, b->size, b->size);
  if (b->size) memcpy(lean_sarray_cptr(out), b->data, b->size);
  return lean_io_result_mk_ok(out);
}

LEANHTTP_API lean_obj_res leanhttp_response_headers(b_lean_obj_arg object) {
  return copy_bytes(&get_handle(object)->response_headers);
}

LEANHTTP_API lean_obj_res leanhttp_response_body(b_lean_obj_arg object) {
  return copy_bytes(&get_handle(object)->response_body);
}

LEANHTTP_API lean_obj_res leanhttp_effective_url(b_lean_obj_arg object) {
  struct leanhttp_handle *h = get_handle(object);
  char *url = NULL;
  CURLcode code = api.easy_getinfo(h->easy, CURLINFO_EFFECTIVE_URL, &url);
  if (code != CURLE_OK) return handle_error(h, code, "curl_easy_getinfo(url)");
  return lean_io_result_mk_ok(lean_mk_string(url ? url : ""));
}

LEANHTTP_API lean_obj_res leanhttp_close(b_lean_obj_arg object) {
  struct leanhttp_handle *h = get_handle(object);
  release_request(h);
  if (h->easy != NULL) { api.easy_cleanup(h->easy); h->easy = NULL; }
  return lean_io_result_mk_ok(lean_box(0));
}

LEANHTTP_API lean_obj_res leanhttp_escape(lean_obj_arg input) {
  if (!ensure_loaded()) { lean_dec(input); return library_error(); }
  CURL *easy = api.easy_init();
  if (easy == NULL) { lean_dec(input); return io_error(2, "curl_easy_init returned NULL"); }
  const char *text = lean_string_cstr(input);
  /* Lean's stored string size includes its terminating NUL. */
  size_t size = lean_string_size(input) - 1;
  if (size > INT32_MAX) {
    lean_dec(input);
    api.easy_cleanup(easy);
    return io_error(9001, "form field is too large for curl_easy_escape");
  }
  char *escaped = api.easy_escape(easy, text, (int)size);
  lean_dec(input);
  if (escaped == NULL) { api.easy_cleanup(easy); return io_error(9001, "curl_easy_escape failed"); }
  lean_object *out = lean_mk_string(escaped);
  api.free(escaped);
  api.easy_cleanup(easy);
  return lean_io_result_mk_ok(out);
}
