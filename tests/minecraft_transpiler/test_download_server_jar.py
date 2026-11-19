import unittest
from unittest.mock import patch

from download_server_jar import official_url, resolve


class OfficialServerResolverTests(unittest.TestCase):
    def test_rejects_untrusted_download_hosts(self):
        with self.assertRaisesRegex(ValueError, "non-official"):
            official_url("http://piston-data.mojang.com/server.jar", "piston-data.mojang.com")
        with self.assertRaisesRegex(ValueError, "non-official"):
            official_url("https://example.com/server.jar", "piston-data.mojang.com")

    def test_resolves_exact_version_and_checksum(self):
        manifest = {"versions": [{"id": "26.3", "url": "https://piston-meta.mojang.com/v1/packages/test/26.3.json"}]}
        metadata = {"downloads": {"server": {"url": "https://piston-data.mojang.com/v1/objects/test/server.jar", "sha1": "a" * 40, "size": 100}}}
        with patch("download_server_jar.read_json", side_effect=[manifest, metadata]):
            url, sha1, size = resolve("26.3")
        self.assertEqual(url, metadata["downloads"]["server"]["url"])
        self.assertEqual(sha1, "a" * 40)
        self.assertEqual(size, 100)

    def test_rejects_unknown_version(self):
        with patch("download_server_jar.read_json", return_value={"versions": []}):
            with self.assertRaisesRegex(ValueError, "not found"):
                resolve("26.3")


if __name__ == "__main__":
    unittest.main()
