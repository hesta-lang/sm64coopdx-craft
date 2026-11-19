import tempfile
import unittest
from pathlib import Path

from mc2sm64 import transpile


class SteveCraftBridgeTranspilerTests(unittest.TestCase):
    def test_bridge_fixture_transpiles_to_native_lua_bindings(self):
        root = Path(__file__).resolve().parents[2]
        source = root / "tools" / "minecraft_transpiler" / "examples" / "stevecraft_bridge"
        mapping = root / "tools" / "minecraft_transpiler" / "mappings" / "stevecraft_bridge.json"

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "generated"
            report = transpile(source, output, "lua", mapping)

            self.assertEqual(report["classes"], 1)
            self.assertGreater(report["generated_methods"]["lua"], 0)
            self.assertEqual(report["unsupported_methods"], [])

            generated_files = list((output / "lua").glob("*.lua"))
            self.assertEqual(len(generated_files), 1)
            generated = generated_files[0].read_text(encoding="utf-8")
            self.assertIn("stevecraft_player_proxy_enable", generated)
            self.assertIn("stevecraft_player_set_state", generated)
            self.assertIn("stevecraft_player_set_hitbox", generated)
            self.assertIn("stevecraft_player_get_engine_action", generated)
            self.assertIn("stevecraft_player_get_engine_interacting", generated)
            self.assertIn("stevecraft_player_model_set_model", generated)
            self.assertIn("stevecraft_player_model_set_scale", generated)
            self.assertIn("stevecraft_player_model_set_animation", generated)
            self.assertIn("stevecraft_player_model_clear", generated)


if __name__ == "__main__":
    unittest.main()
