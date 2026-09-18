# Changelog

User-visible changes are recorded here. Versions use semantic versioning and
are published as `vX.Y.Z` Git tags and GitHub releases.

## [Unreleased]

## [0.4.0] - 2026-09-18

### Added

- `LeanHttp.WebSocket`: a `ws://` and `wss://` client over libcurl's WebSocket
  API (libcurl 7.86 and later). `connect`, `withConnection`, `Connection.send`,
  `recv`, `ping` and `close`, with `connectAsync`, `Connection.sendAsync` and
  `Connection.recvAsync` plus the matching `Task` variants for blocking calls on
  dedicated workers. TLS policy, proxies, user agent and default headers come
  from `Session.Config`; subprotocols and extra handshake headers come from
  `WebSocket.Options`.
- Messages, close codes, receive limits and fragment reassembly are
  [leanws](https://github.com/theoriclabs/leanws) types, so LeanHttp and
  `LeanWs.Client` present the same `LeanWs.Message` values. leanws is a new
  package dependency.
- `WebSocket.supported` and the `Error.Kind.websocketUnsupported` case report a
  libcurl without WebSocket support, distinguishing it from a transport failure.
  `Error.Kind.websocketProtocol` reports handshake and RFC 6455 failures,
  including a message over `Options.limits`, which also closes with `1009`.
- `Target.resolveIn` resolves a target against an explicit scheme set, with
  `Target.httpSchemes` and `Target.webSocketSchemes`. `Target.resolve` keeps its
  HTTP behavior.

### Fixed

- Requests set `CURLOPT_PATH_AS_IS`, so a percent-encoded `%2E` path segment
  stays data. libcurl 8.10 and later decode it and then apply dot-segment
  removal, which turned `.segment "."` into directory navigation on the wire.
  `Target.resolve` already performs RFC 3986 dot-segment removal itself.

### Compatibility

- Additive except for `Error.Kind`, which gained two cases; exhaustive matches
  over it need updating. libcurl without WebSocket support keeps serving every
  HTTP request and degrades to the typed `.websocketUnsupported` error.
- Building LeanHttp now resolves one dependency, leanws `v0.1.0`, from
  https://github.com/theoriclabs/leanws. Consumers pin leanhttp as before.
- The package version and default user agent are now `0.4.0` and
  `leanhttp/0.4.0`.

## [0.3.1] - 2026-09-05

### Fixed

- `Request.segment` and `Target.segment` encode literal `.` and `..` values as
  path data. Previously, resolution or libcurl could interpret a dynamic
  identifier as current- or parent-directory navigation.
- Relative target serialization preserves relative meaning for first segments
  containing `:`, leading empty segments, and an appended empty segment. It adds
  a dot prefix when needed instead of producing an absolute or scheme-relative
  reference, or dropping the distinction between an empty segment and no path.
- Relative fragments are percent-encoded on serialization, so spaces, `#`,
  Unicode, and literal percent characters round-trip through target parsing.
- `Target.resolve` removes literal dot segments from absolute target paths,
  matching its behavior for nonempty relative paths and preserving encoded dots.

### Compatibility

- Public API signatures are unchanged. For intentional directory navigation,
  use reference syntax such as `target!"../users"`; `.segment ".."` now always
  supplies a literal path segment.
- The package version and default user agent are now `0.3.1` and `leanhttp/0.3.1`.

## [0.3.0] - 2026-09-05

### Added

- Inductive absolute/relative `Target` values, `RelativeRef`, checked `target!`
  literals, dynamic target parsing, and pure resolution with typed errors.
- Relative paths, directory merging, dot-segment removal, and explicit omitted
  versus empty query semantics for session base URIs.
- `requestAsync` and `requestAsAsync` integration with `Std.Async`, using a
  dedicated worker and session for each one-shot request.
- `requestAsTask` and bounded batch APIs: `requestManyTask`, `requestManyAsTask`,
  `requestManyAsync`, and `requestManyAsAsync`.
- A strictly positive `Concurrency` type and `Batch.Config`. Batch workers reuse
  their own sessions, consume a shared queue, and preserve input result order.
- Optional session configuration for `request`, `requestAs`, and `requestTask`.
- A design proposal covering target semantics, async scheduling, ownership,
  timeout behavior, cancellation limits, and future backend choices.
- Regression tests for target resolution, async overlap, concurrency bounds,
  connection reuse, result ordering, independent failure handling, and loader
  failures in batches.

### Changed

- `Request.uri` now has type `Target`. Existing URI arguments coerce to
  `.absolute`; code inspecting the field must handle the two target cases or
  resolve it first. `Response.effectiveUri` remains a `Std.Http.URI`.
- Request constructors and URI-taking request helpers accept `Target`.
- Absolute requests must have an HTTP(S) scheme, authority, and an empty or
  slash-prefixed path. They no longer inherit the base merely because an
  authority was absent. Use an explicit
  relative target for base-URI requests. Scheme-relative `//host/path` targets
  are rejected; changing authority requires an explicit absolute URI.
- The package version and default user agent are now `0.3.0` and `leanhttp/0.3.0`.

### Async behavior

- Transfers use blocking libcurl on dedicated threads. Async waits suspend
  through Lean's task scheduler; batches bound worker threads and sessions.
- Timeouts start at transfer execution, excluding batch queue time.
- Dropping a task or abandoning an async branch does not cancel a transfer.
  Workers close their sessions after completion or timeout. Persistent pools,
  streaming, and transfer cancellation are deferred.

## [0.2.0] - 2026-09-05

### Added

- Composable request constructors for GET, POST, PUT, PATCH, DELETE, and HEAD,
  with JSON, authentication, header, path-segment, and query-parameter helpers.
- `Body.ofJson` and `Request.json` for values with `Lean.ToJson` instances.
- Compile-time checked `uri!`, `headerName!`, and `headerValue!` literals,
  enabled by opening `LeanHttp` or its scoped syntax.
- `Session.requestAs` and `LeanHttp.requestAs` for decoding fully configured
  requests, plus `Response.decodeAs` for existing responses.
- `ToBody` instances for `Body` and `Unit`, allowing explicit bodies and empty
  payloads in `Session.exchange`.
- `LeanHttp.packageVersion`, used in the default user agent.
- Regression coverage for checked literals, query encoding, method preservation,
  typed request settings, decoding failures, and session reuse.

### Fixed

- Requests with a GET method and a body now reach the server as GET, preserving
  the payload. Previously, setting the body caused libcurl to send POST.
- Supplying a body to HEAD no longer changes the method to POST or enables
  response-body downloads. libcurl's HEAD behavior does not send that payload.
- The new query helper preserves literal `+` characters in names and values,
  working around the query-encoding behavior in Lean 4.33.0. Repeated parameters
  retain their order.

### Changed

- `Session.getAs` and `Session.exchange` share the same status and decoding
  implementation as `Session.requestAs`, preserving their existing signatures.
- The default user agent is now `leanhttp/0.2.0`.
- `Session.Config.userAgent` and `Opt.userAgent` now require a validated
  `Std.Http.Header.Value` instead of `String`. Migrate custom agents to
  `headerValue!"my-client/1.0"`; validate dynamic values with
  `Std.Http.Header.Value.ofString?`. This excludes CR, LF, and NUL before the FFI.
- Installation examples pin the release tag instead of `main`.

## 0.1.0 - 2026-09-02

Initial source version; no GitHub release was published for this version.

- Synchronous libcurl client, reusable sessions, validated `Std.Http` types,
  typed transport errors, body codecs, TLS, authentication, proxies, redirects,
  timeouts, response limits, and dedicated request tasks.
- In-process HTTP and library-loader failure test suites.

[Unreleased]: https://github.com/theoriclabs/leanhttp/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/theoriclabs/leanhttp/releases/tag/v0.3.1
[0.3.0]: https://github.com/theoriclabs/leanhttp/releases/tag/v0.3.0
[0.2.0]: https://github.com/theoriclabs/leanhttp/releases/tag/v0.2.0
