"""Generate a local, account/network-free callback example; does not install it."""
import json
from pathlib import Path
import sys
import zipfile


def create(destination):
    manifest = dict(id="local.reqgram.events", name="Event callback example", version="1",
                    description="Counts app lifecycle events in plugin storage. No account or network access.",
                    author="ReqGram example", entry="main.py", api_version="1",
                    permissions=["storage", "log"])
    sdk = (Path(__file__).resolve().parents[1] / "SDK" / "reqgram.py").read_text()
    source = sdk + '''
client = None
count = 0

def on_enable():
    global client, count
    client = Client(host_request)
    count = int(client.load() or b"0")
    client.subscribe("app.active", "app.inactive")
    client.enable_callbacks()

def on_event(event):
    global count
    count += 1
    client.save(str(count).encode("ascii"))
    client.log("%s count=%d" % (event["event"], count))

def on_disable():
    global client
    client = None
'''
    with zipfile.ZipFile(destination, "x", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        archive.writestr("main.py", source)


if __name__ == "__main__":
    create(sys.argv[1])
