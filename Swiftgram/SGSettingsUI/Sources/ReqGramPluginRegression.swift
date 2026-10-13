#if DEBUG
import Foundation
import ZipArchive
import ReqGramPythonRuntime

/// Native ZIP fixtures: deliberately write raw headers, without a writer that
/// sanitizes the malformed names/attributes under test. All entries are stored.
func reqGramZIPRegressions() throws {
    func zip(_ names: [Data], mode: UInt32 = 0o100644, flags: UInt16 = 0, crc: UInt32 = 0, size: UInt32 = 0) -> Data {
        var local = Data(), central = Data()
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        for name in names {
            let offset = UInt32(local.count)
            append(UInt32(0x04034b50), to: &local)
            for value in [20, flags, 0, 0, 0] as [UInt16] { append(value, to: &local) }
            append(crc, to: &local); append(UInt32(0), to: &local); append(size, to: &local)
            append(UInt16(name.count), to: &local); append(UInt16(0), to: &local); local.append(name)
            append(UInt32(0x02014b50), to: &central)
            for value in [0x0314, 20, flags, 0, 0, 0] as [UInt16] { append(value, to: &central) }
            append(crc, to: &central); append(UInt32(0), to: &central); append(size, to: &central)
            for value in [UInt16(name.count), 0, 0, 0, 0] as [UInt16] { append(value, to: &central) }
            append(mode << 16, to: &central); append(offset, to: &central); central.append(name)
        }
        let offset = UInt32(local.count)
        local.append(central); append(UInt32(0x06054b50), to: &local)
        for value in [0, 0, UInt16(names.count), UInt16(names.count)] as [UInt16] { append(value, to: &local) }
        append(UInt32(central.count), to: &local); append(offset, to: &local); append(UInt16(0), to: &local)
        return local
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ixplugin")
    defer { try? FileManager.default.removeItem(at: url) }
    let valid = [Data("manifest.json".utf8), Data("main.py".utf8)]
    try zip(valid).write(to: url)
    guard SSZipArchive.reqGramPluginContents(atPath: url.path)?.count == 2 else { throw NSError(domain: "ZIP valid control", code: 1) }
    var cases: [(String, Data)] = []
    for name in ["../escape.py", "/absolute.py", "a\\b.py", "a:b.py", "a//b.py", "./a.py", "folder/", "native.so", "bad\0.py"] {
        cases.append((name, zip(valid + [Data(name.utf8)])))
    }
    cases += [("invalid UTF8", zip(valid + [Data([0xff, 46, 112, 121])])),
              ("duplicate", zip(valid + [valid[1]])), ("case collision", zip(valid + [Data("MAIN.py".utf8)])),
              ("symlink", zip(valid, mode: 0o120777)), ("fifo", zip(valid, mode: 0o010644)),
              ("encrypted", zip(valid, flags: 1)), ("CRC", zip(valid, crc: 1)),
              ("size mismatch", zip(valid, size: 1)), ("oversized", zip(valid, size: 8388609)),
              ("entry limit", zip((0...512).map { Data("\($0).py".utf8) })),
              ("truncated", Data(zip(valid).prefix(15)))]
    for (name, bytes) in cases {
        try bytes.write(to: url, options: .atomic)
        guard SSZipArchive.reqGramPluginContents(atPath: url.path) == nil else { throw NSError(domain: "ZIP accepted \(name)", code: 1) }
    }
    // Same URL reused: a new contents call must not serve an earlier snapshot.
    let inspector = ReqGramPluginZIPInspector()
    try zip(valid).write(to: url, options: .atomic)
    let snapshot = try inspector.contents(in: url)
    try zip([valid[0], Data("replacement.py".utf8)]).write(to: url, options: .atomic)
    let replacement = try inspector.contents(in: url)
    guard snapshot["main.py"] != nil, replacement["main.py"] == nil, replacement["replacement.py"] != nil else { throw NSError(domain: "ZIP stale snapshot", code: 1) }
    NSLog("[ReqGramEmbeddedDiagnostic] PASS native ZIP %d malformed cases and immutable snapshot/path reuse", cases.count)
}

func reqGramBoundaryRegression(completion: @escaping (Bool) -> Void) {
    reqGramEventRuntimeRegression { passed in
        guard passed else { completion(false); return }
        reqGramLifecycleBoundaryRegression(completion: completion)
    }
}

private func reqGramEventRuntimeRegression(completion: @escaping (Bool) -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let module = "reqgram_events_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let source = """
    enabled = False
    count = 0
    def on_enable():
        global enabled
        enabled = True
    def on_event(event):
        global count
        assert enabled
        assert event == {"event": "app.active"}
        count += 1
        if count == 2:
            raise SystemExit("fixture must not exit app")
    def on_disable():
        pass
    """
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: directory.appendingPathComponent("main.py"))
    } catch { completion(false); return }
    let runtime = RGPythonRuntime.shared()
    let event = Data("{\"event\":\"app.active\"}".utf8)
    runtime.runPlugin(module, directory: directory.path, start: true, host: { _, _ in [:] }, boundary: { _ in true }) { startError in
        guard startError == nil else { try? FileManager.default.removeItem(at: directory); completion(false); return }
        runtime.deliverEvent(module, takeEvent: { event }, boundary: { _ in true }) { firstError in
            let firstPassed = firstError == nil && !Thread.isMainThread
            runtime.deliverEvent(module, takeEvent: { event }, boundary: { _ in true }) { exceptionError in
                // A cancelled/stale turn must not call Python (which would increment count).
                runtime.deliverEvent(module, takeEvent: { nil }, boundary: { _ in true }) { staleError in
                    runtime.evaluateExpression("__import__('sys').modules['\(module)'].count") { value, queryError in
                        let passed = firstPassed && exceptionError != nil && staleError == nil && queryError == nil && value == "2"
                        runtime.runPlugin(module, directory: directory.path, start: false, host: { _, _ in [:] }, boundary: { _ in true }) { stopError in
                            try? FileManager.default.removeItem(at: directory)
                            completion(passed && stopError == nil)
                        }
                    }
                }
            }
        }
    }
}

private func reqGramLifecycleBoundaryRegression(completion: @escaping (Bool) -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let module = "reqgram_fault_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("def on_enable():\n    pass\ndef on_disable():\n    pass\n".utf8).write(to: directory.appendingPathComponent("main.py"))
    } catch { completion(false); return }
    let runtime = RGPythonRuntime.shared()
    runtime.runPlugin(module, directory: directory.path, start: true, host: { _, _ in [:] }, boundary: { entering in entering }) { error in
        guard error?.localizedDescription.contains("marker could not be cleared") == true else { completion(false); return }
        runtime.evaluateExpression("'\(module)' not in __import__('sys').modules") { result, queryError in
            guard result == "True", queryError == nil else { completion(false); return }
            // The exact same name can start again, then leave no resident module.
            runtime.runPlugin(module, directory: directory.path, start: true, host: { _, _ in [:] }, boundary: { _ in true }) { retryError in
                guard retryError == nil else { completion(false); return }
                // Refused entry must still remove residency without running on_disable.
                runtime.runPlugin(module, directory: directory.path, start: false, host: { _, _ in [:] }, boundary: { _ in false }) { stopError in
                    runtime.evaluateExpression("'\(module)' not in __import__('sys').modules") { result, queryError in
                        try? FileManager.default.removeItem(at: directory)
                        completion(stopError?.localizedDescription.contains("Could not persist execution marker") == true && result == "True" && queryError == nil)
                    }
                }
            }
        }
    }
}
#endif
