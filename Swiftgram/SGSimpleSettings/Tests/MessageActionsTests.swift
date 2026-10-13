import Foundation

@main
struct MessageActionsTests {
    static func main() {
        let registry = ReqGramMessageActions()
        registry.setAccount("account_9223372036854775807")
        let scope = registry.currentScope(), owner = UUID()
        var received: [[String: String]] = []
        func register(_ json: String) -> String? {
            registry.register(owner: owner, scope: scope, plugin: "fixture", bytes: Data(json.utf8)) { event, token in
                assert(registry.isRegistered(token, owner: owner))
                received.append(event)
            }
        }
        assert(register("{\"id\":\"info\",\"label\":\"Info\",\"extra\":\"x\"}") == "invalid_payload")
        assert(register("{\"id\":\"info\",\"label\":\"bad\\nlabel\"}") == "invalid_payload")
        assert(register("{\"id\":\"info\\n\",\"label\":\"Info\"}") == "invalid_payload")
        assert(register("{\"id\":\"info\",\"label\":\"\\u202eevil\"}") == "invalid_payload")
        assert(register("{\"id\":\"info\",\"label\":\" padded\"}") == "invalid_payload")
        assert(register("{\"id\":1,\"label\":\"Info\"}") == "invalid_payload")
        assert(register("{\"id\":\"info\",\"label\":\"\(String(repeating: "😀", count: 17))\"}") == "invalid_payload")
        assert(register("{\"id\":\"info\",\"label\":\"Info\"}") == nil)
        assert(received.isEmpty)
        assert(register("{\"id\":\"info\",\"label\":\"Info\"}") == "duplicate_action")
        assert(register("{\"id\":\"other\",\"label\":\"Other\"}") == nil)
        assert(register("{\"id\":\"third\",\"label\":\"Third\"}") == "action_limit")
        assert(registry.actions(account: "account_other").isEmpty)
        let action = registry.actions(account: scope!.account)[0]
        func tap() { registry.tap(action, account: scope!.account, peer: "9223372036854775807", namespace: "0", message: "123", text: String(repeating: "😀", count: 2000)) }
        tap()
        assert(received.count == 1 && received[0]["text"]!.utf8.count == 4096)
        assert(received[0]["text_truncated"] == "true" && received[0]["peer_id"] == "9223372036854775807")
        assert(Set(received[0].keys) == ["event", "action_id", "account_id", "peer_id", "message_namespace", "message_id", "text", "text_truncated"])
        assert(action.title == "Plugin [fixture]: Info")
        let otherOwner = UUID()
        assert(registry.unregister(owner: otherOwner, bytes: Data("{\"id\":\"info\"}".utf8)) == nil)
        assert(registry.actions(account: scope!.account).count == 2)
        assert(registry.unregister(owner: owner, bytes: Data("{\"id\":\"info\"}".utf8)) == nil)
        tap(); assert(received.count == 1)
        assert(register("{\"id\":\"info\",\"label\":\"Info\"}") == nil)
        tap(); assert(received.count == 1)
        registry.remove(owner: owner)
        tap(); assert(received.count == 1)
        assert(register("{\"id\":\"info\",\"label\":\"Info\"}") == nil)
        tap(); assert(received.count == 1) // Old menu token cannot target a replacement.
        registry.setAccount("account_other")
        registry.setAccount(scope!.account)
        tap(); assert(received.count == 1)
        assert(register("{\"id\":\"info\",\"label\":\"Info\"}") == "account_context_unavailable")
        let newScope = registry.currentScope()
        var captured: UUID?
        for index in 0..<9 {
            let newOwner = UUID()
            // Fill the global cap with independent sessions.
            let failure = registry.register(owner: newOwner, scope: newScope, plugin: "fixture", bytes: Data("{\"id\":\"info\",\"label\":\"Info\"}".utf8)) { _, token in captured = token }
            assert(failure == (index < 8 ? nil : "action_limit"))
        }
        assert(registry.actions(account: scope!.account).count == 8)
        assert(captured == nil) // Registration/enumeration never delivers anything.
        let staleAction = registry.actions(account: scope!.account)[0]
        registry.revoke()
        assert(!registry.isCurrent(newScope))
        assert(registry.currentScope()?.account == scope!.account)
        assert(registry.actions(account: scope!.account).isEmpty)
        registry.setAccount(scope!.account) // Same-account updates cannot resurrect authorization.
        registry.tap(staleAction, account: scope!.account, peer: "42", namespace: "0", message: "1", text: "Revoked")
        assert(captured == nil)
        assert(registry.register(owner: owner, scope: newScope, plugin: "fixture", bytes: Data("{\"id\":\"info\",\"label\":\"Info\"}".utf8)) { _, _ in
            assertionFailure("Revoked registration delivered")
        } == "account_context_unavailable")
        assert(registry.register(owner: owner, scope: registry.currentScope(), plugin: "fixture", bytes: Data("{\"id\":\"info\",\"label\":\"Info\"}".utf8)) { _, _ in } == nil)
        registry.setAccount(nil)
        assert(registry.actions(account: scope!.account).isEmpty)
        print("MessageActionsTests passed")
    }
}
