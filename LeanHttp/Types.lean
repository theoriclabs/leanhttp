import Std.Http
import LeanHttp.Target
import Std.Time
import Lean

namespace LeanHttp

open Std.Http

/-- A request body whose media type cannot drift away from its bytes. -/
inductive Body where
  | empty
  | bytes (contentType : Header.Value) (data : ByteArray)
  | text (contentType : Header.Value) (data : String)
  | json (data : Lean.Json)
  | form (fields : List (String × String))

inductive Redirects where
  | never
  | upTo (n : Nat)
  deriving Repr

inductive Tls where
  | system
  | bundle (caInfo : System.FilePath)
  | mutual (caInfo : Option System.FilePath) (cert key : System.FilePath)
  | insecureNoVerify
  deriving Repr

inductive Auth where
  | none
  | basic (user password : String)
  | bearer (token : String)
  deriving Repr

structure Timeouts where
  connect : Std.Time.Millisecond.Offset := .ofNat 10000
  total : Std.Time.Millisecond.Offset := .ofNat 30000
  deriving Repr

inductive Encoding where
  | identity
  | gzip
  | any
  deriving Repr

inductive HttpVersion where
  | default
  | http11
  | http2
  | http2Tls
  deriving Repr

structure Request where
  method : Method := .get
  uri : Target
  headers : Headers := .empty
  body : Body := .empty
  redirects : Redirects := .upTo 10
  timeouts : Timeouts := {}
  auth : Auth := .none

structure Response where
  status : Status
  headers : Headers
  body : ByteArray
  effectiveUri : URI

def Response.statusCode (r : Response) : UInt16 := r.status.toCode

def Response.isSuccess (r : Response) : Bool :=
  let n := r.statusCode
  200 ≤ n && n < 300

end LeanHttp
