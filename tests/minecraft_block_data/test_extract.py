import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from extract import extract_from_jar


class BlockDataExtractorTests(unittest.TestCase):
    def make_fixture_jar(self, path: Path) -> None:
        resources = {
            "assets/minecraft/blockstates/stone.json": {
                "variants": {"": {"model": "block/stone"}}
            },
            "assets/minecraft/models/block/stone.json": {
                "parent": "block/cube_all",
                "textures": {"all": "block/stone"},
                "elements": [{
                    "from": [0, 0, 0],
                    "to": [16, 16, 16],
                    "faces": {"north": {"texture": "#all", "cullface": "north"}}
                }]
            },
            "assets/minecraft/sounds.json": {
                "block.stone.hit": {"sounds": ["block/stone/hit"]}
            },
            "data/minecraft/tags/block/mineable/pickaxe.json": {
                "replace": False,
                "values": ["minecraft:stone", "#minecraft:stone_ore_replaceables"]
            },
            "data/minecraft/recipe/stone.json": {
                "type": "minecraft:smelting",
                "ingredient": {"item": "minecraft:cobblestone"},
                "result": {"id": "minecraft:stone", "count": 1}
            },
            "data/minecraft/loot_table/blocks/stone.json": {
                "type": "minecraft:block",
                "pools": []
            }
        }
        with zipfile.ZipFile(path, "w") as archive:
            for name, value in resources.items():
                archive.writestr(name, json.dumps(value))

    def test_extracts_resources_and_marks_runtime_values_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            jar, output = root / "fixture.jar", root / "blocks.json"
            self.make_fixture_jar(jar)
            result = extract_from_jar(jar, "26.3", output, external_sound_definitions={"minecraft": {"entity.player.levelup": {"sounds": ["entity/player/levelup"]}}})
            self.assertEqual(len(result["blocks"]), 1)
            block = result["blocks"][0]
            self.assertEqual(block["id"], "minecraft:stone")
            self.assertEqual(block["model_ids"], ["minecraft:block/stone"])
            self.assertEqual(block["runtime_properties"]["status"], "requires_java_runtime")
            self.assertIsNone(block["runtime_properties"]["friction"])
            self.assertEqual(block["resource_flags"]["loot_table_id"], "minecraft:stone")
            self.assertEqual(result["models"][0]["parent"], "minecraft:block/cube_all")
            self.assertIn("minecraft:mineable/pickaxe", result["block_tags"])
            self.assertEqual(result["recipes"][0]["result_id"], "minecraft:stone")
            self.assertIn("minecraft:block.stone.hit", [entry["id"] for entry in result["sound_events"]])
            self.assertIn("minecraft:entity.player.levelup", [entry["id"] for entry in result["sound_events"]])
            self.assertTrue(output.is_file())

    def test_empty_jar_has_explicitly_incomplete_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            jar, output = root / "empty.jar", root / "blocks.json"
            with zipfile.ZipFile(jar, "w"):
                pass
            result = extract_from_jar(jar, "26.3", output)
            self.assertFalse(result["coverage"]["registry_complete"])
            self.assertEqual(result["coverage"]["blockstate_resource_count"], 0)


if __name__ == "__main__":
    unittest.main()
