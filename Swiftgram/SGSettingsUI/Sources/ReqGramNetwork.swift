import Foundation

/// The deliberately small network boundary exposed to a plugin host session.
/// It is ephemeral: no shared cookies, credentials, caches, or app sessions.
final class ReqGramNetworkSession: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var active = true
    private var nextID = 0
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var buffers: [Int: Data] = [:]
    private var responses: [Int: HTTPURLResponse] = [:]
    private var locations: [Int: String] = [:]
    /// Per-host-session cap. A slot is reserved before URLSession creates a task.
    private let maxRetainedTasks = 16
    #if DEBUG
    private let protocolClasses: [AnyClass]?
    #else
    private let protocolClasses: [AnyClass]? = nil
    #endif
    private var session: URLSession?
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        #if DEBUG
        configuration.protocolClasses = protocolClasses
        #endif
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    private let events: ([[String: String]]) -> Void
    private let maxResponse = 1_048_576
    #if DEBUG
    private var debugHasSession: Bool { lock.lock(); defer { lock.unlock() }; return session != nil }
    #endif

    init(events: @escaping ([[String: String]]) -> Void, protocolClasses: [AnyClass]? = nil) {
        #if DEBUG
        self.protocolClasses = protocolClasses
        #endif
        self.events = events
        super.init()
    }

    func close() {
        lock.lock(); active = false
        let current = Array(tasks.values)
        tasks.removeAll(); buffers.removeAll(); responses.removeAll()
        let currentSession = session
        session = nil
        lock.unlock()
        current.forEach { $0.cancel() }
        currentSession?.invalidateAndCancel()
    }

    /// Cancel and publish the terminal event atomically with respect to URLSession.
    func cancel(_ bytes: Data?) -> [String: Any] {
        guard let bytes,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["request_id"] != nil,
              let text = String(data: bytes, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #""request_id"\s*:\s*([0-9]+)(?=\s*[,}])"#),
              regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 1,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 2,
              text[Range(match.range(at: 1), in: text)!].first != "0",
              let id = Int(text[Range(match.range(at: 1), in: text)!]) else { return ["error": "invalid_payload"] }
        lock.lock()
        guard active, let task = tasks.removeValue(forKey: id) else {
            lock.unlock()
            return ["error": "request_not_found"]
        }
        buffers.removeValue(forKey: id); responses.removeValue(forKey: id); locations.removeValue(forKey: id)
        lock.unlock()
        task.cancel()
        events([["event": "network.response", "request_id": String(id), "status": "0", "size": "0", "body": "", "error": "cancelled"]])
        return [:]
    }

    func request(_ bytes: Data?, insecureAllowed: Bool) -> [String: Any] {
        guard let bytes, let input = try? JSONDecoder().decode(Input.self, from: bytes),
              input.valid(insecureAllowed: insecureAllowed) else { return ["error": "invalid_payload"] }
        guard let url = URL(string: input.url), let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && insecureAllowed) else { return ["error": "network_insecure_url"] }
        var request = URLRequest(url: url)
        request.httpMethod = input.method
        request.timeoutInterval = input.timeout
        request.httpShouldHandleCookies = false
        request.httpBody = input.body
        input.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        lock.lock()
        guard active else { lock.unlock(); return ["error": "session_inactive"] }
        guard tasks.count < maxRetainedTasks else { lock.unlock(); return ["error": "network_limit"] }
        nextID += 1; let id = nextID
        let currentSession: URLSession
        if let session { currentSession = session }
        else { let created = makeSession(); session = created; currentSession = created }
        let task = currentSession.dataTask(with: request)
        tasks[id] = task; buffers[id] = Data(); locations[id] = "\(url.host ?? "")\(url.path)"; lock.unlock()
        task.taskDescription = String(id)
        task.resume()
        return ["data": (try? JSONSerialization.data(withJSONObject: ["request_id": id])) ?? Data()]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let id = dataTask.taskDescription.flatMap(Int.init), let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        lock.lock()
        guard tasks[id] != nil else { lock.unlock(); completionHandler(.cancel); return }
        responses[id] = http
        lock.unlock(); completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = dataTask.taskDescription.flatMap(Int.init) else { return }
        lock.lock()
        guard let buffer = buffers[id] else { lock.unlock(); return }
        if buffer.count + data.count > maxResponse { lock.unlock(); dataTask.cancel(); return }
        buffers[id] = buffer + data; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Redirects are only followed within HTTPS. HTTP is never reached via a redirect.
        guard newRequest.url?.scheme?.lowercased() == "https" else { completionHandler(nil); return }
        completionHandler(newRequest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription.flatMap(Int.init) else { return }
        lock.lock()
        guard tasks.removeValue(forKey: id) != nil else { lock.unlock(); return }
        let response = responses.removeValue(forKey: id)
        let body = buffers.removeValue(forKey: id) ?? Data()
        let location = locations.removeValue(forKey: id) ?? ""
        let live = active
        lock.unlock()
        guard live else { return }
        let status = response?.statusCode ?? 0
        NSLog("[ReqGram network] host_path=%@ method=%@ status=%d size=%d", location, task.originalRequest?.httpMethod ?? "", status, body.count)
        let result: [String: String] = ["event": "network.response", "request_id": String(id), "status": String(status), "size": String(body.count), "body": error == nil && body.count <= maxResponse ? body.base64EncodedString() : "", "error": error.map { ($0 as NSError).code == URLError.timedOut.rawValue ? "timeout" : "network_error" } ?? (response == nil ? "network_error" : "")]
        events([result])
    }

    private struct Input: Decodable {
        let url: String; let method: String; let headers: [String: String]; let body: Data?; let timeout: TimeInterval
        enum CodingKeys: String, CodingKey { case url, method, headers, body, timeout }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self); url = try c.decode(String.self, forKey: .url); method = try c.decode(String.self, forKey: .method).uppercased(); headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]; body = try c.decodeIfPresent(Data.self, forKey: .body); timeout = try c.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 15
        }
        func valid(insecureAllowed: Bool) -> Bool {
            guard url.utf8.count <= 2048, ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(method), headers.count <= 32,
                  headers.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 4096 }), (body?.count ?? 0) <= 65_536,
                  timeout >= 1 && timeout <= 30, let u = URL(string: url), u.host != nil else { return false }
            return true
        }
    }
}

