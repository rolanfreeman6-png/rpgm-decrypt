module RpgmDecrypt.Tests.Main

open RpgmDecrypt.Core
open RpgmDecrypt.Tests
open RpgmDecrypt.Tests.TestFramework

[<EntryPoint>]
let main (_ : string[]) : int =
    TypesTests.register ()
    CryptoTests.register ()
    KeyDiscoveryTests.register ()
    FormatMvTests.register ()
    FormatMzTests.register ()
    FormatXpTests.register ()
    EndToEndTests.register ()
    let n = List.length (TestFramework.snapshot ())
    printfn "[main] tests registered so far: %d" n
    TestFramework.runAll ()
