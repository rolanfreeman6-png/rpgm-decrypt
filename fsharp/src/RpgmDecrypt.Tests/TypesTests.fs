module RpgmDecrypt.Tests.TypesTests

open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

/// Force-init this module's tests. Call once at startup so the
/// module's static initialiser (which calls `Test.register`) actually
/// runs. Without this, F# + .NET static-class-init rules leave the
/// test file's side-effects unrun.
let register () : unit =
    Test.register "Format.ofString is total mapping" (fun () ->
        Test.equal "XP"    (Some XP)    (Format.ofString "XP")
        Test.equal "VX"    (Some VX)    (Format.ofString "VX")
        Test.equal "VXAce" (Some VXAce) (Format.ofString "VXAce")
        Test.equal "MV"    (Some MV)    (Format.ofString "MV")
        Test.equal "MZ"    (Some MZ)    (Format.ofString "MZ")
        Test.equal "unknown->None"    None (Format.ofString "unknown")
        Test.equal "toString" "XP" (Format.toString XP))
    Test.register "Format.toString for MZ" (fun () ->
        Test.equal "MZ" (Format.toString MZ) "MZ")
    Test.register "RunSummary.tally counts and per-format map" (fun () ->
        let s0 = RunSummary.empty (System.DateTime.UtcNow)
        let s1 = RunSummary.tally (Outcome.Decrypted("foo", 1L, MV)) s0
        let s2 = RunSummary.tally (Outcome.Failed("bar", "broken"))     s1
        let s3 = RunSummary.tally (Outcome.Skipped("baz", "x"))         s2
        let s4 = RunSummary.tally (Outcome.PassedThrough("q", MV))      s3
        Test.equal "decrypted=1" 1 s4.DecryptedCount
        Test.equal "failed=1"    1 s4.FailedCount
        Test.equal "skipped=1"   1 s4.SkippedCount
        Test.equal "passthrough=1" 1 s4.PassedThroughCount
        Test.equal "per-format MV=2" 2 s4.PerFormat.[MV])
