"""Generate 05-message-info.ixplugin locally; never installs or makes live calls."""
import json
from pathlib import Path
import sys
import zipfile


def create(destination):
    manifest = dict(id="local.reqgram.message-info", name="Message info", version="1",
                    description="Shows selected text length and message ID only after a plugin menu tap.",
                    author="ReqGram example", entry="main.py", api_version="1",
                    permissions=["messages.context", "ui.notice"])
    source = (Path(__file__).resolve().parents[1] / "SDK" / "reqgram.py").read_text() + '''
client = None

def on_enable():
    global client
    client = Client(host_request)
    client.subscribe("message.action", "ui.action")
    client.enable_callbacks()
    client.register_message_action("info", "Message info")

def on_event(event):
    if event["event"] == "message.action" and event["action_id"] == "info":
        client.notice("Message info", "Text length: %d%s; message ID: %s" % (
            len(event["text"]), " (truncated)" if event["text_truncated"] == "true" else "",
            event["message_id"]))

def on_disable():
    global client
    # Native teardown removes registrations before this hook runs.
    client = None
'''
    with zipfile.ZipFile(destination, "x", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        archive.writestr("main.py", source)


if __name__ == "__main__":
    create(sys.argv[1] if len(sys.argv) > 1 else "05-message-info.ixplugin")
