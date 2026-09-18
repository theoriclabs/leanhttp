# LeanHttp

A synchronous and asynchronous HTTP client for Lean 4 backed by libcurl through a small C FFI.
The public API reuses `Std.Http`'s validated methods, URIs, headers, and
statuses. HTTP error statuses are ordinary responses; transport failures have
typed, stable categories.

```toml
[[require]]
name = "leanhttp"
git = "https://github.com/theoriclabs/leanhttp"
rev = "v0.4.0"
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
`LeanHttp.WebSocket` reuses the same configuration for `ws://` and `wss://`
connections.

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

Opening `LeanHttp` (or `open scoped LeanHttp`) enables `uri!`, `target!`,
`headerName!`, and `headerValue!`. Invalid literals fail during compilation. URI literals validate
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
Literal `"."` and `".."` segment values become `%2E` and `%2E%2E`, so dynamic
identifiers remain data when resolved and sent. For directory navigation, use
reference syntax such as `target!"../users"` instead of `.segment ".."`.

`.header` replaces all request headers with the same name; `.addHeader` appends
another value. Request headers override session defaults, and a nonempty `Body`
determines the final `Content-Type`.

`Session.Config.userAgent` is also a validated `Std.Http.Header.Value`. For
example, use `{ userAgent := headerValue!"my-client/1.0" }`. For a runtime value,
validate it with `Std.Http.Header.Value.ofString?` before creating the session.
This prevents CR, LF, and NUL from reaching libcurl through the user-agent option.

## Absolute and relative targets

`Request.uri` uses the inductive `Target` type: `.absolute URI` or
`.relative RelativeRef`. Existing `uri!` values and parsed `Std.Http.URI`s coerce
to absolute targets. Use `target!` for checked relative or absolute targets and
`Target.parse?` for dynamic strings.

```lean
import LeanHttp

open LeanHttp

def relativeRequest (userId : String) : Request :=
  (Request.get target!"users")
    |>.segment userId
    |>.param "expand" "team"

def fetchUser (userId : String) : IO (Outcome Lean.Json) :=
  requestAs (relativeRequest userId) {
    baseUri := some uri!"https://api.example.com/v1/"
  }
```

The base above resolves `users` to `/v1/users`; `/users` replaces the base path.
Relative paths merge with the base's directory, so a base ending in `/v1/index`
also resolves `users` to `/v1/users`. Dot segments such as `../users` are resolved
before sending. Missing bases return a `.urlMalformed` error.

`RelativeRef.query : Option Std.Http.URI.Query` distinguishes an omitted query
from an explicitly empty one. An empty reference inherits the base path and query;
`target!"?"` inherits its path and clears its query. `target!"?page=2"` replaces
the query. Relative references never replace the base's authority. Scheme-relative
strings such as `//other.example/path` are rejected; supply an explicit absolute
URL when changing hosts. Absolute targets must have an HTTP(S) scheme and an
authority, and ignore the base. `Target.resolve` exposes these checks as a pure
function returning an inductive `Target.Error`.

Resolution removes literal dot segments from absolute URLs as well as nonempty
relative paths, preserving percent-encoded segment data. Serializing relative
references escapes fragments and adds a dot prefix when necessary to preserve
their meaning: appending `"a:b"` to an empty relative target prints `./a:b`, so
parsing it again cannot turn it into an absolute URI.

Migration from 0.2: code that reads `Request.uri` directly now receives a
`Target`; match its `.absolute` and `.relative` cases or call `.resolve` with a
base. `Response.effectiveUri` still contains the final `Std.Http.URI`.

## Async requests and bounded batches

`requestAsync` and `requestAsAsync` return `Std.Async.Async` actions with the
same raw results and typed `Outcome` cases as synchronous calls. Each accepts
an optional `Session.Config` and runs its blocking libcurl transfer on a dedicated
worker with its own session. Awaiting it suspends through Lean's task scheduler.

```lean
import LeanHttp

open LeanHttp

structure UserResult where
  name : String
  deriving Lean.FromJson

def fetchUsers : Std.Async.Async (Array (Outcome UserResult)) :=
  requestManyAsAsync #[
    Request.get target!"users/1",
    Request.get target!"users/2"
  ] {
    concurrency := 4
    session := { baseUri := some uri!"https://api.example.com/v1/" }
  }

def fetchUsersIO : IO (Array (Outcome UserResult)) :=
  Std.Async.Async.block fetchUsers
```

`requestManyAsync` returns raw responses; `requestManyAsAsync` decodes each
response independently. Results stay in input order, and one failed request does
not stop the others. Each batch creates at most `min(concurrency, request count)`
workers. Each worker reuses one session and takes requests from a shared queue.
The limit is per batch; independent one-shot calls each start their own worker.

