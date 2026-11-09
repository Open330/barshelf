import XCTest
@testable import MenubucketCore

final class JSONValueParsingTests: XCTestCase {
    /// The fast parser means exactly what the Codable decoder means.
    func testParsingAgreesWithTheCodableDecoder() throws {
        let samples = [
            #"{"a":true,"b":false,"c":0,"d":1,"e":-2.5,"f":1e3,"g":null,"h":"xé\n","i":[1,"2",[false,{}]],"j":{"k":{"l":[]}}}"#,
            #"[0,1,true,false,null,"",""]"#,
            #""just a string""#,
            "42",
            "true",
            "null",
            #"{"big":12345678901234567890,"tiny":1e-300,"neg":-0}"#,
        ]
        for text in samples {
            let data = Data(text.utf8)
            XCTAssertEqual(try JSONValue.parse(data), try JSONDecoder().decode(JSONValue.self, from: data), text)
        }
        XCTAssertThrowsError(try JSONValue.parse(Data("{nope".utf8)))
        // Long decimals read as a Double reads them.
        let long = Data("0.12345678901234567890123456789".utf8)
        XCTAssertEqual(try JSONValue.parse(long), try JSONDecoder().decode(JSONValue.self, from: long))
    }

    func testARequestIsReadFromOneParse() throws {
        let line = Data(#"{"jsonrpc":"2.0","id":7,"method":"host.render","params":{"tree":{"type":"text","value":"hi"}}}"#.utf8)
        guard case let .request(request) = try JsonRpcCodec.decode(line: line) else { return XCTFail("not a request") }
        XCTAssertEqual(request.id, .number(7))
        XCTAssertEqual(request.method, "host.render")
        XCTAssertEqual(request.params?.objectValue?["tree"]?.objectValue?["value"], .string("hi"))

        let notification = Data(#"{"jsonrpc":"2.0","method":"host.log","params":null}"#.utf8)
        guard case let .request(note) = try JsonRpcCodec.decode(line: notification) else { return XCTFail("not a request") }
        XCTAssertNil(note.id)
        XCTAssertNil(note.params, "params: null is no params")

        // Large integer ids keep every digit.
        for (text, id) in [("9007199254740993", 9_007_199_254_740_993), ("9223372036854775807", Int.max), ("1.5", 1)] {
            let big = Data(#"{"jsonrpc":"2.0","id":\#(text),"method":"x"}"#.utf8)
            guard case let .request(request) = try JsonRpcCodec.decode(line: big) else { return XCTFail(text) }
            XCTAssertEqual(request.id, .number(id), text)
        }

        for bad in [#"{"jsonrpc":"2.0","id":true,"method":"x"}"#, #"{"jsonrpc":"2.0","id":1,"method":3}"#, #"{"jsonrpc":"2.0","id":1e30,"method":"x"}"#] {
            XCTAssertThrowsError(try JsonRpcCodec.decode(line: Data(bad.utf8)), bad) { error in
                XCTAssertEqual((error as? JsonRpcError)?.code, JsonRpcError.invalidRequestCode, bad)
            }
        }
    }

    /// The exec result a script receives has the keys its Codable form has.
    func testTheExecResultMatchesItsCodableForm() throws {
        for json in [nil, JSONValue.object(["n": .number(1)])] {
            let result = ExecRunResult(exitCode: 3, stdout: "out", stderr: "err", json: json, durationMs: 12.5)
            XCTAssertEqual(result.jsonValue, try JSONValue.bridged(result))
        }
    }

    /// A response written by Foundation reads back as the one JSONEncoder
    /// wrote, on one line.
    func testAResultResponseMeansWhatTheCodableOneMeant() throws {
        let result = JSONValue.object([
            "stdout": .string("line1\nline2 \"quoted\" / é 🙂"),
            "exitCode": .number(0), "durationMs": .number(12.34), "ok": .bool(true),
            "json": .array([.number(0.1), .number(-3), .number(1e21), .null, .object([:])]),
        ])
        for id in [JsonRpcID.number(9_007_199_254_740_993), .string("a"), nil] {
            let response = JsonRpcResponse(id: id, result: result)
            let fast = try JsonRpcCodec.encode(.response(response))
            let codable = try JsonRpcCodec.makeEncoder().encode(response)
            XCTAssertFalse(fast.contains(0x0A), "one line")
            XCTAssertEqual(try JSONDecoder().decode(JsonRpcResponse.self, from: fast),
                           try JSONDecoder().decode(JsonRpcResponse.self, from: codable))
        }
        // NaN still fails, as it did.
        XCTAssertThrowsError(try JsonRpcCodec.encode(.response(JsonRpcResponse(id: .number(1), result: .number(.nan)))))
    }
}

