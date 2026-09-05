# Typed request targets and asynchronous execution

Status: accepted and implemented for LeanHttp 0.3.0.

## Problem and existing foundation

LeanHttp 0.2.0 already provides `Session.requestAs`, explicit `ToJson` body
encoding, checked URI/header literals, composable request helpers, and fixes for
GET bodies and query `+` encoding. This proposal completes the request-target
part of that design and defines asynchronous execution over the same request
and result types.

Two gaps remain. `Request.uri` cannot represent `/users` without inventing a
scheme, while the session resolver guesses whether an absolute URI should use
the base. Separately, `requestTask` offers one-shot concurrency but no
`Std.Async` integration, session configuration, typed task results, or bounded
batch execution.

## Types and invariants

Introduce an inductive `Target` with `absolute URI` and `relative RelativeRef`
cases. `RelativeRef` contains a validated `URI.Path`, an optional `URI.Query`,
and an optional fragment. `none` and `some .empty` queries have different
meanings: an omitted query can inherit the base query, while an empty query
clears it. A relative reference cannot supply a scheme or authority.

`Request.uri` becomes `Target`. A coercion from `URI` keeps existing literal
and parsed-URI call sites working. `target!"/users"` checks a target at compile
time; `Target.parse?` handles dynamic strings. `uri!` continues to produce
`Std.Http.URI`. Direct users of the `Request.uri` field must account for its
two cases; `Response.effectiveUri` remains the resolved `URI`.

Resolution is pure and returns an inductive error. Absolute HTTP(S) targets
require an authority and an empty or slash-prefixed path, and do not inherit
anything from the base. Relative targets require an absolute HTTP(S) base.
A leading slash replaces the path;
other paths merge with the base directory. Dot segments are removed while
preserving directory endings. Empty paths inherit the base path and, only when
the query is omitted, its query. Fragments are never inherited.

For example, with base `https://api.example.com/v1/index?old=1`:

| Target | Resolved URI |
| --- | --- |
| `users` | `https://api.example.com/v1/users` |
| `/users` | `https://api.example.com/users` |
| `../users` | `https://api.example.com/users` |
| `?page=2` | `https://api.example.com/v1/index?page=2` |
| `?` | `https://api.example.com/v1/index` |
| empty reference | `https://api.example.com/v1/index?old=1` |

Scheme-relative references such as `//other.example/path` are rejected. Use an
explicit absolute URL to change authority. This is a deliberate subset of
[RFC 3986 reference resolution](https://www.rfc-editor.org/rfc/rfc3986.html#section-5.2).
Std's URI representation does not retain an empty query delimiter after
resolution; the optional query in `RelativeRef` controls inheritance.

Request configuration continues to use Lean fields and domain types: `Body`,
`Auth`, `Redirects`, `Tls`, validated headers, and time units. We will not add
string-keyed configuration. The types should express rules, not merely rename
strings. JSON member names supplied by an external API remain serialized data.

## Async API

Add these entry points, all using the existing `Request` and `Outcome α`:

```text
requestTask       : Request → Session.Config → BaseIO (Task (Except Error Response))
requestAsTask     : Request → Session.Config → BaseIO (Task (Outcome α))
requestAsync      : Request → Session.Config → Std.Async.Async (Except Error Response)
requestAsAsync    : Request → Session.Config → Std.Async.Async (Outcome α)
requestManyAsync  : Array Request → Batch.Config → Std.Async.Async (Array (Except Error Response))
requestManyAsAsync: Array Request → Batch.Config → Std.Async.Async (Array (Outcome α))
```

`requestManyTask` and `requestManyAsTask` expose the batch results as `Task`s too.
Configuration parameters have defaults. The one-shot synchronous `request` and
`requestAs` functions accept the same optional session configuration. The old
single-argument `requestTask` call remains valid.

`Batch.Config` contains a session configuration and a strictly positive
`Concurrency` value, defaulting to four. Numeric literals are convenient, while
zero is rejected by the type system. Dynamic counts use a checked constructor.

### Execution and ownership

The current transport is blocking `curl_easy_perform`. Run it on dedicated
Lean worker threads and await their `Task`s through `Std.Async.Async.ofTask`.
Async continuations must never call `Task.get` on pending work or lift a
blocking `Session.request` directly into `Async`.

A one-shot task owns one fresh session from creation through cleanup. A batch
starts at most `min(concurrency, request count)` dedicated workers. Each worker
owns and reuses one session, taking the next request from a shared FIFO queue.
The mutex protects only queue access, never network IO. All workers finish and
close their sessions before the batch returns. Results remain in input order,
including status, decoding, and transport failures. Empty batches create no
sessions or threads; failures do not cancel other requests.

There is intentionally no `Session.requestAsync` method: the public synchronous
session can be aliased and closed, so spawning background access to its easy
handle would permit races. libcurl requires exclusive handle use, as explained
in its [thread-safety documentation](https://curl.se/libcurl/c/threadsafe.html).

### Timing, cancellation, and limits

A task starts when its `BaseIO` action runs; an `Async` action starts when it is
executed. A request's connect and total timeouts start when its worker begins
the transfer. Queueing time is not included. Batch memory scales with the input
and collected responses, while blocking worker threads and sessions are bounded.

There is no transfer cancellation API in this release. Dropping a task,
abandoning an `Async` branch, or cancelling a surrounding context does not abort
an in-flight libcurl operation. The worker retains ownership and eventually
closes its session after completion or its configured timeout. Zero total
timeouts can therefore leave work running indefinitely. We must not claim
that `IO.cancel` can interrupt C network IO.

For large persistent workloads, a future client can use libcurl's
[multi interface](https://curl.se/libcurl/c/libcurl-multi.html), with explicit
admission, cancellation, shutdown, and connection-pool ownership. That is a
separate backend decision; this release promises thread-backed async IO.

## Compatibility and deferred work

- The existing JSON/body/literal helpers and four `Outcome` cases remain.
- URI arguments coerce to absolute targets; relative references use `target!`
  or `.relative`. Reading `Request.uri` now yields `Target`.
- Absolute URIs without an HTTP(S) scheme and authority are rejected before
  transfer. The old authority-based base-URI guessing is removed.
- `Endpoint Input Output` remains deferred until concrete SDK clients establish
  its encoding, decoding, and status-policy requirements.
- Streaming bodies, persistent async pools, retries, cancellation, and typed
  endpoint definitions are outside this proposal's implementation scope.

## Validation and release

Test literal rejection, relative resolution (including empty queries and dot
segments), dynamic count rejection, compatibility with URI call sites, and
request helper behavior for both target cases. Test sync and async requests
against the local server with configured bases, authentication, headers,
timeouts, status failures, and decoding failures. Use server-side counters and
gates to check overlap and the concurrency bound without wall-clock speed
assertions. Check result order and session reuse, and extend forced loader
failure coverage to async batches. Compile README and proposal examples.

Maintain `CHANGELOG.md`, document migration and async limitations, bump to
0.3.0, and publish the tested commit following `RELEASING.md`.