`Concurrency` requires a proof that its value is positive. Numeric literals such
as `4` work directly; use `Concurrency.ofNat?` for runtime counts. Zero is rejected.
Empty batches create no workers or sessions. Batches collect all results in memory;
`Batch.Config.session.maxBody` can limit each response body.

For code using `Task` directly, use `requestTask`, `requestAsTask`,
`requestManyTask`, or `requestManyAsTask`. These return `BaseIO (Task ...)` and
start work when that `BaseIO` action runs. Async actions start when executed.
Synchronous `Session` handles are not shared by these operations.

This backend uses dedicated threads, not libcurl's multi interface. There is no
transfer cancellation API: dropping a task or abandoning an async branch does
not abort an in-flight transfer. Its worker still owns and closes the session
when the operation completes. Configure request timeouts accordingly; they begin
when a worker starts the request and exclude queueing time. A zero total timeout
allows an operation to run indefinitely.

The [design proposal](docs/proposals/0001-targets-and-async.md) records the API,
ownership rules, compatibility changes, and deferred work.

## WebSocket connections

`LeanHttp.WebSocket` speaks `ws://` and `wss://` through libcurl's WebSocket
API, so TLS policy, proxies, the user agent and default headers come from the
same `Session.Config` as HTTP requests. Messages, close codes, size limits and
fragment reassembly are [leanws](https://github.com/theoriclabs/leanws) values,
so a connection opened here carries exactly the messages `LeanWs.Client` does.

```lean
import LeanHttp
import LeanWs

open LeanHttp Std.Http

def tail (token : String) : IO (Except LeanHttp.Error Unit) :=
  WebSocket.withConnection target!"wss://app.example.com/channel" {
    subprotocols := ["leanapp.v1"]
    headers := Headers.empty.insert! "Cookie" s!"session={token}"
  } fun connection => do
    discard <| connection.send (.text "{\"subscribe\":\"doc-1\"}")
    repeat
      match ← connection.recv with
      | .ok (some (.text text)) => IO.println text
      | .ok (some (.binary bytes)) => IO.println s!"{bytes.size} bytes"
      | .ok none => break
      | .error error => throw <| IO.userError (toString error)
```

`recv` returns one complete message: it reassembles fragments, answers pings,
drops pongs, and returns `none` once the peer has closed, with the status left
in `closeInfo`. `Options.limits` bounds received frames and messages exactly as
in `leanws`; a message over the limit closes the connection with `1009` and is
reported as a `.websocketProtocol` error. A receive that exhausts `recvTimeout`
is a `.timeout` error and leaves the connection usable. `close` sends the
closing frame and releases the handle; `withConnection` does that on both the
normal and the failing path.

Subprotocols are offered in preference order and the server's choice is
verified against them, so `Connection.subprotocol` never reports something that
was not offered. Relative targets resolve against `Options.session.baseUri`,
which must itself be a `ws://` or `wss://` URI; an `http://` target is rejected
as `.unsupportedProtocol` rather than silently upgraded.

A connection owns one easy handle and is no more thread-safe than a `Session`:
one task owns it, and `recv` blocks that task's thread until a message arrives
or its timeout expires. `connectAsync`, `Connection.sendAsync` and
`Connection.recvAsync`, with the matching `Task` variants, move those blocking
calls onto dedicated workers the way the HTTP async API does.

libcurl gained the WebSocket API in 7.86 and can still be built without it.
`WebSocket.supported` reports what the loaded library can do, and `connect`
fails with a typed `.websocketUnsupported` error instead of a generic transport
failure. There is no permessage-deflate and no cancellation API here either.

## Runtime and development

At runtime LeanHttp loads `libcurl.4.dylib` on macOS or `libcurl.so.4` on
Linux. Set `LEANHTTP_LIB` to force a particular library. WebSocket connections
additionally need a libcurl of 7.86 or later that lists the `ws` protocol;
`WebSocket.supported` reports whether the loaded one does. Windows is not yet
supported. Compilation also needs libcurl headers (provided by the macOS SDK;
typically the distribution's libcurl development package on Linux). Consumer
executables do not need a link-time `-lcurl` flag.

Requires Lean `v4.33.0`.

Run the in-process HTTP, WebSocket and loader-failure suites with:

```bash
lake test
```

The WebSocket suite runs against an in-process `leanws` server. Where the
system libcurl has no WebSocket support it checks the typed error and skips the
round trips; point `LEANHTTP_LIB` at a WebSocket-capable libcurl to run them,
and set `LEANHTTP_TLS_TEST_URL` to a `wss://` echo endpoint to add the TLS case:

```bash
LEANHTTP_LIB=/opt/homebrew/opt/curl/lib/libcurl.4.dylib lake test
```

Changes are recorded in [CHANGELOG.md](CHANGELOG.md). Published versions are
available in [GitHub Releases](https://github.com/theoriclabs/leanhttp/releases).
See [RELEASING.md](RELEASING.md) for the versioning and release process.
