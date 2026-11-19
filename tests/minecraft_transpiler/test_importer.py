import tempfile
import unittest
import zipfile
from pathlib import Path

from import_minecraft import import_and_transpile, safe_archive_sources


class MinecraftImporterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "src" / "net" / "minecraft" / "util" / "GravityMath.java"
        self.source.parent.mkdir(parents=True)
        self.source.write_text(
            "package net.minecraft.util; "
            "public final class GravityMath { "
            "public static double clamp(double x, double lo, double hi) { "
            "return Math.max(lo, Math.min(hi, x)); } }",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_imports_source_directory_and_applies_package_filter(self):
        output = self.root / "out"
        report = import_and_transpile(
            self.source.parents[3], output, "lua",
            include_packages=["net.minecraft.util"],
        )
        self.assertEqual(report["source_count"], 1)
        self.assertEqual(report["transpilation"]["generated_methods"]["lua"], 1)
        self.assertTrue((output / "import_report.json").is_file())
        lua_files = list((output / "generated" / "lua").glob("*.lua"))
        self.assertEqual(len(lua_files), 1)
        self.assertIn("math.max", lua_files[0].read_text(encoding="utf-8"))

    def test_imports_java_source_archive(self):
        archive = self.root / "sources.jar"
        with zipfile.ZipFile(archive, "w") as handle:
            handle.write(self.source, "net/minecraft/util/GravityMath.java")
        report = import_and_transpile(archive, self.root / "zip-out", "lua")
        self.assertEqual(report["input_kind"], "java-source")
        self.assertEqual(report["source_count"], 1)

    def test_binary_jar_requires_explicit_cfr_decompiler(self):
        archive = self.root / "client.jar"
        with zipfile.ZipFile(archive, "w") as handle:
            handle.writestr("net/minecraft/Example.class", b"\\xca\\xfe\\xba\\xbe")
        with self.assertRaisesRegex(ValueError, "Supply --cfr-jar"):
            import_and_transpile(archive, self.root / "binary-out", "lua")

    def test_source_archive_rejects_traversal_paths(self):
        archive = self.root / "unsafe-sources.zip"
        with zipfile.ZipFile(archive, "w") as handle:
            handle.writestr("../outside.java", "class Outside {}")
            handle.writestr(r"..\outside-windows.java", "class OutsideWindows {}")
            handle.writestr("C:/outside-drive.java", "class OutsideDrive {}")
            handle.writestr("safe/Inside.java", "class Inside {}")
        destination = self.root / "extracted"
        count = safe_archive_sources(archive, destination)
        self.assertEqual(count, 1)
        self.assertTrue((destination / "safe" / "Inside.java").is_file())
        self.assertFalse((self.root / "outside.java").exists())


if __name__ == "__main__":
    unittest.main()
