"""Source integration checks; run without building the iOS application."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]


class PresentationWiringTests(unittest.TestCase):
    def test_localized_root_controls(self):
        controller = (ROOT / "SGSettingsUI/Sources/ReqGramSettingsController.swift").read_text()
        root = controller.split("private func reqGramBuiltInPluginsController")[0]
        keys = set(re.findall(r'i18n\("([^"]+)"', root))
        keys.update(re.findall(r'appendNotice\("([^"]+)"', root))
        for language in ("en", "ru"):
            strings = (ROOT / f"SGStrings/Strings/{language}.lproj/SGLocalizable.strings").read_text()
            available = set(re.findall(r'^"([^"]+)"\s*=', strings, re.MULTILINE))
            self.assertEqual(keys - available, set(), language)

    def test_shared_rendering_authority(self):
        repo = ROOT.parent
        helper = (ROOT / "AyuGram/Sources/AyuUtils.swift").read_text()
        self.assertIn("ReqGramPresentationPolicy.deletedMessageAlpha(", helper)
        self.assertIn("percent: settings.reqGramDeletedOpacityPercent", helper)
        for relative in (
            "submodules/TelegramUI/Sources/AyuSavedDeletedMessageItem.swift",
            "submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift",
        ):
            self.assertIn("AyuUtils.deletedMessageAlpha", (repo / relative).read_text())

    def test_warning_and_plugin_scope(self):
        controller = (ROOT / "SGSettingsUI/Sources/ReqGramSettingsController.swift").read_text()
        self.assertIn('appendNotice("Settings.Telegram1211LegacyDesign.Notice", section: .presentation, kind: .warning)', controller)
        plugin_code = controller.split("private func reqGramBuiltInPluginsController")[1]
        self.assertNotIn("reqGramCompactDescriptions", plugin_code)
        # "Legacy Gift Details" plugin was removed entirely; its notice and
        # settings key must not reappear.
        self.assertNotIn("DeletedGiftSender", plugin_code)
        self.assertNotIn("DeletedGiftSending", plugin_code)
        self.assertIn("text: description", plugin_code)

    def test_deleted_opacity_lives_only_in_ayugram(self):
        """The fade/opacity controls are owned by the AyuGram section exclusively."""
        ayu = (ROOT / "SGSettingsUI/Sources/AyuSettingsController.swift").read_text()
        reqgram = (ROOT / "SGSettingsUI/Sources/ReqGramSettingsController.swift").read_text()
        # Toggle, slider and warning notice all render from the AyuGram .marks section.
        self.assertIn("settingName: .ayuSemiTransparentDeleted", ayu)
        self.assertIn('title: i18n("ReqGram.DeletedOpacity", lang)', ayu)
        self.assertIn("value: Int32(settings.reqGramDeletedOpacityPercent)", ayu)
        self.assertIn('i18n("ReqGram.DeletedOpacity.Notice", lang)', ayu)
        # The slider writes the surviving storage key, which clamps itself.
        self.assertIn("SGSimpleSettings.shared.reqGramDeletedOpacityPercent = Int(value)", ayu)
        # No duplicate copy left in the ReqGram screen.
        self.assertNotIn("DeletedOpacity", reqgram)
        self.assertNotIn("ayuSemiTransparentDeleted", reqgram)
        # The dead legacy key is gone entirely.
        settings = (ROOT / "SGSimpleSettings/Sources/SimpleSettings.swift").read_text()
        self.assertNotIn("ayuDeletedOpacity", settings)
        self.assertNotIn("ayuDeletedOpacity", ayu)

    def test_localized_ayugram_deleted_opacity_keys(self):
        ayu = (ROOT / "SGSettingsUI/Sources/AyuSettingsController.swift").read_text()
        # Skip runtime-interpolated keys; only literal keys can be checked statically.
        keys = {k for k in re.findall(r'i18n\("([^"]+)"', ayu) if "\\(" not in k}
        self.assertIn("ReqGram.DeletedOpacity", keys)
        self.assertIn("ReqGram.DeletedOpacity.Notice", keys)
        for language in ("en", "ru"):
            strings = (ROOT / f"SGStrings/Strings/{language}.lproj/SGLocalizable.strings").read_text()
            available = set(re.findall(r'^"([^"]+)"\s*=', strings, re.MULTILINE))
            self.assertEqual(keys - available, set(), language)


if __name__ == "__main__":
    unittest.main()
