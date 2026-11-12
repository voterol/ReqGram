"""Small injected-host SDK. No native imports and no full Telegram API."""
import json


class Client:
    def __init__(self, host_request):
        self._host = host_request

    def _json(self, operation, payload=None):
        result = self._host(operation) if payload is None else self._host(
            operation, json.dumps(payload).encode('utf-8'))
        return json.loads(result) if result else None

    def app_info(self):
        return self._json('app.info')

    def settings(self):
        return self._json('settings')

    def accounts(self):
        return self._json('accounts.list')

    def account_context(self):
        return self._json('account.context')

    def peer(self, peer_id):
        return self._json('peer.lookup', {'peer_id': peer_id})

    def chat_context(self, peer_id):
        """Read a bounded, local chat DTO. Requires chat.context."""
        return self._json('chat.context', {'peer_id': str(peer_id)})

    def message(self, peer_id, message_id):
        """Read one message DTO using ``peer_id_namespace_message_id``."""
        return self._json('message.get', {'peer_id': str(peer_id), 'message_id': message_id})

    def history(self, peer_id, limit=20, anchor_id=None):
        """Read at most 50 locally cached messages; inspect hole_before/hole_after/network_fetched."""
        payload = {'peer_id': str(peer_id), 'limit': limit}
        if anchor_id is not None:
            payload['anchor_id'] = anchor_id
        return self._json('message.history', payload)

    def search(self, peer_id, query, limit=20):
        """Search up to 50 locally indexed plain-text messages in one peer.

        This operation never fetches from Telegram; inspect ``network_fetched``
        in the response (it is always ``False`` for this local API).
        """
        return self._json('message.search', {
            'peer_id': str(peer_id), 'query': query, 'limit': limit})

    def subscribe(self, *events):
        return self._json('events.subscribe', list(events))

    def unsubscribe(self, *events):
        return self._json('events.unsubscribe', list(events))

    def watch_messages(self, peer_id, message_ids):
        """Watch up to eight explicit cloud message IDs; never discovers a peer stream."""
        return self._json('message.events.watch', {
            'peer_id': str(peer_id), 'message_ids': [str(value) for value in message_ids]})

    def unwatch_messages(self, peer_id, message_ids):
        return self._json('message.events.unwatch', {
            'peer_id': str(peer_id), 'message_ids': [str(value) for value in message_ids]})

    def send_text(self, request_id, idempotency_key, peer_id, text, reply_to_message_id=None):
        """Queue one plain-text message locally. Requires capability ``message.send``.

        Subscribe to ``message.mutation`` first. A result with status ``queued`` and
        consistency ``local`` only confirms local enqueue, never server delivery.
        """
        payload = {'request_id': request_id, 'idempotency_key': idempotency_key,
                   'peer_id': str(peer_id), 'text': text}
        if reply_to_message_id is not None:
            payload['reply_to_message_id'] = str(reply_to_message_id)
        return self._json('message.send', payload)

    def edit_message(self, request_id, idempotency_key, peer_id, message_id, text):
        """Edit one existing cloud text message.

        Requires ``message.edit`` and a ``message.mutation`` subscription. The
        terminal event has status ``succeeded`` (changed), ``unchanged``, or a
        stable error code; it never claims delivery beyond the native result.
        Reusing the same idempotency key and exact payload replays that terminal
        result in this enabled session; a different payload is a conflict.
        """
        return self._json('message.edit', {
            'request_id': request_id, 'idempotency_key': idempotency_key,
            'peer_id': str(peer_id), 'message_id': str(message_id), 'text': text})

    def poll(self):
        return self._json('events.poll')

    def delete_message(self, request_id, idempotency_key, peer_id, message_id, scope='local'):
        """Delete one eligible cloud message locally.

        ``scope`` must be ``local``. ``everyone`` is intentionally unsupported
        until the host can provide accurate remote-capable semantics. Completion
        is a ``message.mutation`` event with local consistency only.
        """
        return self._json('message.delete', {'request_id': request_id, 'idempotency_key': idempotency_key,
                                               'peer_id': str(peer_id), 'message_id': str(message_id), 'scope': scope})

    def forward_message(self, request_id, idempotency_key, source_peer_id,
                        source_message_id, destination_peer_id):
        """Queue one eligible cloud message for forwarding to one cloud peer.

        Requires ``message.forward`` and a ``message.mutation`` subscription.
        Completion reports ``queued``/``local`` only, never server delivery.
        """
        return self._json('message.forward', {
            'request_id': request_id, 'idempotency_key': idempotency_key,
            'source_peer_id': str(source_peer_id),
            'source_message_id': str(source_message_id),
            'destination_peer_id': str(destination_peer_id)})

    def enable_callbacks(self):
        """Opt this session into synchronous main.py on_event(dict) delivery.

        One-way until re-enable; poll then raises callback_mode. The hook must
        return promptly. Delivery starts only after on_enable succeeds.
        """
        return self._json('events.callback')

    def event_status(self):
        """Session-only mode, failed, queued, dropped and delivered counters."""
        return self._json('events.status')

    def alert(self, title, message):
        return self._json('ui.alert', {'title': title, 'message': message})

    def notice(self, title, message):
        """Show a non-destructive notice with a single OK action."""
        return self._json('ui.notice', {'title': title, 'message': message})

    def register_message_action(self, action_id, label):
        """Requires messages.context and a message.action subscription; no data until tap."""
        return self._json('messages.register', {'id': action_id, 'label': label})

    def unregister_message_action(self, action_id):
        return self._json('messages.unregister', {'id': action_id})

    def load(self):
        return self._host('load')

    def save(self, value):
        return self._host('save', value)

    def log(self, message):
        return self._host('log', message.encode('utf-8'))

    def network_request(self, url, method='GET', headers=None, body=None, timeout=15):
        """Queue a bounded request. Subscribe to ``network.response`` first.

        Response bodies are returned base64-encoded in the event; the host never
        supplies cookies, credentials, Telegram sessions, or keychain values.
        HTTP requires the manifest's explicit ``network.insecure`` permission.
        """
        payload = {'url': url, 'method': method, 'headers': headers or {},
                   'timeout': timeout}
        if body is not None:
            import base64
            payload['body'] = base64.b64encode(body).decode('ascii')
        return self._json('network.request', payload)

    def cancel_network_request(self, request_id):
        """Cancel a pending request; completion wins if it already finished."""
        return self._json('network.cancel', {'request_id': request_id})

    def mtproto_raw(self, request_id, body, timeout=15):
        import base64
        return self._json('mtproto.raw', {'request_id': request_id, 'body': base64.b64encode(body).decode('ascii'), 'timeout': timeout})

    def mtproto_json(self, request_id, request, timeout=15):
        return self._json('mtproto.json', {'request_id': request_id, 'request': request, 'timeout': timeout})

    def native_class_call(self, class_name, selector, *arguments):
        """Call a validated Objective-C class method. Requires ``full_access``."""
        return self._json('native.class_call', {
            'class': class_name, 'selector': selector, 'arguments': list(arguments)})

    def native_instance_call(self, handle, selector, *arguments):
        """Call a validated method on a session-owned opaque handle."""
        return self._json('native.instance_call', {
            'handle': handle, 'selector': selector, 'arguments': list(arguments)})

    def native_get(self, handle, property_name):
        return self._json('native.get', {'handle': handle, 'property': property_name})

    def native_set(self, handle, property_name, value):
        return self._json('native.set', {
            'handle': handle, 'property': property_name, 'value': value})

    def native_release(self, handle):
        return self._json('native.release', {'handle': handle})

    def output_volume(self):
        return self._json('native.audio.output_volume')

    def set_output_volume(self, value):
        return self._json('native.audio.set_output_volume', {'value': value})

    # Explicitly bounded iOS facade. These names never accept selectors,
    # classes, handles, or arbitrary native arguments.
    def ios_app_info(self):
        return self._json('ios.safe.app_info')

    def ios_alert(self, title, message):
        return self._json('ios.safe.alert', {'title': title, 'message': message})

    def ios_notice(self, title, message):
        return self._json('ios.safe.notice', {'title': title, 'message': message})

    def ios_output_volume(self):
        return self._json('ios.safe.output_volume')

    def ios_set_output_volume(self, value):
        return self._json('ios.safe.set_output_volume', {'value': value})

    def ios_account_context(self):
        return self._json('ios.safe.account_context')

    def ios_peer_lookup(self, peer_id):
        return self._json('ios.safe.peer_lookup', {'peer_id': peer_id})

    def ios_message_get(self, peer_id, message_id):
        return self._json('ios.safe.message_get', {'peer_id': str(peer_id), 'message_id': message_id})
