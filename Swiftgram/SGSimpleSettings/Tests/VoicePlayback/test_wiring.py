"""Static queue/settings integration checks, not a substitute for device playback."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[4]


def source(path):
    return (REPO / path).read_text()


class VoicePlaybackWiringTests(unittest.TestCase):
    def test_persistence_and_live_ui(self):
        settings = source("Swiftgram/SGSimpleSettings/Sources/SimpleSettings.swift")
        self.assertIn("case stopAfterVoiceMessage", settings)
        self.assertIn("Keys.stopAfterVoiceMessage.rawValue: false", settings)
        self.assertIn('@UserDefault(key: Keys.stopAfterVoiceMessage.rawValue)\n    public var stopAfterVoiceMessage: Bool', settings)
        ui = source("Swiftgram/SGSettingsUI/Sources/ReqGramSettingsController.swift")
        self.assertIn("settings.stopAfterVoiceMessage = value", ui)
        self.assertIn("settingName: .stopAfterVoiceMessage, value: settings.stopAfterVoiceMessage", ui)
        self.assertIn("UserDefault<Bool>.didChangeNotification", ui)
        self.assertIn('appendNotice("ReqGram.StopAfterVoiceMessage.Notice", section: .media, kind: .explanation)', ui)
        for lang in ("en", "ru"):
            strings = source(f"Swiftgram/SGStrings/Strings/{lang}.lproj/SGLocalizable.strings")
            for key in ("ReqGram.Media.Title", "ReqGram.StopAfterVoiceMessage", "ReqGram.StopAfterVoiceMessage.Notice"):
                self.assertEqual(len(re.findall(r'^"' + re.escape(key) + r'"\s*=', strings, re.M)), 1)

    def test_only_natural_voice_completion(self):
        player = source("submodules/TelegramUI/Sources/SharedMediaPlayer.swift")
        completion = player.split("private func armPlaybackCompletion", 1)[1].split("func control(_ action:", 1)[0]
        self.assertIn("state.item?.playbackData?.type == .voice", player)
        self.assertIn("isVoicePlayer: self.type == .voice, isVoiceMessage: isVoiceMessage", completion)
        self.assertIn("enabled: SGSimpleSettings.shared.stopAfterVoiceMessage", completion)
        stop = completion.split("if ReqGramVoicePlaybackPolicy.stopsAtEnd", 1)[1].split("switch self.playlist.looping", 1)[0]
        self.assertIn("self.stop()", stop)
        self.assertIn("self.playedToEnd?()", stop)
        self.assertIn("self.scheduledPlaybackAction = nil", stop)
        self.assertIn("self.scheduledStartTime = nil", stop)
        self.assertIn("return", stop)
        self.assertNotIn("control(.next)", stop)
        # Off/non-voice still reaches original looping and navigation; explicit controls bypass policy.
        self.assertIn("self.playlist.control(.next)", completion)
        self.assertNotIn("self.control(.next)", completion)
        controls = player.split("func control(_ action:", 1)[1]
        self.assertNotIn("stopAfterVoiceMessage", controls)
        self.assertIn("self.playlist.control(.next)", controls)
        self.assertIn("self.completionGate.consume(ticket)", completion)
        self.assertIn("strongSelf.completionGate.invalidate()", player)
        intent = controls.split("switch action", 1)[1].split("switch action", 1)[0]
        self.assertIn("case .next, .previous:", intent)
        self.assertIn("case .playback, .seek:", intent)
        self.assertIn("case .playback(.pause):", intent)
        self.assertIn("self.playbackItem != nil && self.scheduledPlaybackAction == nil", intent)
        pause = intent.split("case .playback(.pause):", 1)[1].split("case .playback, .seek:", 1)[0]
        self.assertNotIn("armPlaybackCompletion", pause)
        self.assertIn("self.completionGate.invalidate()", intent)
        self.assertIn("self.armPlaybackCompletion", intent)
        self.assertIn("func stop() {\n        self.completionGate.invalidate()", controls)

    def test_queue_entry_points_and_cleanup(self):
        manager = source("submodules/TelegramUI/Sources/MediaManager.swift")
        cleanup = manager.split("voiceMediaPlayer.playedToEnd =", 1)[1].split("voiceMediaPlayer.cancelled", 1)[0]
        self.assertIn("voiceMediaPlayer === strongSelf.voiceMediaPlayer", cleanup)
        self.assertIn("strongSelf.voiceMediaPlayer = nil", cleanup)
        opening = source("submodules/TelegramUI/Sources/OpenChatMessage.swift")
        self.assertIn("PeerMessagesMediaPlaylist(context:", opening)
        playlist = source("submodules/TelegramUI/Components/MediaManager/PeerMessagesMediaPlaylist/Sources/PeerMessagesMediaPlaylist.swift")
        self.assertIn("SharedMediaPlaybackData(type: .voice", playlist)
        self.assertIn("SharedMediaPlaybackData(type: .instantVideo", playlist)
        once = source("submodules/TelegramUI/Sources/Chat/ChatControllerOpenViewOnceMediaMessage.swift")
        self.assertIn("playlistLocation: .singleMessage(message.id)", once)


if __name__ == "__main__":
    unittest.main()
