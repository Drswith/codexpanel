import base64
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "prepare_tokscale.py"
SPEC = importlib.util.spec_from_file_location("prepare_tokscale", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrepareTokscaleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def archive(self, content=b"synthetic Mach-O fixture", symlink=False):
        path = self.root / "package.tgz"
        with tarfile.open(path, "w:gz") as archive:
            item = tarfile.TarInfo("package/bin/tokscale")
            if symlink:
                item.type = tarfile.SYMTYPE
                item.linkname = "/outside"
                archive.addfile(item)
            else:
                item.size = len(content)
                archive.addfile(item, io.BytesIO(content))
        return path, hashlib.sha256(content).hexdigest()

    def test_rejects_tarball_that_does_not_match_locked_integrity(self):
        path, _ = self.archive()
        with self.assertRaisesRegex(ValueError, "SHA-512"):
            MODULE.verify_tarball(path, "sha512-incorrect")

    def test_extracts_only_verified_binary(self):
        path, digest = self.archive()
        integrity = "sha512-" + base64.b64encode(hashlib.sha512(path.read_bytes()).digest()).decode()
        MODULE.verify_tarball(path, integrity)
        output = self.root / "tokscale"
        MODULE.extract_binary(path, output, digest)
        self.assertEqual(MODULE.sha256(output), digest)
        self.assertEqual(output.stat().st_mode & 0o777, 0o755)

    def test_rejects_symlink_binary(self):
        path, digest = self.archive(symlink=True)
        with self.assertRaisesRegex(ValueError, "普通二进制"):
            MODULE.extract_binary(path, self.root / "tokscale", digest)
        self.assertFalse((self.root / "tokscale").exists())

    def test_rejects_wrong_binary_digest_before_writing(self):
        path, _ = self.archive()
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            MODULE.extract_binary(path, self.root / "tokscale", "incorrect")
        self.assertFalse((self.root / "tokscale").exists())

    def test_verified_binary_cache_works_without_network(self):
        directory = self.root / "4.20.0/arm64"
        directory.mkdir(parents=True)
        binary = directory / "tokscale"
        binary.write_bytes(b"verified cache")
        manifest = {"version": "4.20.0", "platforms": {"arm64": {"binarySHA256": MODULE.sha256(binary)}}}
        with patch.object(MODULE.subprocess, "run", side_effect=AssertionError("must remain offline")):
            self.assertEqual(MODULE.prepare(manifest, "arm64", self.root), binary)


if __name__ == "__main__":
    unittest.main()
