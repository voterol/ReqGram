"""Create a self-authored, account-free main-client UI example."""
import json
import sys
import zipfile

manifest = dict(id="local.reqgram.alert", name="Host alert example", version="1",
                description="Shows a native alert; no account or network operations.",
                author="ReqGram example", entry="main.py", api_version="1",
                permissions=["ui.alert", "log"])
source = '''import json

def on_enable():
    info = json.loads(host_request("app.info"))
    host_request("events.subscribe", b'["ui.action"]')
    request = json.loads(host_request("ui.alert", json.dumps({
        "title": "Hello from Python",
        "message": "Running in %s %s on %s" % (info["client"], info["version"], info["platform"])
    }).encode()))
    host_request("log", ("Alert queued: " + request["request_id"]).encode())

def on_disable():
    host_request("log", b"Stopped; host releases subscriptions and alert")
'''
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("manifest.json", json.dumps(manifest))
    archive.writestr("main.py", source)
