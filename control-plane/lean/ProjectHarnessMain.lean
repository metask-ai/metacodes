import MetaCodesControl.ProjectHarness

open MetaCodesControl.ProjectHarness

def maxInputBytes : Nat := 128 * 1024

partial def readBounded (stream : IO.FS.Stream) (acc : ByteArray := .empty) : IO String := do
  let remaining := maxInputBytes + 1 - acc.size
  let chunk ← stream.read (USize.ofNat (min 4096 remaining))
  let bytes := acc ++ chunk
  if bytes.size > maxInputBytes then
    throw <| IO.userError "project harness request exceeds 128KiB"
  if chunk.isEmpty then
    match String.fromUTF8? bytes with
    | some input => pure input
    | none => throw <| IO.userError "project harness request is not UTF-8"
  else
    readBounded stream bytes

def main (args : List String) : IO UInt32 := do
  if !args.isEmpty then
    IO.eprintln "metacodes-project-kernel reads one canonical JSON request from stdin"
    return 64
  let input ← readBounded (← IO.getStdin)
  match decodeCanonicalRequest input with
  | .error message =>
      IO.eprintln s!"invalid project harness request: {message}"
      pure 64
  | .ok request =>
      IO.println (verdictJson request)
      pure 0