#if DEBUG
final class ReqGramDiagnosticURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "reqgram.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path == "/timeout" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
        } else if url.path == "/hold" {
            // Intentionally retained until cancellation by the bounded-task diagnostic.
        } else if url.path == "/oversize" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 1_048_577)); client?.urlProtocolDidFinishLoading(self)
        } else if url.path == "/redirect-http" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://reqgram.test/final"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: Data("diagnostic".utf8)); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

extension ReqGramNetworkSession {
    static func runDiagnostic(report: @escaping (String) -> Void, completion: @escaping () -> Void) {
        let session = ReqGramNetworkSession(events: { events in events.forEach { report("NETWORK event=\($0)") } }, protocolClasses: [ReqGramDiagnosticURLProtocol.self])
        let http = session.request(Data(#"{"url":"http://reqgram.test/ok","method":"GET"}"#.utf8), insecureAllowed: false)
        report("\((http["error"] as? String) == "network_insecure_url" ? "PASS" : "FAIL") network HTTP denied")
        _ = session.request(Data(#"{"url":"http://reqgram.test/ok","method":"GET","timeout":1}"#.utf8), insecureAllowed: true)
        _ = session.request(Data(#"{"url":"https://reqgram.test/redirect-http","method":"GET","timeout":1}"#.utf8), insecureAllowed: false)
        _ = session.request(Data(#"{"url":"https://reqgram.test/oversize","method":"GET","timeout":1}"#.utf8), insecureAllowed: false)
        _ = session.request(Data(#"{"url":"https://reqgram.test/timeout","method":"GET","timeout":1}"#.utf8), insecureAllowed: false)
        let cancellation = session.request(Data(#"{"url":"https://reqgram.test/timeout","method":"GET","timeout":1}"#.utf8), insecureAllowed: false)
        let cancellationID = (try? JSONSerialization.jsonObject(with: cancellation["data"] as? Data ?? Data())) as? [String: Any]
        guard let cancellationNumber = cancellationID?["request_id"] as? Int, cancellationNumber > 0 else {
            report("FAIL network cancellation setup")
            session.close()
            completion()
            return
        }
        let cancelPayload = "{\"request_id\":\(cancellationNumber)}"
        let cancelResult = session.cancel(Data(cancelPayload.utf8))
        report(cancelResult["error"] == nil ? "PASS network cancellation" : "FAIL network cancellation")
        let malformedPayloads = ["true", "1.5", "0", "-1", "9223372036854775808"]
        malformedPayloads.forEach { payload in
            let result = session.cancel(Data("{\"request_id\":\(payload)}".utf8))
            report(result["error"] as? String == "invalid_payload" ? "PASS invalid request_id \(payload)" : "FAIL invalid request_id \(payload)")
        }
        let secondCancel = session.cancel(Data(cancelPayload.utf8))
        report(secondCancel["error"] as? String == "request_not_found" ? "PASS duplicate cancellation" : "FAIL duplicate cancellation")
        let limited = ReqGramNetworkSession(events: { _ in }, protocolClasses: [ReqGramDiagnosticURLProtocol.self])
        var admitted = 0
        for _ in 0..<16 {
            if limited.request(Data(#"{"url":"https://reqgram.test/hold","method":"GET","timeout":30}"#.utf8), insecureAllowed: false)["data"] != nil { admitted += 1 }
        }
        let overLimit = limited.request(Data(#"{"url":"https://reqgram.test/hold","method":"GET","timeout":30}"#.utf8), insecureAllowed: false)
        report(admitted == 16 && overLimit["error"] as? String == "network_limit" ? "PASS network retained-task limit" : "FAIL network retained-task limit")
        limited.close()
        // Closing an unused session must not instantiate URLSession as a side effect.
        let unused = ReqGramNetworkSession(events: { _ in }, protocolClasses: [ReqGramDiagnosticURLProtocol.self])
        unused.close()
        report(!unused.debugHasSession ? "PASS unused network close" : "FAIL unused network close")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            session.close()
            completion()
        }
    }
}
#endif
