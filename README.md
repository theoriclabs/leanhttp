# LeanHttp

A synchronous HTTP client for Lean 4 backed by libcurl through a small C FFI.
The public API reuses `Std.Http`'s validated methods, URIs, headers, and
statuses. HTTP error statuses are ordinary responses; transport failures have
typed, stable categories.

```toml
[[require]]
name = "leanhttp"
git = "https://github.com/theoriclabs/leanhttp"
rev = "main"
```

```lean
import LeanHttp

open LeanHttp Std.Http

def main : IO Unit := do
  let some uri := URI.parse? "https://example.com" | throw <| IO.userError "bad URL"
  match ← LeanHttp.get uri with
  | .ok response => IO.println s!"{response.statusCode}: {response.body.size} bytes"
  | .error error => throw <| IO.userError (toString error)
```

`Session` reuses one libcurl easy handle, so connections stay alive across
requests. It supports timeouts, bounded response bodies, redirects, TLS policy,
basic and bearer authentication, proxies, compression, binary/text/JSON/form
bodies, typed body codecs, and one-session-per-task concurrency.

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
