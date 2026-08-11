import MetaCodesControl.ProjectHarness
import MetaCodesControl.RuleImpactGovernance

open MetaCodesControl.ProjectHarness

def maxSingleInputBytes : Nat := 128 * 1024
def maxInputBytes : Nat := 4 * 1024 * 1024

partial def readBounded (stream : IO.FS.Stream) (acc : ByteArray := .empty) : IO String := do
  let remaining := maxInputBytes + 1 - acc.size
  let chunk ← stream.read (USize.ofNat (min 4096 remaining))
  let bytes := acc ++ chunk
  if bytes.size > maxInputBytes then
    throw <| IO.userError "project harness request exceeds 4MiB"
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
  match decodeCanonicalBatchRequest input with
  | .ok requests =>
      IO.println (batchVerdictJson requests)
      pure 0
  | .error batchMessage =>
      if input.toUTF8.size > maxSingleInputBytes then
        IO.eprintln "invalid project harness request: single request exceeds 128KiB"
        pure 64
      else
        match decodeCanonicalRequest input with
        | .ok request =>
            IO.println (verdictJson request)
            pure 0
        | .error message =>
            match MetaCodesControl.RuleImpactGovernance.decodeCanonicalRequest input with
            | .ok request =>
                IO.println (MetaCodesControl.RuleImpactGovernance.verdictJson request)
                pure 0
            | .error impactMessage =>
                IO.eprintln s!"invalid project harness request: {message}; batch: {batchMessage}; impact: {impactMessage}"
                pure 64
