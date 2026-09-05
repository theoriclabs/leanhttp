import LeanHttp
import Std.Http.Server

open LeanHttp Std.Http Std.Async

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError s!"FAIL: {message}"

private structure Info where
  id : String
  peer : String
  header : String
  authorization : String
  body : String
  deriving Lean.ToJson, Lean.FromJson, Inhabited

private structure Probe where
  active : Nat := 0
  peak : Nat := 0
  gate : Option (IO.Promise Unit) := none

private def response (status : Status) (text : String) :
    ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  let result ← (Std.Http.Response.withStatus status).headers .empty |>.fromBytes text.toUTF8
  return result

private def handler (probe : Std.Mutex Probe) (request : Std.Http.Request Std.Http.Body.Stream) :
    ContextAsync (Std.Http.Response Std.Http.Body.Any) := do
  match request.line.uri.path.toDecodedSegments.toList with
  | ["status"] => response .serviceUnavailable "not JSON"
  | ["bad-json"] => response .ok "not JSON"
  | ["timeout"] =>
      Std.Async.sleep 100
      response .ok "late"
  | [mode, id] =>
      let (active, gate) ← probe.atomically do
        let state ← getThe Probe
        let active := state.active + 1
        set { state with active, peak := max active state.peak }
        return (active, state.gate)
      try
        if mode == "gate" then
          if let some gate := gate then
            if active ≥ 2 then gate.resolve ()
            -- Two transfers must enter the server before either can finish.
            Std.Async.Async.ofTask gate.result!
        Std.Async.sleep (Std.Time.Millisecond.Offset.ofNat ((id.toNat?.getD 0 % 3) * 5))
        let body : ByteArray ← Std.Http.Body.Stream.readAll request.body
        let info : Info := {
          id
          peer := (request.extensions.get Server.RemoteAddr).map toString |>.getD ""
          header := (request.line.headers.get? headerName!"X-Client").map toString |>.getD ""
          authorization := (request.line.headers.get? Header.Name.authorization).map toString |>.getD ""
          body := (String.fromUTF8? body).getD "<binary>" }
        response .ok (Lean.toJson info).compress
      finally
        probe.atomically do modify fun state => { state with active := state.active - 1 }
  | _ => response .notFound "missing"

private def req (path : String) : LeanHttp.Request := {
  uri := (Target.parse? path).get!
  timeouts := { total := 2000 }
}

private def expectInfo (outcome : Outcome Info) : IO Info :=
  match outcome with
  | .ok info _ => pure info
  | .status raw => throw <| IO.userError s!"unexpected status {raw.statusCode}"
  | .decode message _ => throw <| IO.userError s!"decode: {message}"
  | .transport error => throw <| IO.userError s!"transport: {error}"

def main : IO UInt32 := do
  let probe ← Std.Mutex.new ({} : Probe)
  let address : Std.Net.SocketAddress := .v4 {
    addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port := 0 }
  let server ← Async.block <|
    Server.serve address (Server.Handler.ofFn (handler probe)) { generateDate := false }
  try
    let some bound := server.localAddr | throw <| IO.userError "no server address"
    let config : Session.Config := {
      baseUri := some (URI.parse! s!"http://127.0.0.1:{bound.port}/api/index")
      headers := Headers.empty.insert headerName!"X-Client" headerValue!"shared"
      httpVersion := .http11 }

    let gate ← IO.Promise.new
    probe.atomically do set ({ gate := some gate } : Probe)
    let (first, second) : Outcome Info × Outcome Info ← Async.block <|
      Async.concurrently
        (requestAsAsync (req "../gate/0") config)
        (requestAsAsync (req "/gate/1") config)
    let first ← expectInfo first
    let second ← expectInfo second
    check (first.id == "0" && second.id == "1" && first.header == "shared")
      "async one-shot results and relative base configuration"
    check ((← probe.atomically (getThe Probe)).peak == 2)
      "async one-shot requests overlap without blocking the scheduler"

    let gate ← IO.Promise.new
    probe.atomically do set ({ gate := some gate } : Probe)
    let requests := (List.range 8).toArray.map fun i => req s!"/gate/{i}"
    let outcomes : Array (Outcome Info) ← Async.block <|
      requestManyAsAsync requests { concurrency := 2, session := config }
    let values ← outcomes.mapM expectInfo
    check (values.map (·.id) == (List.range 8).toArray.map toString) "batch input order"
    check (values.all (·.header == "shared")) "batch session configuration"
    check ((← probe.atomically (getThe Probe)).peak == 2) "batch concurrency limit and overlap"
    let peers := values.map (·.peer) |>.toList.eraseDups
    check (peers.length == 2 && !peers.contains "") "batch workers reuse two TCP connections"

    probe.atomically do set ({} : Probe)
    let sequential := (List.range 5).toArray.map fun i =>
      let request := req s!"/item/{i}"
      if i == 0 then request.bearer "first" |>.json (Lean.Json.str "payload") else request
    let task ← requestManyAsTask (α := Info) sequential { concurrency := 1, session := config }
    let values ← (← IO.wait task).mapM expectInfo
    check ((← probe.atomically (getThe Probe)).peak == 1) "single-worker batch is serial"
    check ((values.map (·.peer) |>.toList.eraseDups).length == 1) "single-worker connection reuse"
    check (values[0]!.authorization == "Bearer first" && values[0]!.body == "\"payload\"")
      "typed async request auth and body"
    check ((values.toList.drop 1).all (fun value => value.authorization.isEmpty && value.body.isEmpty))
      "batch session reset does not leak auth or bodies"

    let mixed : Array (Outcome Info) ← Async.block <| requestManyAsAsync #[
      req "/item/ok",
      req "/status",
      req "/bad-json",
      { req "/timeout" with timeouts := { total := 10 } },
      req "/item/after"
    ] { concurrency := 1, session := config }
    let [_, status, invalid, timedOut, after] := mixed.toList
      | throw <| IO.userError "FAIL: batch lost results"
    match status with
    | .status raw => check (raw.status == .serviceUnavailable) "batch status outcome"
    | _ => throw <| IO.userError "FAIL: batch status classification"
    match invalid with
    | .decode _ raw => check (raw.status == .ok) "batch decode outcome"
    | _ => throw <| IO.userError "FAIL: batch decode classification"
    match timedOut with
    | .transport { kind := .timeout, .. } => pure ()
    | _ => throw <| IO.userError "FAIL: batch timeout classification"
    check ((← expectInfo after).id == "after") "batch continues after failed requests"

    let typedTask ← requestAsTask (α := Info) (req "/item/task") config
    check ((← expectInfo (← IO.wait typedTask)).id == "task") "typed one-shot task"
    let raw ← Async.block <| requestAsync (req "/item/raw") config
    match raw with
    | .ok result => check (result.isSuccess) "raw async request"
    | .error error => throw <| IO.userError (toString error)
    let empty ← Async.block <| requestManyAsync #[]
    check empty.isEmpty "empty async batch"
  finally
    if let some gate := (← probe.atomically (getThe Probe)).gate then gate.resolve ()
    Async.block server.shutdownAndWait
  IO.println "LeanHttp async tests passed"
  return 0
