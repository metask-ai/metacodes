import MetaCodesControl.FormalKernel

open Lean
open MetaCodesControl.FormalKernel

def usage : String :=
  "metacodes-formal-kernel reads one metacodes-formal-request-v1 JSON object from stdin"

def maxInputBytes : Nat := 64 * 1024

partial def readBounded (stream : IO.FS.Stream) (acc : ByteArray := .empty) : IO String := do
  -- Read one byte beyond the protocol cap so an oversized request is rejected
  -- instead of being silently truncated into a different proposal.
  let remaining := maxInputBytes + 1 - acc.size
  let chunk ← stream.read (USize.ofNat (min 4096 remaining))
  let bytes := acc ++ chunk
  if bytes.size > maxInputBytes then
    throw <| IO.userError "formal request exceeds 64KiB"
  if chunk.isEmpty then
    match String.fromUTF8? bytes with
    | some input => pure input
    | none => throw <| IO.userError "formal request is not UTF-8"
  else
    readBounded stream bytes

def main (args : List String) : IO UInt32 := do
  if !args.isEmpty then
    IO.eprintln usage
    return 64
  let stdin ← IO.getStdin
  let input ← readBounded stdin
  match decodeRequest input with
  | .error message =>
      IO.eprintln s!"invalid formal request: {message}"
      pure 64
  | .ok request =>
      IO.println (verdictJson request)
      pure 0
