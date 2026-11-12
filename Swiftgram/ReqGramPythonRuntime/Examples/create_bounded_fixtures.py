"""Generate deterministic, least-privileged ReqGram API fixtures.

The generated packages only use the documented host bridge.  They are intended
for local fake-host tests and do not install, start, or contact the network.
"""
import json
from pathlib import Path
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SDK = (ROOT / "SDK" / "reqgram.py").read_text()


FIXTURES = {
    "all-api": ({
        "id": "local.reqgram.fixture.all-api",
        "name": "Bounded all API fixture",
        "version": "1",
        "description": "Bounded, redacted coverage of every documented API, including consent-gated full access.",
        "author": "ReqGram tests",
        "entry": "main.py",
        "api_version": "1",
        "permissions": ["accounts.read", "peer.read", "chat.context",
                         "message.get", "message.history", "message.search", "messages.context", "ui.alert",
                          "ui.notice", "ios.safe", "storage", "log", "network", "full_access"],
        "capabilities": ["message.events", "message.send", "message.edit",
                         "message.delete", "message.forward"],
        "settings_schema": {"version": 1, "fields": [
            {"key": "enabled", "label": "Enable safe API checks", "type": "boolean",
             "default_value": True}
        ]},
    }, '''
client = None
report = {"version": 1, "methods": {}}

_SUITE_ACTION_ID = "safe_api_suite"
_UI_ACTION_ID = "safe_api_ui"
_PEER_ID = "4242"
_MESSAGE_ID = "4242_0_7"
_UNKNOWN_HISTORY_ANCHOR = "4242_0_2147483647"
_next_ui_phase = "alert"
_suite_running = False

def _check(name, call, expected_rejection=None, allow_success=False):
    """Record only status and an exception class; never persist returned user data."""
    try:
        call()
        passed = expected_rejection is None or allow_success
        detail = "ok" if passed else "unsafe_payload_accepted"
    except RuntimeError as error:
        try:
            failure = json.loads(str(error))
        except (TypeError, ValueError):
            failure = None
        passed = failure == expected_rejection
        detail = "safely_rejected" if passed else "unexpected_RuntimeError"
    except Exception as error:
        passed = False
        detail = "unexpected_" + type(error).__name__
    report["methods"][name] = {"status": "PASS" if passed else "FAIL", "detail": detail}

def _report_bytes():
    return json.dumps(report, sort_keys=True, separators=(",", ":")).encode("utf-8")

def _persist_and_log():
    # Storage is plugin-private. Logs contain method names/status only, never results or event data.
    client.save(_report_bytes())
    for name in sorted(report["methods"]):
        item = report["methods"][name]
        client.log("safe-suite %s %s %s" % (name, item["status"], item["detail"]))

def run_safe_suite():
    """Exercise non-UI APIs without issuing a valid mutation or network request."""
    global report, _suite_running
    # The host may synchronously deliver an action while enable is completing.
    # Keep the report transaction single-owner so persistence and per-method logs
    # cannot be interleaved or duplicated by a re-entrant invocation.
    if _suite_running:
        return report
    _suite_running = True
    report = {"version": 1, "methods": {}}
    try:
        _check("app_info", lambda: client.app_info())
        _check("settings", lambda: client.settings())
        _check("accounts", lambda: client.accounts())
        _check("account_context", lambda: client.account_context())
        # The native safe-suite runs against the user's local Postbox, which may
        # not contain the deterministic fixture peer.  Missing local data is a
        # documented, safe rejection; keep the operation and error exact so a
        # real provider/runtime failure still fails the suite.
        _check("peer", lambda: client.peer(4242),
               {"operation": "peer.lookup", "error": "peer_not_found"}, allow_success=True)
        _check("chat_context", lambda: client.chat_context(_PEER_ID),
               {"operation": "chat.context", "error": "peer_not_found"}, allow_success=True)
        _check("message", lambda: client.message(_PEER_ID, _MESSAGE_ID),
               {"operation": "message.get", "error": "peer_not_found"}, allow_success=True)
        # This is intentionally a syntactically valid, unknown anchor. A safe
        # host must reject it before native Postbox history is constructed.
        _check("history", lambda: client.history(_PEER_ID, limit=1, anchor_id=_UNKNOWN_HISTORY_ANCHOR),
               {"operation": "message.history", "error": "message_not_found"})
        _check("search", lambda: client.search(_PEER_ID, "fixture", limit=1), allow_success=True)

        _check("subscribe", lambda: client.subscribe("app.active", "ui.action", "message.change"))
        # on_enable already drained polling once before switching modes. In callback mode a poll must
        # now be rejected, proving that the one-way transition is enforced without competing drains.
        _check("poll", lambda: client.poll(), {"operation": "events.poll", "error": "callback_mode"})
        _check("unsubscribe", lambda: client.unsubscribe("app.active"))
        _check("watch_messages", lambda: client.watch_messages(_PEER_ID, [_MESSAGE_ID]))
        _check("unwatch_messages", lambda: client.unwatch_messages(_PEER_ID, [_MESSAGE_ID]))
        _check("event_status", lambda: client.event_status())

        # These malformed values fail current native shape validation before provider/network scheduling.
        # Required completion subscriptions are installed during on_enable before any probe is attempted.
        expected = lambda operation: {"operation": operation, "error": "invalid_payload"}
        _check("send_text", lambda: client.send_text("bad request id", "safe", _PEER_ID, "probe"), expected("message.send"))
        _check("edit_message", lambda: client.edit_message("bad request id", "safe", _PEER_ID, _MESSAGE_ID, "probe"), expected("message.edit"))
        _check("delete_message", lambda: client.delete_message("bad request id", "safe", _PEER_ID, _MESSAGE_ID, "local"), expected("message.delete"))
        _check("forward_message", lambda: client.forward_message("bad request id", "safe", _PEER_ID, _MESSAGE_ID, _PEER_ID), expected("message.forward"))
        _check("network_request", lambda: client.network_request("not a URL"), expected("network.request"))
        _check("cancel_network_request", lambda: client.cancel_network_request(0), expected("network.cancel"))
        native = client.native_class_call("UIView", "new")
        handle = native.get("handle", "fixture-handle")
        _check("native_class_call", lambda: native)
        _check("native_instance_call", lambda: client.native_instance_call(handle, "description"))
        _check("native_get", lambda: client.native_get(handle, "alpha"))
        _check("native_set", lambda: client.native_set(handle, "alpha", 0.5))
        _check("native_release", lambda: client.native_release(handle))
        _check("output_volume", lambda: client.output_volume())
        # Exercise the setter contract without changing the user's system volume.
        _check("set_output_volume", lambda: client.set_output_volume(0.5))
        _check("ios_app_info", lambda: client.ios_app_info())
        _check("ios_alert", lambda: client.ios_alert("ReqGram safe check", "Local API check only."))
        _check("ios_notice", lambda: client.ios_notice("ReqGram safe check", "Local API check only."))
        _check("ios_output_volume", lambda: client.ios_output_volume())
        _check("ios_set_output_volume", lambda: client.ios_set_output_volume(0.5))
        _check("ios_account_context", lambda: client.ios_account_context())
        _check("ios_peer_lookup", lambda: client.ios_peer_lookup(_PEER_ID))
        _check("ios_message_get", lambda: client.ios_message_get(_PEER_ID, _MESSAGE_ID))

        # MTProto probes remain malformed so the safe fixture never performs a
        # real account/network call. They still exercise both public wrappers.
        _check("mtproto_raw", lambda: client.mtproto_raw("bad request id", bytes([1, 0, 0, 0])), expected("mtproto.raw"))
        _check("mtproto_json", lambda: client.mtproto_json("bad request id", {"constructor": "0x1", "arguments": []}), expected("mtproto.json"))

        _check("unregister_message_action", lambda: client.unregister_message_action(_SUITE_ACTION_ID))
        _check("register_message_action", lambda: client.register_message_action(_SUITE_ACTION_ID, "Run safe API checks"))
        _check("load", lambda: client.load())
        _check("save", lambda: client.save(b"{}"))
        _check("log", lambda: client.log("safe-suite log probe"))

        # Callback mode was selected only after an initial poll in on_enable; this is idempotent.
        _check("enable_callbacks", lambda: client.enable_callbacks())
        _persist_and_log()
        return report
    finally:
        _suite_running = False

def run_alert_phase():
    """Issue exactly one tap-gated UI request; never combine it with notice."""
    _check("alert", lambda: client.alert("ReqGram safe check", "Local API check only."))
    _persist_and_log()
    return report

def run_notice_phase():
    """Issue exactly one tap-gated UI request; never combine it with alert."""
    _check("notice", lambda: client.notice("ReqGram safe check", "Local API check only."))
    _persist_and_log()
    return report

def run_ui_phase():
    """Alternate the single UI action while issuing only one UI request per tap."""
    global _next_ui_phase
    if _next_ui_phase == "alert":
        _check("alert", lambda: client.alert("ReqGram safe check", "Local API check only."))
        if report["methods"]["alert"]["status"] == "PASS":
            _next_ui_phase = "notice"
    else:
        _check("notice", lambda: client.notice("ReqGram safe check", "Local API check only."))
        if report["methods"]["notice"]["status"] == "PASS":
            _next_ui_phase = "alert"
    _persist_and_log()
    return report

def on_enable():
    global client
    client = Client(host_request)
    # Registration is optional: hosts without message-menu support must still get
    # the automatic, synchronous safe report.
    client.subscribe("message.action", "message.mutation", "network.response")
    client.subscribe("ui.action")
    for action_id, label in ((_SUITE_ACTION_ID, "Run safe API checks"),
                             (_UI_ACTION_ID, "Run safe UI check")):
        try:
            client.register_message_action(action_id, label)
        except Exception:
            pass
    client.poll()
    client.enable_callbacks()
    # The fixture is self-testing on install; actions are only optional rerun/UI entry points.
    run_safe_suite()

def on_event(event):
    # Synchronous and bounded: no threads, sleeps, raw event persistence, or user-data logging.
    if event.get("event") != "message.action":
        return
    action = event.get("action_id")
    if action == _SUITE_ACTION_ID:
        run_safe_suite()
    elif action == _UI_ACTION_ID:
        run_ui_phase()

def on_disable():
    global client
    client = None
'''),
    "message-watch": ({
        "id": "local.reqgram.fixture.message-watch",
        "name": "Message watch fixture",
        "version": "1",
        "description": "Explicit message change watch and callback fixture.",
        "author": "ReqGram tests",
        "entry": "main.py",
        "api_version": "1",
        "permissions": [],
        "capabilities": ["message.events"],
    }, '''
client = None
observed = []

def on_enable():
    global client
    client = Client(host_request)
    client.subscribe("message.change")
    client.watch_messages("4242", ["4242_0_7"])
    client.enable_callbacks()

def on_event(event):
    observed.append(event)

def on_disable():
    global client
    client = None
'''),
    "message-mutations": ({
        "id": "local.reqgram.fixture.message-mutations",
        "name": "Message mutation fixture",
        "version": "1",
        "description": "Bounded text mutation wire fixture.",
        "author": "ReqGram tests",
        "entry": "main.py",
        "api_version": "1",
        "permissions": [],
        "capabilities": ["message.send", "message.edit", "message.delete", "message.forward"],
    }, '''
client = None

def on_enable():
    global client
    client = Client(host_request)
    client.subscribe("message.mutation")

def send():
    return client.send_text("send-1", "send-key", "4242", "hello", "4242_0_7")

def edit():
    return client.edit_message("edit-1", "edit-key", "4242", "4242_0_7", "edited")

def delete():
    return client.delete_message("delete-1", "delete-key", "4242", "4242_0_7")

def forward():
    return client.forward_message("forward-1", "forward-key", "4242", "4242_0_7", "4343")

def on_disable():
    global client
    client = None
'''),
    "network": ({
        "id": "local.reqgram.fixture.network",
        "name": "Network fixture",
        "version": "1",
        "description": "Deterministic fake-host request and cancellation fixture.",
        "author": "ReqGram tests",
        "entry": "main.py",
        "api_version": "1",
        "permissions": ["network", "network.insecure"],
    }, '''
client = None

def on_enable():
    global client
    client = Client(host_request)
    client.subscribe("network.response")

def request():
    return client.network_request("http://fixture.invalid/echo", method="POST",
                                  headers={"X-Fixture": "yes"}, body=b"hello", timeout=3)

def cancel(request_id):
    return client.cancel_network_request(request_id)

def on_disable():
    global client
    client = None
    '''),
    "broad-read-ui-storage": ({
        "id": "local.reqgram.fixture.broad-read-ui-storage",
        "name": "Broad read UI storage fixture",
        "version": "1",
        "description": "Least-privilege fixture for documented read, UI, action, settings, storage and log APIs.",
        "author": "ReqGram tests",
        "entry": "main.py",
        "api_version": "1",
        "permissions": ["accounts.read", "peer.read", "chat.context", "message.get",
                         "message.history", "message.search", "messages.context", "ui.alert", "ui.notice",
                        "storage", "log"],
        "settings_schema": {"version": 1, "fields": [
            {"key": "enabled", "label": "Enabled", "type": "boolean", "default_value": True}
        ]},
    }, '''
client = None

def on_enable():
    global client
    client = Client(host_request)

def all_calls():
    """Exercise every remaining documented Python SDK method once."""
    return {
        "app_info": client.app_info(),
        "settings": client.settings(),
        "accounts": client.accounts(),
        "account_context": client.account_context(),
        "peer": client.peer(4242),
        "chat_context": client.chat_context(4242),
        "message": client.message(4242, "4242_0_7"),
        "history": client.history(4242, limit=2, anchor_id="4242_0_6"),
        "search": client.search(4242, "fixture", limit=2),
        "unsubscribe": client.unsubscribe(),
        "unwatch_messages": client.unwatch_messages(4242, ["4242_0_7"]),
        "event_status": client.event_status(),
        "alert": client.alert("Fixture", "Alert"),
        "notice": client.notice("Fixture", "Notice"),
        "register_message_action": client.register_message_action("fixture", "Fixture action"),
        "unregister_message_action": client.unregister_message_action("fixture"),
        "load": client.load(),
        "save": client.save(b"fixture-storage"),
        "log": client.log("fixture-log"),
    }

def on_disable():
    global client
    client = None
'''),
}


def _write_entry(archive, name, data):
    """Write bytes with stable ZIP metadata (including the DOS timestamp)."""
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 0
    info.external_attr = 0
    archive.writestr(info, data)


def create(destination, fixture=None):
    """Create one package at a file path, or all packages in a directory.

    With no fixture, *destination* is always a directory (and is created). With
    a fixture, an existing directory receives ``<fixture>.ixplugin``; otherwise
    the destination is the package file and its parent is created. Packages
    are deliberately exclusive: an existing output is never silently replaced.
    """
    destination = Path(destination)
    selected = FIXTURES if fixture is None else {fixture: FIXTURES[fixture]}
    if fixture is None:
        if destination.exists() and not destination.is_dir():
            raise NotADirectoryError(destination)
        destination.mkdir(parents=True, exist_ok=True)
    elif destination.exists() and destination.is_dir():
        pass
    elif not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
    for name, (manifest, body) in selected.items():
        path = destination / (name + ".ixplugin") if destination.is_dir() else destination
        with zipfile.ZipFile(path, "x", compression=zipfile.ZIP_DEFLATED) as archive:
            _write_entry(archive, "manifest.json", json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode())
            _write_entry(archive, "main.py", (SDK + body).encode())


if __name__ == "__main__":
    create(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
