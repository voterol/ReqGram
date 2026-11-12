from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]

class SettingsTransferWiringTests(unittest.TestCase):
    def test_allowlist_is_explicit_and_safe(self):
        source = (ROOT / "SGSimpleSettings/Sources/ReqGramSettingsTransfer.swift").read_text()
        self.assertIn('public static let formatVersion = 1', source)
        self.assertIn('options: [.sortedKeys, .prettyPrinted]', source)
        for forbidden in ("token", "secret", "session", "plugin", "account", "server"):
            self.assertNotIn(forbidden, source.lower())

    def test_ui_is_wired_to_transfer(self):
        controller = (ROOT / "SGSettingsUI/Sources/ReqGramSettingsController.swift").read_text()
        self.assertIn("ReqGramSettingsTransfer", controller)
        self.assertIn("UIDocumentPickerViewController", controller)
        self.assertIn(".atomic", controller)

if __name__ == "__main__": unittest.main()
