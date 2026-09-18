import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import skill_paths

class SkillPathsTest(unittest.TestCase):
    def test_rejects_path_traversal(self):
        with self.assertRaises(ValueError):
            skill_paths.candidates("../secret")

    def test_claude_root_is_a_candidate(self):
        self.assertIn(".claude", [p.parts[-4] for p in skill_paths.candidates("x")])

    @patch.object(Path, "is_file", return_value=False)
    def test_missing_skill(self, _is_file):
        self.assertIsNone(skill_paths.resolve("missing"))

    @patch.object(Path, "is_file", side_effect=lambda: True)
    def test_returns_first_installed_candidate(self, _is_file):
        result = skill_paths.resolve("target")
        self.assertIsNotNone(result)
        self.assertEqual(result.parts[-2], "target")

if __name__ == "__main__":
    unittest.main()
