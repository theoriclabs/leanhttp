import LeanHttp.Session

namespace LeanHttp

open Lean Std.Http

class ToBody (α : Type) where
  toBody : α → Body

instance : ToBody Json := ⟨.json⟩
instance : ToBody String := ⟨.text (Header.Value.ofString! "text/plain; charset=utf-8")⟩
instance : ToBody ByteArray := ⟨.bytes (Header.Value.ofString! "application/octet-stream")⟩
instance : ToBody Body := ⟨id⟩
instance : ToBody Unit := ⟨fun _ => .empty⟩

class FromBody (α : Type) where
  fromBody : Headers → ByteArray → Except String α

instance : FromBody ByteArray := ⟨fun _ body => pure body⟩
instance : FromBody String := ⟨fun _ body =>
  match String.fromUTF8? body with
  | some s => pure s
  | none => throw "response body is not UTF-8"⟩
instance : FromBody Json := ⟨fun _ body => do
  let some text := String.fromUTF8? body | throw "JSON response is not UTF-8"
  Json.parse text⟩

def FromBody.fromJson [FromJson α] (headers : Headers) (body : ByteArray) : Except String α := do
  let json ← (FromBody.fromBody headers body : Except String Json)
  fromJson? json

/-- Decode any type with a `FromJson` instance through the JSON body codec.
    Concrete `FromBody` instances above take precedence. -/
instance (priority := low) [FromJson α] : FromBody α := ⟨FromBody.fromJson⟩

inductive Outcome (α : Type) where
  | ok (value : α) (response : Response)
  | status (response : Response)
  | decode (message : String) (response : Response)
  | transport (error : Error)

/-- Decode a successful response, retaining the raw response for HTTP status
    and decoding failures. Non-2xx responses are never passed to the codec. -/
def Response.decodeAs [FromBody α] (response : Response) : Outcome α :=
  if !response.isSuccess then .status response
  else match FromBody.fromBody response.headers response.body with
    | .ok value => .ok value response
    | .error message => .decode message response

/-- Execute a fully configured request and decode its successful response. -/
def Session.requestAs [FromBody α] (session : Session) (request : Request) : IO (Outcome α) := do
  match ← session.request request with
  | .error e => return .transport e
  | .ok response => return response.decodeAs

/-- Execute and decode a single request using a fresh session. -/
def requestAs [FromBody α] (request : Request) (config : Session.Config := {}) : IO (Outcome α) := do
  match ← LeanHttp.request request config with
  | .error e => return .transport e
  | .ok response => return response.decodeAs

def Session.exchange [ToBody β] [FromBody α] (session : Session) (method : Method)
    (uri : Target) (payload : β) (headers : Headers := .empty) : IO (Outcome α) :=
  session.requestAs { method, uri, headers, body := ToBody.toBody payload }

def Session.getAs [FromBody α] (session : Session) (uri : Target)
    (headers : Headers := .empty) : IO (Outcome α) :=
  session.requestAs { uri, headers }

/-- Start a typed one-shot request on its own dedicated worker and session. -/
def requestAsTask [FromBody α] (request : Request) (config : Session.Config := {}) :
    BaseIO (Task (Outcome α)) := do
  let task ← requestTask request config
  return task.map fun
    | .error error => .transport error
    | .ok response => response.decodeAs

end LeanHttp
