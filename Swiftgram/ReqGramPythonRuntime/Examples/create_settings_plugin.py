"""Run with Python 3: python3 create_settings_plugin.py [output.ixplugin].

Standard library only; run this generator on the developer's computer.
ZIP_STORED avoids requiring zlib compression. Plugin code uses bundled json.
"""
import json
import sys
import zipfile

manifest = {
    "id": "local.example.settings", "name": "Settings example", "version": "1",
    "description": "Self-authored local settings and logging example",
    "author": "Local developer", "entry": "main.py", "api_version": "1",
    "permissions": ["log"],
    "settings_transfer": True,
    "settings_schema": {"version": 1, "fields": [
        {"key": "enabled", "label": "Enabled", "type": "boolean", "default_value": True, "transferable": True},
        {"key": "greeting", "label": "Greeting", "type": "string", "default_value": "Hello", "transferable": True},
        {"key": "style", "label": "Style", "type": "selection", "default_value": "quiet",
          "options": ["quiet", "verbose"], "transferable": True},
    ]},
}
source = '''import json
def on_enable():
    settings = json.loads(host_request("settings"))
    host_request("log", ("Settings: " + json.dumps(settings, sort_keys=True)).encode())
def on_disable():
    host_request("log", b"Settings example stopped")
'''
with zipfile.ZipFile(sys.argv[1] if len(sys.argv) > 1 else "settings-example.ixplugin", "w", compression=zipfile.ZIP_STORED) as archive:
    archive.writestr("manifest.json", json.dumps(manifest))
    archive.writestr("main.py", source)
