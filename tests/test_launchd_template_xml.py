"""Parse launchd templates without installing or executing any launch job."""
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = (
    "com.jleechan.agy-shim.plist.template",
    "smartclaw.schedule.skeptic-auto-merge.plist.template",
    "smartclaw.schedule.slack-digest-rollup.plist.template",
)


class LaunchdTemplateXMLTests(unittest.TestCase):
    def test_templates_are_valid_plists(self):
        for name in TEMPLATES:
            with self.subTest(template=name):
                data = plistlib.loads((ROOT / "launchd" / name).read_bytes())
                self.assertIsInstance(data["Label"], str)
                self.assertIsInstance(data["ProgramArguments"], list)
                self.assertTrue(data["ProgramArguments"])

    def test_command_line_double_hyphens_are_preserved(self):
        data = plistlib.loads(
            (ROOT / "launchd" / TEMPLATES[2]).read_bytes()
        )
        self.assertIn("--hours", data["ProgramArguments"])


if __name__ == "__main__":
    unittest.main()
