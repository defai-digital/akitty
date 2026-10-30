import XCTest
@testable import AkittyKit

final class CellScannerTests: XCTestCase {
    private struct Reply: Decodable { let data: Payload; struct Payload: Decodable { let cells: [Cell] } }

    /// Cells compare through their wire encoding, which covers every field.
    private func wire(_ cells: [Cell]) throws -> Data { try JSONEncoder().encode(cells) }

    private func assertMatchesJSONDecoder(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let scanned = try XCTUnwrap(CellScanner.split(data), file: file, line: line)
        let expected = try JSONDecoder().decode(Reply.self, from: data).data.cells
        XCTAssertEqual(try wire(scanned.cells), try wire(expected), file: file, line: line)
        // What is left still decodes, with an empty cell array where the cells were.
        let rest = try JSONSerialization.jsonObject(with: scanned.rest) as? [String: Any]
        var original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var payload = try XCTUnwrap(original["data"] as? [String: Any]); payload["cells"] = []; original["data"] = payload
        XCTAssertEqual(rest as NSDictionary?, original as NSDictionary, file: file, line: line)
    }

    func testReadsRealSnapshotsExactlyAsJSONDecoderDoes() throws {
        let session = try TerminalSession(cols: 40, rows: 8, headless: true)
        defer { try? session.close() }
        let screens = [
            "plain \u{1b}[1mbold\u{1b}[0m \u{1b}[3;4mitalic underline\u{1b}[0m \u{1b}[9mstrike\u{1b}[0m \u{1b}[7mreverse\u{1b}[0m",
            "\u{1b}[38;2;1;2;3;48;5;200mtruecolor\u{1b}[0m \u{1b}[4:3m\u{1b}[58;2;255;0;0mcurly\u{1b}[0m",
            "\u{1b}]8;;https://example.com/\u{7}link\u{1b}]8;;\u{7} \u{1b}[4m\u{1b}]8;;https://u.test/\u{7}under\u{1b}]8;;\u{7}\u{1b}[0m",
            "漢字 한글 👨\u{200D}👩\u{200D}👧 🇯🇵 e\u{301} ❤\u{FE0F}",
            "quote \" backslash \\ slash / tab\tend",
            "╭─┬╮│┃╬▀▄█░▒▓⣿",
        ]
        for text in screens {
            _ = try session.call("feed", ["text": "\u{1b}[2J\u{1b}[H" + text])
            try assertMatchesJSONDecoder(try CoreBridge.raw(["op": "snapshot", "id": session.id, "compact": true]))
        }
        // Through the session too: the decoded snapshot carries the scanned cells.
        _ = try session.call("feed", ["text": "\u{1b}[2J\u{1b}[H" + screens[4]])
        let snapshot = try XCTUnwrap(try session.snapshot())
        XCTAssertEqual(snapshot.cells.first { $0.col == 6 }?.text, "\"")
        XCTAssertEqual(snapshot.cells.first { $0.col == 18 }?.text, "\\")
    }

    func testEscapesAndOptionalFields() throws {
        let json = #"""
        {"version":1,"ok":true,"data":{"title":"a \"cells\":[ trap","x":{"cells":[1]},"cells":[
          [0,0,"\"",1,2,0],[0,1,"\\",16777215,0,1],[0,2,"\u00e9\ud83d\ude00\n\t\/",3,4,1027],
          [1,0,"x",5,6,4,null,0],[1,1,"y",5,6,772,16711680],[1,2,"z",5,6,4,255,3]
        ],"rows":2}}
        """#
        try assertMatchesJSONDecoder(Data(json.utf8))
        let cells = try XCTUnwrap(CellScanner.split(Data(json.utf8))).cells
        XCTAssertEqual(cells.map(\.text), ["\"", "\\", "é😀\n\t/", "x", "y", "z"])
        XCTAssertEqual(cells[1].fg, [255, 255, 255]); XCTAssertTrue(cells[1].bold)
        XCTAssertEqual(cells[3].link, 0); XCTAssertNil(cells[3].ucolor)
        XCTAssertEqual(cells[4].ucolor, [255, 0, 0]); XCTAssertEqual(cells[4].ustyle, 3)
    }

    func testDefaultSchemaOneCellsDecodeLikeOptInCompactCells() throws {
        let session = try TerminalSession(cols: 20, rows: 3, headless: true)
        defer { try? session.close() }
        _ = try session.call("feed", ["text": "\u{1b}[1;3;4:3;9;58;2;1;2;3mA\u{1b}[0m界"])
        let legacy = try CoreBridge.raw(["op": "snapshot", "id": session.id])
        let compact = try CoreBridge.raw(["op": "snapshot", "id": session.id, "compact": true])
        XCTAssertNil(CellScanner.split(legacy))
        let decoder = JSONDecoder()
        XCTAssertEqual(try wire(decoder.decode(Reply.self, from: legacy).data.cells), try wire(decoder.decode(Reply.self, from: compact).data.cells))
    }

    func testMalformedCellBytesDoNotBypassJSONValidation() {
        for number in ["01", "-00"] {
            let data = Data("{\"data\":{\"cells\":[[\(number),0,\"a\",1,0,0]]}}".utf8)
            XCTAssertNil(CellScanner.split(data), "JSON integers cannot have leading zeroes")
        }
        for suffix in ["", "\\n"] {
            var data = Data(#"{"data":{"cells":[[0,0,""#.utf8)
            data.append(0xff)
            data.append(contentsOf: (suffix + #"",1,0,0]]}}"#).utf8)
            XCTAssertNil(CellScanner.split(data), "invalid UTF-8 must not be replaced silently")
        }
    }

    func testDeepUnknownValuesFallBackBeforeExhaustingTheStack() {
        let nested = String(repeating: "[", count: 256) + "0" + String(repeating: "]", count: 256)
        let data = Data("{\"extra\":\(nested),\"data\":{\"cells\":[]}}".utf8)
        XCTAssertNil(CellScanner.split(data))
    }

    func testAnythingUnexpectedFallsBackToJSONDecoder() {
        for json in [
            #"{"version":1,"ok":false,"error":"boom"}"#,
            #"{"version":1,"ok":true,"data":{"changed":false}}"#,
            #"{"version":1,"ok":true,"data":{"cells":[[0,0,"a",1.5,0,0]]}}"#,
            #"{"version":1,"ok":true,"data":{"cells":[[0,0,"a",-1,0,0]]}}"#,
            #"{"version":1,"ok":true,"data":{"cells":[[0,0,"a",1,0,70000]]}}"#,
            #"{"version":1,"ok":true,"data":{"cells":[[0,0,"\ud800",1,0,0]]}}"#,
            #"{"version":1,"ok":true,"data":{"cells":[[0,0,"a",1,0,0,null,0,9]]}}"#,
            #"{"version":1,"ok":true,"data":{"cells":[[0,0,"a",1,0,0]"#,
            "",
        ] { XCTAssertNil(CellScanner.split(Data(json.utf8)), json) }
    }
}
