# LeanHttp

A synchronous HTTP client for Lean 4 backed by libcurl through a small C FFI.
The public API reuses `Std.Http`'s validated methods, URIs, headers, and
statuses. HTTP error statuses are ordinary responses; transport failures have
typed, stable categories.

```toml
[[require]]
name = "leanhttp"
git = "https://github.com/theoriclabs/leanhttp"
rev = "v0.2.0"
```

```lean
import LeanHttp

open LeanHttp

def main : IO Unit := do
  match ← LeanHttp.get uri!"https://example.com" with
  | .ok response => IO.println s!"{response.statusCode}: {response.body.size} bytes"
  | .error error => throw <| IO.userError (toString error)
```

`Session` reuses one libcurl easy handle, so connections stay alive across
requests. It supports timeouts, bounded response bodies, redirects, TLS policy,
basic and bearer authentication, proxies, compression, binary/text/JSON/form
bodies, typed body codecs, and one-session-per-task concurrency.

## Composing requests

Request helpers return ordinary `Request` records. Use pipelines for bodies,
authentication, headers, path segments, and query parameters; use record updates
for settings such as timeouts and redirects.

```lean
import LeanHttp

open LeanHttp

structure User where
  name : String
  deriving Lean.ToJson, Lean.FromJson

def createUser (session : Session) (input : User) (token : String) : IO (Outcome User) := do
  let req := (Request.post uri!"https://api.example.com/users")
    |>.json input
    |>.bearer token
    |>.header headerName!"Accept" headerValue!"application/json"
  session.requestAs {
    req with
    redirects := .never
    timeouts := { total := 5000 }
  }
```

`Request.get`, `.post`, `.put`, `.patch`, `.delete`, and `.head` select the
method. `.json` accepts any `Lean.ToJson` value and sets the body's media type
to `application/json`. `Body.ofJson` provides the same encoding for record
construction. Encoding a string as JSON is explicit; the ordinary `ToBody String`
codec still sends plain text.

`Session.requestAs` accepts the full request configuration. The one-shot
`LeanHttp.requestAs` uses a fresh session. Both return `Outcome α`:

- `.ok value response`: a 2xx response decoded successfully.
- `.status response`: a non-2xx response; its body has not been decoded.
- `.decode message response`: a 2xx response whose body could not be decoded.
- `.transport error`: the request failed before a response could be returned.

`FromBody` supports bytes, UTF-8 text, JSON, and types with `Lean.FromJson`
instances. `Response.decodeAs` applies the same status and decoding policy to an
existing response. The existing `Session.getAs` and `Session.exchange` helpers
remain available. `exchange` also accepts `Body` directly, or `()` for no body.

## Validated literals and URL components

Opening `LeanHttp` (or `open scoped LeanHttp`) enables `uri!`, `headerName!`, and
`headerValue!`. Invalid literals fail during compilation. URI literals validate
URI syntax; they do not check whether a server exists or supports HTTP. For
dynamic strings, use `Std.Http.URI.parse?`, `Header.Name.ofString?`, and
`Header.Value.ofString?` from `Std.Http`.

```lean
import LeanHttp

open LeanHttp

def searchRequest (userId query : String) : Request :=
  (Request.get uri!"https://api.example.com/users")
    |>.segment userId
    |>.param "q" query
    |>.param "tag" "lean"
    |>.param "tag" "http"
```

Pass raw strings to `.segment` and `.param`. For example, the segment `"a/b"`
becomes `a%2Fb`, and the query value `"a+b c"` becomes `a%2Bb+c`. Repeated query
names are appended in order. `.segment` appends one segment to the existing path;
it preserves any existing empty segments and trailing separators.

`.header` replaces all request headers with the same name; `.addHeader` appends
another value. Request headers override session defaults, and a nonempty `Body`
determines the final `Content-Type`.

`Session.Config.userAgent` is also a validated `Std.Http.Header.Value`. For
example, use `{ userAgent := headerValue!"my-client/1.0" }`. For a runtime value,
validate it with `Std.Http.Header.Value.ofString?` before creating the session.
This prevents CR, LF, and NUL from reaching libcurl through the user-agent option.

The `uri` field continues to use `Std.Http.URI`. Relative strings such as
`"/users"` are not URI literals; construct an absolute URI before building a
request. General relative-reference parsing is not part of this release.

## Runtime and development

At runtime LeanHttp loads `libcurl.4.dylib` on macOS or `libcurl.so.4` on
Linux. Set `LEANHTTP_LIB` to force a particular library. Windows is not yet
supported. Compilation also needs libcurl headers (provided by the macOS SDK;
typically the distribution's libcurl development package on Linux). Consumer
executables do not need a link-time `-lcurl` flag.

Requires Lean `v4.33.0`.

Run the in-process HTTP and loader-failure suites with:

```bash
lake test
```

Changes are recorded in [CHANGELOG.md](CHANGELOG.md). Published versions are
available in [GitHub Releases](https://github.com/theoriclabs/leanhttp/releases).
See [RELEASING.md](RELEASING.md) for the versioning and release process.
