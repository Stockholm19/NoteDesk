import Testing
@testable import NoteStationKit

@Test func jsonParamsAreEncodedLikeDSMWebUI() {
    #expect(JSONValue.string("1026_ABC").jsonText == "\"1026_ABC\"")
    #expect(JSONValue.bool(true).jsonText == "true")
    #expect(JSONValue.int(3).jsonText == "3")
    #expect((["device": "desktop"] as JSONValue).jsonText == "{\"device\":\"desktop\"}")
}

@Test func formEncodingEscapesCyrillic() {
    #expect(DSMClient.formEncode("Заметка 1") == "%D0%97%D0%B0%D0%BC%D0%B5%D1%82%D0%BA%D0%B0%201")
    #expect(DSMClient.formEncode("a+b&c=d") == "a%2Bb%26c%3Dd")
}

@Test func noteParsesLeniently() throws {
    let v = try JSONValue.parse("""
    {"object_id":"1026_X","title":"T","ver":"abc","mtime":1700000000,"parent_id":"1026_NB",
     "tag":["дом","работа"],"recycle":false,"content":"<p>hi</p>",
     "attachment":{"_f1":{"ref":"R1","name":"a.png","type":"image/png","md5":"m"}}}
    """)
    let n = try #require(NSNote(v))
    #expect(n.id == "1026_X")
    #expect(n.tags == ["дом", "работа"])
    #expect(n.attachments.first?.ref == "R1")
    #expect(n.attachments.first?.isImage == true)
}

@Test func briefStripsMarkup() {
    #expect(HTMLText.brief(from: "<p>Привет&nbsp;<b>мир</b></p><p>2</p>") == "Привет мир 2")
}

@Test func listFoundUnderAnyKey() throws {
    let v = try JSONValue.parse(#"{"total":1,"offset":0,"notes":[{"object_id":"1"}]}"#)
    #expect(v.firstList(preferring: ["notes"]).count == 1)
    let w = try JSONValue.parse(#"{"total":1,"whatever":[{"object_id":"1"}]}"#)
    #expect(w.firstList(preferring: ["notes"]).count == 1)
}
