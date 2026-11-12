"""Generate a reviewed-source example, including the SDK without global imports."""
import json
from pathlib import Path
import sys
import zipfile

manifest = {
    'id': 'example.accounts', 'name': 'Account summary', 'version': '1',
    'description': 'Reads a session account snapshot; displays only its count.',
    'author': 'Local example', 'entry': 'main.py', 'api_version': '1',
    'permissions': ['accounts.read', 'ui.alert'],
    'settings_schema': {'version': 1, 'fields': [
        {'key': 'show_summary', 'label': 'Show summary', 'type': 'boolean',
         'default_value': True}]},
}
source = Path(__file__).resolve().parents[1].joinpath('SDK/reqgram.py').read_text()
source += '''
client = None

def on_enable():
    global client
    client = Client(host_request)
    accounts = client.accounts()
    context = client.account_context()
    assert context['consistency'] == 'session_snapshot'
    client.subscribe('app.active', 'app.inactive', 'ui.action')
    if client.settings()['show_summary']:
        client.alert('Accounts', str(len(accounts['accounts'])) + ' available at enable time')
    # Return immediately. poll() drains events when explicitly invoked; no busy loop.

def on_disable():
    global client
    # Native subscriptions/UI already closed; no host calls during teardown.
    client = None
'''
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('manifest.json', json.dumps(manifest))
    archive.writestr('main.py', source)
