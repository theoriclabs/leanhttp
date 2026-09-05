import LeanHttp

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
