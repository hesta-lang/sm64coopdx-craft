import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from import_minecraft import import_and_transpile


class ImporterBlockCatalogIntegrationTests(unittest.TestCase):
    def test_importer_can_attach_26_3_block_catalog(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "java"
            source.mkdir()
            (source / "Example.java").write_text("class Example {}", encoding="utf-8")
            report = root / "blocks.json"
            report.write_text(json.dumps({
                "minecraft:redstone_wire": {
                    "properties": {"power": ["0", "1"]},
                    "states": [
                        {"id": 10, "default": True, "properties": {"power": "0"}},
                        {"id": 11, "properties": {"power": "1"}},
                    ],
                }
            }), encoding="utf-8")
            fake_transpile = {"classes": 1, "methods_seen": 0, "generated_methods": {"lua": 0, "c": 0}}
            with patch("import_minecraft.transpile", return_value=fake_transpile):
                result = import_and_transpile(
                    source, root / "out", "lua",
                    block_report=report, minecraft_version="26.3",
                )
            self.assertEqual(result["minecraft_version"], "26.3")
            self.assertEqual(result["block_state_catalog"]["state_count"], 2)
            self.assertTrue((root / "out" / "block_states" / "block_states.lua").is_file())
            saved = json.loads((root / "out" / "import_report.json").read_text(encoding="utf-8"))
            self.assertEqual(saved["block_state_catalog"]["block_count"], 1)


if __name__ == "__main__":
    unittest.main()
