namespace RpgmDecrypt.Tests

open System
open System.Collections.Generic

/// Minimal in-process test runner.
///
/// We avoid `xUnit`/`NUnit` dependencies because the package versions
/// that ship with .NET 10 currently have binding conflicts (see the
/// project history). The whole runner is <100 LoC and sufficient for
/// the unit + golden-fixture + end-to-end tests we need for v0.x.
module TestFramework =

    type Test =
        { Name : string
          Body : unit -> unit }

    let private registry = List<Test>()

    let register (name: string) (body : unit -> unit) =
        lock registry (fun () ->
            printfn "  [register] %s" name
            registry.Add({ Name = name; Body = body }))

    let snapshot () : Test list =
        lock registry (fun () -> registry |> List.ofSeq)

    let mutable total   = 0
    let mutable passed  = 0
    let mutable failed  = 0
    let private failures = List<string * string>()

    let assertionFailed (msg: string) =
        raise (InvalidOperationException ("ASSERT_FAILED: " + msg))

    let consoleColor (c: ConsoleColor) (s: string) =
        let prev = Console.ForegroundColor
        Console.ForegroundColor <- c
        try printfn "%s" s
        finally Console.ForegroundColor <- prev

    let assertEqual<'a when 'a : equality> (label: string)
                    (expected: 'a) (actual: 'a) =
        total <- total + 1
        if expected = actual then
            passed <- passed + 1
        else
            failed <- failed + 1
            failures.Add(label, sprintf "expected %A, got %A" expected actual)

    let assertByteEqual (label: string) (expected: byte[]) (actual: byte[]) =
        total <- total + 1
        if expected = actual then
            passed <- passed + 1
        else
            // Exactly one failure entry per failed assertion (counter never
            // desyncs from the failures list — was: 0 entries on a length
            // mismatch with equal prefix, or N entries for N differing bytes).
            failed <- failed + 1
            if expected.Length <> actual.Length then
                failures.Add(label,
                    sprintf "length differs: expected %d bytes, got %d" expected.Length actual.Length)
            else
                let mutable firstDiff = -1
                let mutable i = 0
                while firstDiff < 0 && i < expected.Length do
                    if expected.[i] <> actual.[i] then firstDiff <- i
                    i <- i + 1
                failures.Add(label,
                    sprintf "byte %d differs: expected %02x got %02x"
                        firstDiff expected.[firstDiff] actual.[firstDiff])

    let assertTrue (label: string) (cond: bool) =
        total <- total + 1
        if cond then passed <- passed + 1
        else
            failed <- failed + 1
            failures.Add(label, "expected true")

    let assertFalse (label: string) (cond: bool) =
        total <- total + 1
        if not cond then passed <- passed + 1
        else
            failed <- failed + 1
            failures.Add(label, "expected false")

    /// Run all tests registered via `register`. Returns 0 on full pass.
    let runAll () : int =
        let tests = snapshot ()
        for t in tests do
            try
                t.Body ()
                // assertions inside have already updated counters
                ()
            with
            | ex ->
                failed <- failed + 1
                failures.Add(t.Name, "EXCEPTION: " + ex.Message)
        printfn ""
        printfn "===== %d tests, %d passed, %d failed =====" total passed failed
        for (name, why) in failures do
            consoleColor ConsoleColor.Red (sprintf "  FAIL %s -- %s" name why)
        if failed = 0 then
            consoleColor ConsoleColor.Green "  ALL PASS"
            0
        else
            consoleColor ConsoleColor.Red (sprintf "  %d failure(s)" failed)
            1

module Test =
    let register = TestFramework.register
    let equal = TestFramework.assertEqual
    let equalBytes = TestFramework.assertByteEqual
    let isTrue label cond = TestFramework.assertTrue label cond
    let isFalse label cond = TestFramework.assertFalse label cond
