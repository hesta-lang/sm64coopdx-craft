import json
import tempfile
import unittest
from pathlib import Path

from extract_block_states import extract_block_states


class BlockStateExtractorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.report = self.root / "blocks.json"
        self.data = {
            "minecraft:stone": {"states": [{"id": 1, "default": True, "properties": {}}]},
            "minecraft:redstone_wire": {
                "properties": {"east": ["none", "side", "up"], "power": [str(i) for i in range(16)], "west": ["none", "side", "up"]},
                "states": [
                    {"id": 2, "default": True, "properties": {"east": "none", "power": "0", "west": "none"}},
                    {"id": 3, "properties": {"east": "side", "power": "15", "west": "up"}},
                ],
            },
            "minecraft:oak_door": {
                "properties": {"powered": ["true", "false"], "open": ["true", "false"]},
                "states": [{"id": 4, "default": True, "properties": {"open": "false", "powered": "false"}}],
            },
        }
        self.report.write_text(json.dumps(self.data), encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def test_preserves_state_ids_property_domains_and_defaults(self):
        out = self.root / "out"
        summary = extract_block_states(self.report, out, "26.3")
        catalog = json.loads((out / "block_states.json").read_text(encoding="utf-8"))
        self.assertEqual(summary["block_count"], 3)
        self.assertEqual(summary["state_count"], 4)
        wire = catalog["blocks"]["minecraft:redstone_wire"]
        self.assertEqual(wire["default_state_id"], 2)
        self.assertEqual(wire["properties"]["power"], [str(i) for i in range(16)])
        self.assertEqual([x["id"] for x in wire["states"]], [2, 3])

    def test_indexes_redstone_components_and_powered_blocks(self):
        out = self.root / "out"
        extract_block_states(self.report, out, "26.3")
        result = json.loads((out / "redstone_blocks.json").read_text(encoding="utf-8"))
        self.assertEqual(set(result["blocks"]), {"minecraft:redstone_wire", "minecraft:oak_door"})
        self.assertEqual(result["blocks"]["minecraft:redstone_wire"]["confidence"], "high")
        self.assertIn("state_property:powered", result["blocks"]["minecraft:oak_door"]["reasons"])

    def test_writes_compact_lua_lookup_modules(self):
        out = self.root / "out"
        extract_block_states(self.report, out, "26.3")
        lua = (out / "block_states.lua").read_text(encoding="utf-8")
        redstone = (out / "redstone_candidates.lua").read_text(encoding="utf-8")
        self.assertIn('["minecraft:redstone_wire"]', lua)
        self.assertIn('function M.get_properties', lua)
        self.assertIn('["minecraft:oak_door"]', redstone)

    def test_rejects_duplicate_global_state_ids(self):
        self.data["minecraft:dirt"] = {"states": [{"id": 1, "default": True, "properties": {}}]}
        self.report.write_text(json.dumps(self.data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "duplicated"):
            extract_block_states(self.report, self.root / "out", "26.3")

    def test_accepts_directory_containing_reports_subfolder(self):
        source = self.root / "data"
        reports = source / "reports"
        reports.mkdir(parents=True)
        (reports / "blocks.json").write_text(json.dumps(self.data), encoding="utf-8")
        result = extract_block_states(source, self.root / "out", "26.3")
        self.assertEqual(result["block_count"], 3)


if __name__ == "__main__":
    unittest.main()
