"""Small, deliberately bounded ExteraGram-shaped compatibility facade.

This module adapts names used by a narrow class of ExteraGram plugins to the
ReqGram v1 ``Client``.  It is not an Android runtime and does not provide
arbitrary native or Telegram method invocation.
"""
from reqgram import Client


class AppEvent:
    """Event names accepted by :meth:`Client.subscribe`."""

    ACTIVE = "app.active"
    INACTIVE = "app.inactive"
    UI_ACTION = "ui.action"
    NETWORK_RESPONSE = "network.response"
    MESSAGE_ACTION = "message.action"
    MESSAGE_CHANGE = "message.change"
    MESSAGE_MUTATION = "message.mutation"

    # Common ExteraGram spellings.
    APP_ACTIVE = ACTIVE
    APP_INACTIVE = INACTIVE


class BasePlugin:
    """Lifecycle and bounded host helpers for a compatibility plugin.

    A plugin should subclass this class and implement ``on_plugin_load`` and
    optionally ``on_plugin_unload``.  The package's ``main.py`` must still
    expose ReqGram's module hooks and call ``plugin.on_enable()`` and
    ``plugin.on_disable()``; the runtime does not discover Android plugin
    classes.
    """

    def __init__(self, host_request):
        self.client = Client(host_request)

    def on_plugin_load(self):
        """Compatibility lifecycle hook; override in the plugin."""

    def on_plugin_unload(self):
        """Compatibility lifecycle hook; override in the plugin."""

    def on_enable(self):
        return self.on_plugin_load()

    def on_disable(self):
        return self.on_plugin_unload()

    # Message-action wrappers: registration remains tap-gated by the host.
    def add_message_action(self, action_id, label):
        return self.client.register_message_action(action_id, label)

    def remove_message_action(self, action_id):
        return self.client.unregister_message_action(action_id)

    # UI wrappers retain ReqGram's permission, subscription, rate and size
    # checks.  They do not expose arbitrary UIKit or Android UI.
    def show_alert(self, title, message):
        return self.client.alert(title, message)

    def show_notice(self, title, message):
        return self.client.notice(title, message)

    def send_message(self, request_id, idempotency_key, peer_id, text,
                     reply_to_message_id=None):
        return self.client.send_text(
            request_id, idempotency_key, peer_id, text, reply_to_message_id)

    def app_info(self):
        return self.client.ios_app_info()

    def output_volume(self):
        return self.client.ios_output_volume()

    def set_output_volume(self, value):
        return self.client.ios_set_output_volume(value)


def _unsupported(name):
    raise NotImplementedError(
        "%s is Android-only and unsupported by the ReqGram iOS facade" % name)


class MethodHook:
    def __init__(self, *args, **kwargs):
        _unsupported("MethodHook")


def java(*args, **kwargs):
    _unsupported("java")


def dynamic_proxy(*args, **kwargs):
    _unsupported("dynamic_proxy")
