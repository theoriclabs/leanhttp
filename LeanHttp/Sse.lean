import LeanHttp.Request
import LeanHttp.Codec
import LeanHttp.Async
import LeanHttp.Syntax

namespace LeanHttp.Sse

open Std.Http

/-- A complete Server-Sent Event dispatched on a blank line. -/
structure Event where
  /-- The event type (`event:` field), defaulting to `"message"`. -/
  event : String := "message"
  /-- The event payload (`data:` lines joined with `\n`). -/
  data : String := ""
  /-- The last event ID (`id:` field), if set and containing no NUL. -/
  id : Option String := none
  /-- Reconnection time in milliseconds (`retry:` field), if a valid ASCII integer. -/
  retry : Option Nat := none
  deriving Repr, BEq, Inhabited

/-- Incremental WHATWG Server-Sent Events parser. Lines are buffered as raw bytes
    until `\r`, `\n`, or `\r\n`, so multi-byte UTF-8 code points split across
    network chunks are reassembled before UTF-8 validation. -/
structure Parser where
  private lineBuffer : ByteArray := ByteArray.empty
  private pendingCR : Bool := false
  private started : Bool := false
  private eventType : String := ""
  private dataLines : Array String := #[]
  private lastEventId : Option String := none
  private retry : Option Nat := none
  deriving Inhabited

private def processLine (p : Parser) (rawLine : ByteArray) : Except String (Parser × Option Event) := do
  let some decoded := String.fromUTF8? rawLine
    | throw "SSE stream is not valid UTF-8"
  let isFirstLine := !p.started
  let mut p := { p with started := true }
  let line :=
    if isFirstLine && decoded.startsWith "\uFEFF" then
      (decoded.drop 1).toString
    else
      decoded
  if line.isEmpty then
    if p.dataLines.isEmpty then
      return ({ p with eventType := "", retry := none }, none)
    else
      let ev : Event := {
        event := if p.eventType.isEmpty then "message" else p.eventType
        data  := String.intercalate "\n" p.dataLines.toList
        id    := p.lastEventId
        retry := p.retry
      }
      return ({ p with eventType := "", dataLines := #[], retry := none }, some ev)
  else if line.startsWith ":" then
    return (p, none)
  else
    let (field, value) := match line.splitOn ":" with
      | [] => ("", "")
      | [f] => (f, "")
      | f :: rest =>
        let rawVal := String.intercalate ":" rest
        let val := if rawVal.startsWith " " then (rawVal.drop 1).toString else rawVal
        (f, val)
    match field with
    | "event" => p := { p with eventType := value }
    | "data"  => p := { p with dataLines := p.dataLines.push value }
    | "id"    =>
      unless value.contains '\x00' do
        p := { p with lastEventId := some value }
    | "retry" =>
      if !value.isEmpty && value.all Char.isDigit then
        p := { p with retry := value.toNat? }
    | _ => pure ()
    return (p, none)

/-- Feed a raw byte chunk into `p`, returning the updated parser and all complete
    events dispatched by blank lines in the chunk. -/
def Parser.feed (p : Parser) (chunk : ByteArray) : Except String (Parser × Array Event) := do
  let mut p := p
  let mut events : Array Event := #[]
  for i in [0:chunk.size] do
    let b := chunk.get! i
    if p.pendingCR then
      p := { p with pendingCR := false }
      if b == 0x0A then
        continue
    if b == 0x0D then
      let (nextP, ev?) ← processLine { p with lineBuffer := ByteArray.empty, pendingCR := true } p.lineBuffer
      p := nextP
      if let some ev := ev? then events := events.push ev
    else if b == 0x0A then
      let (nextP, ev?) ← processLine { p with lineBuffer := ByteArray.empty } p.lineBuffer
      p := nextP
      if let some ev := ev? then events := events.push ev
    else
      p := { p with lineBuffer := p.lineBuffer.push b }
  return (p, events)

/-- Validate any trailing buffered bytes at end-of-stream. Per the WHATWG SSE
    specification, an incomplete event without a trailing blank line is discarded. -/
def Parser.finish (p : Parser) : Except String Unit := do
  if !p.lineBuffer.isEmpty then
    let some _ := String.fromUTF8? p.lineBuffer
      | throw "SSE stream is not valid UTF-8"
  return ()

end LeanHttp.Sse

namespace LeanHttp

open Std.Http

private def ensureAcceptEventStream (sessionHeaders : Headers) (request : Request) : Request :=
  if request.headers.contains Header.Name.accept || sessionHeaders.contains Header.Name.accept then
    request
  else
    request.header Header.Name.accept (Header.Value.ofString! "text/event-stream")

/-- Execute a Server-Sent Events request on `session`, invoking `onEvent` for
    each complete `Sse.Event` on a 2xx response. Non-2xx responses do not invoke
    `onEvent` and instead return `.status response` with the buffered response
    body. Invalid UTF-8 in a 2xx stream returns `.decode message response`. -/
def Session.requestSse (session : Session) (request : Request)
    (onEvent : Sse.Event → IO Unit) : IO (Outcome Unit) := do
  let request := ensureAcceptEventStream session.config.headers request
  let parserRef ← IO.mkRef ({} : Sse.Parser)
  let decodeErrRef ← IO.mkRef (none : Option String)
  let errorBodyRef ← IO.mkRef ByteArray.empty
  let result ← session.requestStream request fun chunk => do
    let code ← session.responseCode
    if 200 ≤ code && code < 300 then
      if (← decodeErrRef.get).isNone then
        let currentParser ← parserRef.get
        match currentParser.feed chunk with
        | .error msg => decodeErrRef.set (some msg)
        | .ok (nextParser, events) =>
          parserRef.set nextParser
          for ev in events do
            onEvent ev
    else if code ≥ 300 || code < 200 then
      errorBodyRef.modify (· ++ chunk)
  match result with
  | .error err => return .transport err
  | .ok response =>
    if !response.isSuccess then
      let body ← errorBodyRef.get
      return .status { response with body }
    else
      if let some msg ← decodeErrRef.get then
        return .decode msg response
      let finalParser ← parserRef.get
      match finalParser.finish with
      | .error msg => return .decode msg response
      | .ok () => return .ok () response

/-- Execute a Server-Sent Events request using a fresh session. -/
def requestSse (request : Request) (config : Session.Config := {})
    (onEvent : Sse.Event → IO Unit) : IO (Outcome Unit) := do
  match ← Session.new config with
  | .error e => return .transport e
  | .ok session =>
      let outcome ← session.requestSse request onEvent
      session.close
      return outcome

/-- Start a Server-Sent Events request on a dedicated worker thread. -/
def requestSseTask (request : Request) (config : Session.Config := {})
    (onEvent : Sse.Event → IO Unit) : BaseIO (Task (Outcome Unit)) := do
  let task ← IO.asTask (LeanHttp.requestSse request config onEvent) Task.Priority.dedicated
  return task.map fun
    | .ok outcome => outcome
    | .error e => .transport (Error.fromIO e)

/-- Await a Server-Sent Events request on a dedicated worker thread. -/
def requestSseAsync (request : Request) (config : Session.Config := {})
    (onEvent : Sse.Event → IO Unit) : Std.Async.Async (Outcome Unit) := do
  let task ← requestSseTask request config onEvent
  Std.Async.Async.ofTask task

end LeanHttp
