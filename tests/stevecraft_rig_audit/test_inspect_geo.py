import unittest
from pathlib import Path
from inspect_geo import EXPECTED_SHA256, inspect

BINARY = Path("mods/stevecraft/actors/minecraft_steve_geo.bin")


class SteveRigAuditTests(unittest.TestCase):
    def test_original_binary_has_valid_balanced_mario_geo_layout(self):
        result = inspect(BINARY)
        self.assertEqual(result["source"]["binary_sha256"], EXPECTED_SHA256)
        self.assertTrue(result["hierarchy"]["balanced"])
        self.assertEqual(result["layout"]["word_count"], 361)
        self.assertEqual(result["layout"]["command_count"], 215)

    def test_original_rig_has_twenty_animated_parts_and_no_dynos_bone_nodes(self):
        result = inspect(BINARY)
        self.assertEqual(result["hierarchy"]["animated_part_count"], 20)
        self.assertEqual(result["hierarchy"]["dynos_bone_node_count"], 0)

    def test_main_body_meshes_are_referenced_by_the_animated_layout(self):
        result = inspect(BINARY)
        names = {
            part["display_list"]["name"]
            for part in result["animated_parts"]
            if part["display_list"] and part["display_list"].get("kind") == "pointer"
        }
        self.assertIn("mario_Torso_mesh_layer_1", names)
        self.assertIn("mario_Left_Forearm_mesh_layer_1", names)
        self.assertIn("mario_Right_Forearm_mesh_layer_1", names)
        self.assertIn("mario_Left_Leg_mesh_layer_1", names)
        self.assertIn("mario_Right_Leg_mesh_layer_1_with_layer_1_revert", names)

    def test_animated_channel_names_match_engine_mario_anim_part_order(self):
        result = inspect(BINARY)
        names = [part["channel_name"] for part in result["animated_parts"]]
        self.assertEqual(names, [
            "ROOT", "BUTT", "TORSO", "HEAD",
            "UPPER_LEFT", "LEFT_ARM", "LEFT_FOREARM", "LEFT_HAND",
            "UPPER_RIGHT", "RIGHT_ARM", "RIGHT_FOREARM", "RIGHT_HAND",
            "LOWER_LEFT", "LEFT_THIGH", "LEFT_LEG", "LEFT_FOOT",
            "LOWER_RIGHT", "RIGHT_THIGH", "RIGHT_LEG", "RIGHT_FOOT",
        ])

    def test_head_mesh_is_separate_display_list_node(self):
        result = inspect(BINARY)
        names = {
            item["target"]["name"]
            for item in result["display_lists"]
            if item["target"] and item["target"].get("kind") == "pointer"
        }
        self.assertIn("mario_Head_DL_mesh_layer_1", names)


if __name__ == "__main__":
    unittest.main()
