module RpgmDecrypt.Tests.FormatMzTests

open System.IO
open System.IO.Compression
open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let private buildSyntheticPak (entries : (string * byte[]) list) : byte[] =
    use ms = new MemoryStream()
    use archive = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen = true)
    for (name, payload) in entries do
        let e = archive.CreateEntry name
        use es = e.Open()
        es.Write(payload, 0, payload.Length)
    archive.Dispose()
    ms.ToArray()

let register () : unit =
    Test.register "Mz.openPak: rejects non-ZIP file" (fun () ->
        let tmp = Path.Combine(Path.GetTempPath(), "rpgm-decrypt-mz-tests")
        if Directory.Exists tmp then Directory.Delete(tmp, true)
        try
            Directory.CreateDirectory tmp |> ignore
            let notZip = Path.Combine(tmp, "fake.pak")
            let bogus = System.Convert.FromHexString "00000000"
            File.WriteAllBytes(notZip, bogus)
            match Mz.openPak notZip with
            | Error Mz.NotAZipFile -> Test.isTrue "got NotAZipFile" true
            | _ -> Test.isFalse "expected NotAZipFile" true
        finally
            try Directory.Delete(tmp, true) with | _ -> ())

    Test.register "Mz: decrypt synthetic Pak with PNG entry" (fun () ->
        let key : byte[] =
            System.Convert.FromHexString "DEADBEEFCAFEBABE0102030405060708"
        let pngHeader : byte[] =
            System.Convert.FromHexString "89504E470D0A1A0AAABBCCDDEEFF1122"
        let zipBytes = buildSyntheticPak [ "www/img/test.png", pngHeader ]
        let tmp = Path.Combine(Path.GetTempPath(), "rpgm-decrypt-mz-tests")
        if Directory.Exists tmp then Directory.Delete(tmp, true)
        try
            Directory.CreateDirectory tmp |> ignore
            let pakPath = Path.Combine(tmp, "game.pak")
            File.WriteAllBytes(pakPath, zipBytes)
            match Mz.openPak pakPath with
            | Ok z ->
                match Mz.decryptAll key z with
                | Ok entries ->
                    Test.equal "one entry" 1 (List.length entries)
                    Test.equal "entry name" "www/img/test.png" entries.Head.EntryName
                    Test.equalBytes "entry bytes" pngHeader entries.Head.Bytes
                    Test.equal "kind=png" "png" entries.Head.PlaintextKind
                | _ -> Test.isFalse "decryptAll should succeed" true
            | _ -> Test.isFalse "openPak should succeed" true
        finally
            try Directory.Delete(tmp, true) with | _ -> ())

