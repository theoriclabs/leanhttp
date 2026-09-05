import LeanHttp.Codec
import Std.Async
import Std.Sync.Mutex
import Init.Data.Queue

namespace LeanHttp

/-- A strictly positive concurrency limit. Use numeric literals or `ofNat?`
    for a runtime count; zero cannot construct a valid limit. -/
structure Concurrency where
  val : Nat
  positive : 0 < val
  deriving Repr

instance (n : Nat) [NeZero n] : OfNat Concurrency n where
  ofNat := ⟨n, Nat.pos_of_ne_zero (NeZero.ne n)⟩

def Concurrency.ofNat? (value : Nat) : Option Concurrency :=
  if h : 0 < value then some ⟨value, h⟩ else none

/-- Batch workers each own one reusable session with these settings. -/
structure Batch.Config where
  concurrency : Concurrency := 4
  session : Session.Config := {}
  deriving Repr

/-- Await a fresh-session request without blocking the async scheduler.
    The libcurl transfer itself runs on a dedicated thread. -/
def requestAsync (request : Request) (config : Session.Config := {}) :
    Std.Async.Async (Except Error Response) := do
  let task ← requestTask request config
  Std.Async.Async.ofTask task

/-- Await a typed fresh-session request. Dropping this action does not cancel
    an in-flight libcurl transfer; configure request timeouts accordingly. -/
def requestAsAsync [FromBody α] (request : Request) (config : Session.Config := {}) :
    Std.Async.Async (Outcome α) := do
  let task ← requestAsTask request config
  Std.Async.Async.ofTask task

private abbrev Job := Nat × Request
private abbrev Result := Nat × Except Error Response

-- Keep ordinary IO failures as result values, so a worker never drops a claimed
-- request because an IO exception escaped its session operation.
private def protect (action : IO (Except Error α)) : BaseIO (Except Error α) := do
  match ← action.toBaseIO with
  | .ok result => return result
  | .error error => return .error (Error.fromIO error)

private def worker (jobs : Std.Mutex (Std.Queue Job)) (config : Session.Config) :
    BaseIO (Array Result) := do
  let session ← protect (Session.new config)
  try
    let mut results := #[]
    repeat
      let next ← jobs.atomically do
        match (← getThe (Std.Queue Job)).dequeue? with
        | none => return none
        | some (job, rest) => set rest; return some job
      match next with
      | none => break
      | some (index, request) =>
          let result ← match session with
            | .ok session => protect (session.request request)
            | .error error => pure (.error error)
          results := results.push (index, result)
    return results
  finally
    if let .ok session := session then
      discard session.close.toBaseIO

/-- Start a bounded batch. Workers take jobs from a FIFO queue and reuse their
    own sessions. Results are returned in input order after all sessions close.
    Per-request timeouts begin at execution, excluding time spent in the queue. -/
def requestManyTask (requests : Array Request) (config : Batch.Config := {}) :
    BaseIO (Task (Array (Except Error Response))) := do
  if requests.isEmpty then return Task.pure #[]
  let queue : Std.Queue Job := {
    dList := requests.toList.zipIdx.map fun (request, index) => (index, request) }
  let jobs ← Std.Mutex.new queue
  let count := min requests.size config.concurrency.val
  let workers ← (List.range count).mapM fun _ =>
    BaseIO.asTask (worker jobs config.session) Task.Priority.dedicated
  -- All workers have already started; the task chain only joins their results.
  let joined := workers.foldl (fun acc next =>
    acc.bind fun results => next.map (results ++ ·)) (Task.pure #[])
  return joined.map fun results =>
    (results.qsort (fun a b => a.1 < b.1)).map Prod.snd

/-- Start a bounded batch and decode every response independently. -/
def requestManyAsTask [FromBody α] (requests : Array Request) (config : Batch.Config := {}) :
    BaseIO (Task (Array (Outcome α))) := do
  let task ← requestManyTask requests config
  return task.map fun results => results.map fun
    | .ok response => response.decodeAs
    | .error error => .transport error

/-- Await a bounded batch without blocking the async scheduler. -/
def requestManyAsync (requests : Array Request) (config : Batch.Config := {}) :
    Std.Async.Async (Array (Except Error Response)) := do
  let task ← requestManyTask requests config
  Std.Async.Async.ofTask task

/-- Await a bounded batch of typed responses, preserving all four outcomes. -/
def requestManyAsAsync [FromBody α] (requests : Array Request) (config : Batch.Config := {}) :
    Std.Async.Async (Array (Outcome α)) := do
  let task ← requestManyAsTask requests config
  Std.Async.Async.ofTask task

end LeanHttp
