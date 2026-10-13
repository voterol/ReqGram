import Foundation
@testable import SGSettingsUI

private func json(_ value: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: value)
}

private func assertFailure(_ data: Data, jsonTL: Bool, _ expected: String, file: StaticString = #file, line: UInt = #line) {
    switch ReqGramMTProtoInput.parse(data, jsonTL: jsonTL) {
    case .success:
        assertionFailure("expected \(expected)", file: file, line: line)
    case let .failure(error):
        if error.code != expected {
            assertionFailure("expected \(expected), got \(error.code)", file: file, line: line)
        }
    }
}

@main
struct ReqGramMTProtoTests {
    static func main() {
        let rawBody = Data([0x01, 0x02, 0x03, 0x04])
        let raw = json([
            "request_id": "raw-1",
            "timeout": 1,
            "body": rawBody.base64EncodedString(),
        ])
        switch ReqGramMTProtoInput.parse(raw, jsonTL: false) {
        case let .success(input):
            assert(input.requestId == "raw-1")
            assert(input.body == rawBody)
            assert(input.timeout == 1)
        case .failure:
            assertionFailure("valid raw request rejected")
        }

        let jsonRequest = json([
            "request_id": "json-1",
            "timeout": 2,
            "request": [
                "constructor": "1",
                "arguments": [["type": "int", "value": "42"]],
            ],
        ])
        switch ReqGramMTProtoInput.parse(jsonRequest, jsonTL: true) {
        case let .success(input):
            assert(input.requestId == "json-1")
            assert(input.body.count == 8)
            assert(input.body.suffix(4) == Data([42, 0, 0, 0]))
        case .failure:
            assertionFailure("valid JSON TL request rejected")
        }

        assertFailure(json(["request_id": "bad id", "timeout": 1, "body": rawBody.base64EncodedString()]), jsonTL: false, "invalid_payload")
        assertFailure(json(["request_id": "bad-timeout", "timeout": 0, "body": rawBody.base64EncodedString()]), jsonTL: false, "invalid_payload")
        assertFailure(json(["request_id": "unaligned", "timeout": 1, "body": Data([1, 2, 3]).base64EncodedString()]), jsonTL: false, "invalid_tl_payload")
        assertFailure(json(["request_id": "bad-json", "timeout": 1, "request": ["constructor": "1", "arguments": [["type": "float", "value": "1"]]]]), jsonTL: true, "unsupported_tl_form")

        let oversized = Data(repeating: 0, count: 64 * 1024 + 4)
        assertFailure(json(["request_id": "large", "timeout": 1, "body": oversized.base64EncodedString()]), jsonTL: false, "payload_limit")
        print("ReqGramMTProtoTests passed")
    }
}
