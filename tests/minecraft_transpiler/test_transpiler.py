import tempfile
import unittest
import zipfile
from pathlib import Path

from mc2sm64 import transpile


class TranspilerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "GravityMath.java"
        self.source.write_text(
            "public final class GravityMath { "
            "public static double step(double y, double gravity) { "
            "if (y > 0.0) { y = y - gravity; } return y; } "
            "public static double clamp(double x, double lo, double hi) { "
            "return Math.max(lo, Math.min(hi, x)); } }",
            encoding="utf-8",
        )
        self.output = self.root / "out"

    def tearDown(self):
        self.temp.cleanup()

    def test_generates_lua_and_c_for_supported_static_methods(self):
        report = transpile(self.source, self.output, "both")
        self.assertEqual(report["generated_methods"]["lua"], 2)
        self.assertEqual(report["generated_methods"]["c"], 2)
        lua = next((self.output / "lua").glob("*.lua")).read_text(encoding="utf-8")
        c_source = next((self.output / "c").glob("*.c")).read_text(encoding="utf-8")
        self.assertIn("M[", lua)
        self.assertIn("fmax", c_source)
        self.assertTrue((self.output / "manifest.json").is_file())
        self.assertTrue((self.output / "ir" / "GravityMath.json").is_file())

    def test_skips_unsupported_construct_instead_of_faking_translation(self):
        source = self.root / "Unsupported.java"
        source.write_text(
            "class Unsupported { public static int value(int x) { "
            "for (int i = 0; i < x; i++) { x = x - 1; } return x; } }",
            encoding="utf-8",
        )
        report = transpile(source, self.root / "unsupported-out", "lua")
        self.assertEqual(report["generated_methods"]["lua"], 0)
        self.assertTrue(report["diagnostics"])

    def test_binary_jar_without_sources_is_rejected(self):
        archive = self.root / "client.jar"
        with zipfile.ZipFile(archive, "w") as handle:
            handle.writestr("net/minecraft/Example.class", b"\xca\xfe\xba\xbe")
        with self.assertRaisesRegex(ValueError, "contains no .java sources"):
            transpile(archive, self.root / "jar-out", "lua")


if __name__ == "__main__":
    unittest.main()
