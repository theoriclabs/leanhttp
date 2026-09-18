import LeanHttp
import LeanWs

open LeanHttp Std.Http

-- These are compile-time checks; importing this module runs them during lake test.
#guard toString uri!"https://example.com/users" == "https://example.com/users"
#guard headerName!"X-Trace" == headerName!"x-trace"
#guard toString headerValue!"application/json" == "application/json"

/-- error: invalid URI literal -/
#guard_msgs in
#check uri!"https://bad host/"

/-- error: invalid header name literal -/
#guard_msgs in
#check headerName!"bad:name"

/-- error: invalid header value literal -/
#guard_msgs in
#check headerValue!"ok\r\nInjected: yes"

-- Session options reuse the same validated domain type as request headers.
example : Session.Config := { userAgent := headerValue!"my-client/1.0" }
#guard (Header.Value.ofString? "client\u0000suffix").isNone

private def queryRoundTrip (value : String) : Bool :=
  let request := (LeanHttp.Request.get uri!"https://example.com").param value value
  match request.uri.query.toArray[0]? with
  | some (name, some encoded) => name.decode == some value && encoded.decode == some value
  | _ => false

-- Test raw inputs, including every ASCII byte and multi-byte UTF-8. '%' must not
-- be interpreted as a pre-existing escape, nor '+' confused with a space.
#guard (List.range 128).all (fun n => queryRoundTrip (String.singleton (Char.ofNat n)))
#guard ["a+b c&d=e", "%2B", "", "café / 東京 😀"].all queryRoundTrip

#guard toString ((LeanHttp.Request.get uri!"https://example.com/users")
  |>.segment "a/b"
  |>.param "q" "a+b c&d=e").uri ==
  "https://example.com/users/a%2Fb?q=a%2Bb+c%26d%3De"

#guard toString ((LeanHttp.Request.get uri!"https://example.com/").segment "users").uri ==
  "https://example.com/users"

#guard toString ((LeanHttp.Request.get uri!"https://example.com").segment "users").uri ==
  "https://example.com/users"

#guard toString ((LeanHttp.Request.get uri!"https://example.com?tag=first")
  |>.param "tag" "second"
  |>.param "tag" "third").uri ==
  "https://example.com?tag=first&tag=second&tag=third"

private def headersRequest : LeanHttp.Request :=
  (LeanHttp.Request.get uri!"https://example.com")
    |>.addHeader headerName!"X-Trace" headerValue!"old"
    |>.addHeader headerName!"X-Trace" headerValue!"older"
    |>.header headerName!"X-Trace" headerValue!"new"
    |>.addHeader headerName!"X-Trace" headerValue!"last"

#guard (headersRequest.headers.getAll? headerName!"x-trace").map
  (fun values => values.map toString) == some #["new", "last"]

-- JSON encoding stays explicit for types that also have other body codecs.
#guard match Body.ofJson "hello" with
  | .json json => json.compress == "\"hello\""
  | _ => false

#guard match ToBody.toBody "hello" with
  | .text _ text => text == "hello"
  | _ => false

private def sample (status : Status) (bytes : ByteArray) : LeanHttp.Response := {
  status, body := bytes, headers := .empty, effectiveUri := uri!"https://example.com"
}

#guard match (sample .notFound "invalid JSON".toUTF8).decodeAs (α := Lean.Json) with
  | .status response => response.status == .notFound && response.body == "invalid JSON".toUTF8
  | _ => false

#guard match (sample .ok (ByteArray.mk #[255])).decodeAs (α := String) with
  | .decode message response => !message.isEmpty && response.body == ByteArray.mk #[255]
  | _ => false

-- Typical client code elaborates with the output type inferred from Outcome.
private structure User where
  name : String
  deriving Lean.ToJson, Lean.FromJson

example (session : Session) (input : User) (token : String) : IO (Outcome User) := do
  let req := (LeanHttp.Request.post uri!"https://api.example.com/users")
    |>.json input
    |>.bearer token
  session.requestAs { req with timeouts := { total := 5000 } }

private def resolved (reference : String) : Option String := do
  let target ← Target.parse? reference
  let uri ← (target.resolve (some uri!"http://a/b/c/d;p?q")).toOption
  return toString uri

-- RFC 3986 reference-resolution cases within the supported same-authority subset.
#guard ([
  ("g", "http://a/b/c/g"), ("./g", "http://a/b/c/g"),
  ("g/", "http://a/b/c/g/"), ("/g", "http://a/g"),
  ("?y", "http://a/b/c/d;p?y"), ("g?y", "http://a/b/c/g?y"),
  ("#s", "http://a/b/c/d;p?q#s"), ("g#s", "http://a/b/c/g#s"),
  ("g?y#s", "http://a/b/c/g?y#s"), (";x", "http://a/b/c/;x"),
  ("", "http://a/b/c/d;p?q"), ("?", "http://a/b/c/d;p"),
  (".", "http://a/b/c/"), ("./", "http://a/b/c/"),
  ("..", "http://a/b/"), ("../", "http://a/b/"),
  ("../g", "http://a/b/g"), ("../..", "http://a/"),
  ("../../g", "http://a/g"), ("../../../g", "http://a/g"),
  ("/./g", "http://a/g"), ("/../g", "http://a/g"),
  ("g/./h", "http://a/b/c/g/h"), ("g/../h", "http://a/b/c/h"),
  ("g?y/../x", "http://a/b/c/g?y/../x"),
  ("g#s/../x", "http://a/b/c/g#s/../x"),
  ("%2E%2E/g", "http://a/b/c/%2E%2E/g"),
  ("http://other.example/x", "http://other.example/x")
] : List (String × String)).all (fun (input, expected) => resolved input == some expected)

