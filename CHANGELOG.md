# Changelog

User-visible changes are recorded here. Versions use semantic versioning and
are published as `vX.Y.Z` Git tags and GitHub releases.

## [Unreleased]

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

[Unreleased]: https://github.com/theoriclabs/leanhttp/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/theoriclabs/leanhttp/releases/tag/v0.2.0
