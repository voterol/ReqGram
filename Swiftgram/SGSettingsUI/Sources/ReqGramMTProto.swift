import Foundation

let reqGramMTProtoMaximumBody = 64 * 1024

struct ReqGramMTProtoInputError: Error {
    let code: String
}

/// Strict, schema-free TL wire encoder. Generated TelegramApi functions cannot
/// be selected dynamically by name, so JSON uses explicit constructor IDs and
/// ordered typed values instead of claiming generated-schema coverage.
enum ReqGramTLEncoder {
    static func request(_ data: Data) -> Result<Data, ReqGramMTProtoInputError> {
        guard data.count <= reqGramMTProtoMaximumBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["constructor", "arguments"]),
              let constructor = int32(object["constructor"]), let arguments = object["arguments"] as? [[String: Any]],
              arguments.count <= 256 else { return .failure(ReqGramMTProtoInputError(code: "invalid_payload")) }
        var output = Data()
        append(constructor, to: &output)
        var budget = 512
        for value in arguments {
            if let failure = encode(value, output: &output, depth: 0, budget: &budget) { return .failure(ReqGramMTProtoInputError(code: failure)) }
            if output.count > reqGramMTProtoMaximumBody { return .failure(ReqGramMTProtoInputError(code: "payload_limit")) }
        }
        return .success(output)
    }

    private static func encode(_ node: [String: Any], output: inout Data, depth: Int, budget: inout Int) -> String? {
        guard depth <= 16, budget > 0, let type = node["type"] as? String else { return "unsupported_tl_form" }
        budget -= 1
        switch type {
        case "int":
            guard Set(node.keys) == ["type", "value"], let value = int32(node["value"]) else { return "invalid_tl_value" }
            append(value, to: &output)
        case "long":
            guard Set(node.keys) == ["type", "value"], let value = int64(node["value"]) else { return "invalid_tl_value" }
            append(value, to: &output)
        case "double":
            guard Set(node.keys) == ["type", "value"], let number = node["value"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return "invalid_tl_value" }
            append(number.doubleValue.bitPattern, to: &output)
        case "string":
            guard Set(node.keys) == ["type", "value"], let value = node["value"] as? String,
                  let bytes = value.data(using: .utf8) else { return "invalid_tl_value" }
            if let failure = appendTLBytes(bytes, to: &output) { return failure }
        case "bytes":
            guard Set(node.keys) == ["type", "value"], let value = node["value"] as? String,
                  let bytes = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]),
                  bytes.base64EncodedString() == value else { return "invalid_tl_value" }
            if let failure = appendTLBytes(bytes, to: &output) { return failure }
        case "bool":
            guard Set(node.keys) == ["type", "value"], let value = node["value"] as? Bool else { return "invalid_tl_value" }
            append(Int32(bitPattern: value ? 0x997275b5 : 0xbc799737), to: &output)
        case "constructor":
            guard Set(node.keys) == ["type", "constructor", "arguments"], let constructor = int32(node["constructor"]),
                  let arguments = node["arguments"] as? [[String: Any]], arguments.count <= 256 else { return "invalid_tl_value" }
            append(constructor, to: &output)
            for value in arguments { if let failure = encode(value, output: &output, depth: depth + 1, budget: &budget) { return failure } }
        case "vector":
            guard Set(node.keys) == ["type", "items"], let items = node["items"] as? [[String: Any]], items.count <= 256 else { return "invalid_tl_value" }
            append(Int32(bitPattern: 0x1cb5c415), to: &output); append(Int32(items.count), to: &output)
            for value in items { if let failure = encode(value, output: &output, depth: depth + 1, budget: &budget) { return failure } }
        default: return "unsupported_tl_form"
        }
        return output.count <= reqGramMTProtoMaximumBody ? nil : "payload_limit"
    }

    private static func int32(_ value: Any?) -> Int32? {
        guard let value = value as? String else { return nil }
        if value.hasPrefix("0x"), let parsed = UInt32(value.dropFirst(2), radix: 16) { return Int32(bitPattern: parsed) }
        guard let parsed = Int32(value), String(parsed) == value else { return nil }; return parsed
    }
    private static func int64(_ value: Any?) -> Int64? {
        guard let value = value as? String, let parsed = Int64(value), String(parsed) == value else { return nil }; return parsed
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to output: inout Data) {
        var little = value.littleEndian; withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
    }
    private static func appendTLBytes(_ value: Data, to output: inout Data) -> String? {
        guard value.count <= 0x00ff_ffff else { return "payload_limit" }
        let prefix: Int
        if value.count < 254 { output.append(UInt8(value.count)); prefix = 1 }
        else { output.append(254); output.append(UInt8(value.count & 255)); output.append(UInt8((value.count >> 8) & 255)); output.append(UInt8((value.count >> 16) & 255)); prefix = 4 }
        output.append(value)
        output.append(contentsOf: repeatElement(0, count: (4 - ((prefix + value.count) % 4)) % 4))
        return nil
    }
}

struct ReqGramMTProtoInput {
    let requestId: String
    let body: Data
    let timeout: TimeInterval
    static func parse(_ bytes: Data?, jsonTL: Bool) -> Result<ReqGramMTProtoInput, ReqGramMTProtoInputError> {
        guard let bytes, bytes.count <= 96 * 1024,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let requestId = object["request_id"] as? String,
              requestId.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil,
              let timeoutNumber = object["timeout"] as? NSNumber, CFGetTypeID(timeoutNumber) != CFBooleanGetTypeID(),
               timeoutNumber.doubleValue >= 1, timeoutNumber.doubleValue <= 30 else { return .failure(ReqGramMTProtoInputError(code: "invalid_payload")) }
        let body: Data
        if jsonTL {
            guard Set(object.keys) == ["request_id", "timeout", "request"], let request = object["request"],
                   JSONSerialization.isValidJSONObject(request), let encoded = try? JSONSerialization.data(withJSONObject: request) else { return .failure(ReqGramMTProtoInputError(code: "invalid_payload")) }
            switch ReqGramTLEncoder.request(encoded) { case let .success(value): body = value; case let .failure(error): return .failure(error) }
        } else {
            guard Set(object.keys) == ["request_id", "timeout", "body"], let encoded = object["body"] as? String,
                   let value = Data(base64Encoded: encoded), value.base64EncodedString() == encoded else { return .failure(ReqGramMTProtoInputError(code: "invalid_payload")) }
            body = value
        }
        guard body.count >= 4, body.count <= reqGramMTProtoMaximumBody, body.count % 4 == 0 else { return .failure(ReqGramMTProtoInputError(code: "invalid_tl_payload")) }
        return .success(ReqGramMTProtoInput(requestId: requestId, body: body, timeout: timeoutNumber.doubleValue))
    }
}