#guard ((target!"g").resolve (some uri!"http://example.com")).toOption.map toString ==
  some "http://example.com/g"
#guard ((target!"/g").resolve (some uri!"http://example.com/base/")).toOption.map toString ==
  some "http://example.com/g"
#guard ((target!"g").resolve (some uri!"http://example.com/base/")).toOption.map toString ==
  some "http://example.com/base/g"
#guard ((target!"/g").resolve).toOption.isNone
#guard ((target!"/g").resolve (some uri!"http:base")).toOption.isNone
#guard ((target!"http:relative").resolve (some uri!"http://example.com")).toOption.isNone
#guard ((target!"ftp://example.com").resolve).toOption.isNone
#guard (Target.parse? "//other.example/path").isNone
#guard (Target.parse? "http://").isNone
#guard (Target.parse? "http:///path").isNone
#guard (RelativeRef.parse? "g:h").isNone

-- Std.URI validates components but permits this inconsistent combination when
-- built directly. Do not serialize it as a different host (example.comusers).
private def badAuthorityPath : URI := {
  uri!"http://example.com" with path := (target!"users").path }
#guard ((Target.absolute badAuthorityPath).resolve).toOption.isNone
#guard ((target!"").resolve (some badAuthorityPath)).toOption.isNone

/-- error: invalid request target literal -/
#guard_msgs in
#check target!"//other.example/path"

/-- error: invalid request target literal -/
#guard_msgs in
#check target!"/bad path"

#guard toString ((LeanHttp.Request.get target!"users")
  |>.segment "a/b"
  |>.param "q" "a+b").uri == "users/a%2Fb?q=a%2Bb"

-- WebSocket targets resolve with the same rules under a different scheme set.
#guard ((target!"ws://example.com/socket").resolveIn Target.webSocketSchemes).toOption.map
  toString == some "ws://example.com/socket"
#guard ((target!"socket").resolveIn Target.webSocketSchemes
  (some uri!"wss://example.com/api/index")).toOption.map toString ==
  some "wss://example.com/api/socket"
#guard ((target!"http://example.com").resolveIn Target.webSocketSchemes).toOption.isNone
#guard ((target!"ws://example.com").resolve).toOption.isNone
#guard ((target!"socket").resolveIn Target.webSocketSchemes
  (some uri!"https://example.com/api/")).toOption.isNone

-- Receive limits and close codes are leanws values, not a second vocabulary.
example : WebSocket.Options := { limits := { maxMessage := 1 <<< 16 } }
#guard (WebSocket.Options.limits {}).maxMessage == LeanWs.Limits.maxMessage {}
#guard LeanWs.CloseCode.messageTooBig.code == 1009

#guard (Concurrency.ofNat? 0).isNone
#guard (Concurrency.ofNat? 3).map (·.val) == some 3
#guard (2 : Concurrency).val == 2
example (limit : Concurrency) : limit.val ≠ 0 := by
  have := limit.positive
  omega

-- Raw appended segments are data; only literal reference syntax navigates.
#guard toString ((LeanHttp.Request.get target!"users").segment ".").uri == "users/%2E"
#guard toString ((LeanHttp.Request.get target!"users").segment "..").uri == "users/%2E%2E"
#guard (((LeanHttp.Request.get target!"users").segment "..").uri.resolve
  (some uri!"https://example.com/api/index")).toOption.map toString ==
  some "https://example.com/api/users/%2E%2E"

-- Serialization must preserve the relative case and the resolved destination,
-- including paths constructed directly from valid Std components.
private def relativeRoundTrip (reference : RelativeRef) : Bool :=
  match Target.parse? (toString reference) with
  | some (.relative parsed) =>
      let base := some uri!"https://example.com/api/index?old=1"
      ((Target.relative parsed).resolve base).toOption ==
        ((Target.relative reference).resolve base).toOption
  | _ => false

#guard (RelativeRef.parse? "users#hello%20world%23part").map relativeRoundTrip == some true
#guard (RelativeRef.parse? "#caf%C3%A9%25").map relativeRoundTrip == some true
#guard relativeRoundTrip { path := { segments := #[URI.EncodedSegment.encode "a:b"], absolute := false } }
#guard relativeRoundTrip { path := { segments := #[URI.EncodedString.empty], absolute := false } }
#guard relativeRoundTrip { path := { segments := #[URI.EncodedString.empty, URI.EncodedSegment.encode "host"], absolute := false } }
#guard relativeRoundTrip { path := { segments := #[URI.EncodedString.empty, URI.EncodedSegment.encode "host"], absolute := true } }
#guard toString ((LeanHttp.Request.get target!"").segment "a:b").uri == "./a:b"
#guard toString target!"users#hello%20world%23part" == "users#hello%20world%23part"

#guard ((target!"http://example.com/a/../b/.").resolve).toOption.map toString ==
  some "http://example.com/b/"
#guard ((target!"http://example.com/a/%2E%2E/b").resolve).toOption.map toString ==
  some "http://example.com/a/%2E%2E/b"
