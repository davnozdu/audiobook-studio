import XCTest
@testable import StudioCore

final class CoreTests: XCTestCase {
    let fm=FileManager.default
    var rules:URL{URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("backend/engine/supertonic_rules.json")}
    func testScalarOffsets() throws {XCTAssertEqual(try NativeIO.scalarSlice("A😀Б",1,2),"😀");XCTAssertThrowsError(try NativeIO.scalarSlice("A",0,2))}
    func testRolesPreserveAllText()throws {
        let paragraph:Object=["id":"p00001","text":"— Да! 😀 — сказал он."],answer:Object=["paragraphs":[["id":"p00001","segments":[["text":"— Да! 😀","speaker":"hero"],["text":"— сказал он.","speaker":"narrator"]]]]]
        let rows=try NativeDirector.validateRoles(answer,chunk:[paragraph],allowed:["hero","narrator"]),spans=NativeIO.objects(rows[0]["spans"])
        XCTAssertEqual(spans[1]["start"] as? Int,8)
        let bad:Object=["paragraphs":[["id":"p00001","segments":[["text":"— Да! 😀","speaker":"hero"]]]]]
        XCTAssertThrowsError(try NativeDirector.validateRoles(bad,chunk:[paragraph],allowed:["hero"]))
    }
    func testExcerptNeverBorrowsAnotherRole() throws {
        let own="Я внимательно смотрю на дорогу и вспоминаю вчерашний разговор. Вдалеке слышен шум поезда, который медленно приближается к станции."
        let manifest:Object=["segments":[["speaker":"narrator","text":"Чужой текст, который нельзя использовать."],["speaker":"hero","text":own]]]
        let excerpt=try NativeProject.excerpt(manifest,character:"hero");XCTAssertFalse(excerpt.contains("Чужой"));XCTAssertTrue((110...150).contains(excerpt.count));XCTAssertThrowsError(try NativeProject.excerpt(manifest,character:"missing"))
    }
    func testNumberAndDateNormalization()throws {
        let ru=try RussianText(rules)
        XCTAssertEqual(try ru.integer(1234),"одна тысяча двести тридцать четыре")
        XCTAssertEqual(try ru.normalize("25%"),"двадцать пять процентов")
        XCTAssertEqual(try ru.normalize("Глава IV"),"Глава четвёртая")
        XCTAssertEqual(try ru.normalize("21.01.2024"),"двадцать первого января две тысячи двадцать четвёртого года")
        XCTAssertEqual(try ru.normalize("12:30"),"двенадцать часов тридцать минут")
        XCTAssertEqual(try ru.normalize("Цена 2,5 кг"),"Цена две целых пять десятых килограмма")
        XCTAssertEqual(try ru.normalize("https://site.ru/page12"),"https://site.ru/page12")
        XCTAssertThrowsError(try ru.normalize("31.02.2024"))
    }
    func testSplitKeepsScalarText()throws {
        let text="Очень длинная реплика. Следующая мысль 😀 состоит из нескольких слов. И ещё немного текста.",chunks=NativeBook.split(text,maximum:35)
        let result=try chunks.map{try NativeIO.scalarSlice(text,$0.0,$0.1)}.joined(separator:" ")
        XCTAssertEqual(result,text)
    }
    func temporary()->URL{let folder=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try! fm.createDirectory(at:folder,withIntermediateDirectories:true);return folder}
    func fixture(_ folder:URL)throws->Object {
        let book=folder.appendingPathComponent("book.epub");try Data("fixture".utf8).write(to:book)
        let source:Object=["paragraphs":[["id":"p00001","chapter_id":"ch001","text":"Я 😀 читаю книгу."]],"chapters":[["id":"ch001","title":"Глава"]]]
        let manifest:Object=["format":"qwen-audiobook-project","book":["input_sha256":try NativeIO.hashFile(book)],"voices":[["id":"narrator","voice_id":"voice_001"]],"segments":[["id":"seg000001","paragraph_id":"p00001","chapter_id":"ch001","speaker":"narrator","text":"Я 😀 читаю книгу.","source":["char_start":0,"char_end":16]]]]
        try NativeIO.write(folder.appendingPathComponent("roles/source.json"),source);try NativeIO.write(folder.appendingPathComponent("roles/manifest.json"),manifest);return manifest
    }
    func testProjectRoundtripAndMissingTextRejected()throws {
        let folder=temporary();defer{try? fm.removeItem(at:folder)};let p=folder.appendingPathComponent("book");try fm.createDirectory(at:p,withIntermediateDirectories:true);var manifest=try fixture(p);_=try NativeProject.verify(p)
        let archive=folder.appendingPathComponent("test.audiobookstudio");try NativeProject.export(p,destination:archive,settings:["music_enabled":false]);let opened=try NativeProject.open(archive,output:folder);_=try NativeProject.verify(opened)
        manifest["segments"]=[];try NativeIO.write(p.appendingPathComponent("roles/manifest.json"),manifest);XCTAssertThrowsError(try NativeProject.verify(p))
    }
    func testWAVMontageFramePreservation()throws {
        let folder=temporary();defer{try? fm.removeItem(at:folder)};let file=folder.appendingPathComponent("audio.wav"),montage=try WAVMontage(file);try montage.append([0.2,-0.4,0.1]);try montage.silence(7);try montage.append([0.5]);try montage.finish();let samples=try NativeWAV.read(file);XCTAssertEqual(samples.count,11);XCTAssertEqual(samples[10],0.5);XCTAssertEqual(samples[3...9],ArraySlice([Float](repeating:0,count:7)))
    }
    func testBinaryDictionaryBounds()throws {
        let folder=temporary();defer{try? fm.removeItem(at:folder)};let file=folder.appendingPathComponent("test.sacc")
        func le<T:FixedWidthInteger>(_ n:T)->Data{var v=n.littleEndian;return withUnsafeBytes(of:&v){Data($0)}}
        var data=Data("SACC".utf8);data += le(UInt32(1));data += le(UInt32(1));data += le(UInt64(28));data += le(UInt64(32));data += le(UInt32(0));let key=Data("книга".utf8),value=Data("кн+ига".utf8);data += le(UInt16(key.count));data += le(UInt16(value.count));data += key;data += value;try data.write(to:file)
        let dict=try AccentDictionary(file);XCTAssertEqual(try dict.lookup("книга"),"кн+ига");XCTAssertNil(try dict.lookup("кот"));try Data("SACC".utf8).write(to:file);XCTAssertThrowsError(try AccentDictionary(file))
    }
}
