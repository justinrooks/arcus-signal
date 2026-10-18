#!/usr/bin/env python3
"""File persistence and real Compose interpolation tests; never start containers."""
import importlib.util
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tools/lib/release-pin.py"
spec = importlib.util.spec_from_file_location("release_pin", HELPER)
pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pin)


class TemporaryConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="arcus-release-pin-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env_file = self.root / ".env"
        self.env_file.write_bytes(b"")


class ReleasePinTests(TemporaryConfigTests):
    def test_preserves_unrelated_bytes_and_permissions(self):
        original = b"# keep comments\r\nOTHER='first\r\nARCUS_SIGNAL_IMAGE_TAG=secret-text\r\nlast'\r\nARCUS_SIGNAL_IMAGE_TAG=v1.0.0\r\nMESO_NOTIFICATIONS_ENABLED=true"
        self.env_file.write_bytes(original)
        self.env_file.chmod(0o640)
        before = self.env_file.stat()
        pin.save(self.env_file, "v1.4.1")
        self.assertEqual(self.env_file.read_bytes(), original + b"\r\nARCUS_SIGNAL_IMAGE_TAG=v1.4.1\r\n")
        after = self.env_file.stat()
        self.assertEqual(stat.S_IMODE(after.st_mode), 0o640)
        self.assertEqual((after.st_uid, after.st_gid), (before.st_uid, before.st_gid))

    def test_repeated_deployments_replace_the_final_pin(self):
        original = b"OTHER=value\nARCUS_SIGNAL_IMAGE_TAG=v1.0.0\n"
        self.env_file.write_bytes(original)
        pin.save(self.env_file, "v1.4.1")
        pin.save(self.env_file, "v1.4.2")
        self.assertEqual(self.env_file.read_bytes(), b"OTHER=value\nARCUS_SIGNAL_IMAGE_TAG=v1.4.2\n")
        before = self.env_file.stat()
        pin.save(self.env_file, "v1.4.2")
        self.assertEqual(self.env_file.stat().st_ino, before.st_ino)

    def test_replace_failure_preserves_original_and_cleans_temporary_file(self):
        original = b"ARCUS_SIGNAL_IMAGE_TAG=v1.0.0\nOTHER=SECRET_SENTINEL\n"
        self.env_file.write_bytes(original)
        with patch.object(pin.os, "replace", side_effect=OSError("denied")):
            with self.assertRaises(OSError):
                pin.save(self.env_file, "v1.4.1")
        self.assertEqual(self.env_file.read_bytes(), original)
        self.assertEqual(list(self.root.glob(".arcus-release-pin-*")), [])

    def test_concurrent_edit_is_not_overwritten(self):
        changed = b"OTHER=operator-change\n"
        with patch.object(pin.os, "fsync", side_effect=lambda _: self.env_file.write_bytes(changed)):
            with self.assertRaises(OSError):
                pin.save(self.env_file, "v1.4.1")
        self.assertEqual(self.env_file.read_bytes(), changed)
        self.assertEqual(list(self.root.glob(".arcus-release-pin-*")), [])

    def test_check_and_invalid_tag_do_not_modify_configuration(self):
        self.env_file.write_bytes(b"OTHER=SECRET_SENTINEL\n")
        before = self.env_file.read_bytes()
        for arguments, expected in ((["--check", str(self.env_file), "v1.4.1"], 0), ([str(self.env_file), "latest"], 2)):
            result = subprocess.run([sys.executable, str(HELPER), *arguments], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected)
            self.assertNotIn("SECRET_SENTINEL", result.stdout + result.stderr)
            self.assertEqual(self.env_file.read_bytes(), before)

    def test_symlink_is_rejected(self):
        link = self.root / "linked.env"
        link.symlink_to(self.env_file)
        with self.assertRaises(OSError):
            pin.save(link, "v1.4.1")
        self.assertEqual(self.env_file.read_bytes(), b"")


@unittest.skipUnless(shutil.which("docker"), "Docker Compose CLI is unavailable")
class ComposeSelectionTests(TemporaryConfigTests):
    def setUp(self):
        super().setUp()
        shutil.copy(ROOT / "docker-compose.yml", self.root / "docker-compose.yml")
        # No host .env, exported tag, credentials, daemon, or network is used.
        self.process_env = {"PATH": os.environ["PATH"], "HOME": str(self.root)}
        result = subprocess.run(["docker", "compose", "version"], env=self.process_env, capture_output=True)
        if result.returncode:
            self.skipTest("Docker Compose CLI is unavailable")

    def compose(self):
        return subprocess.run(["docker", "compose", "--project-directory", str(self.root), "--env-file", str(self.env_file), "config", "--images"], env=self.process_env, capture_output=True, text=True)

    def test_missing_and_empty_tag_fail_before_container_operations(self):
        for contents in (b"", b"ARCUS_SIGNAL_IMAGE_TAG=\n"):
            self.env_file.write_bytes(contents)
            result = self.compose()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Set ARCUS_SIGNAL_IMAGE_TAG", result.stderr)

    def test_fresh_compose_process_resolves_persisted_tag_for_both_services(self):
        original = b"ARCUS_SIGNAL_IMAGE_TAG=v1.0.0\nOTHER='first\nARCUS_SIGNAL_IMAGE_TAG=secret-text\nlast'\n"
        self.env_file.write_bytes(original)
        for tag in ("v1.4.1", "v1.4.2"):
            pin.save(self.env_file, tag)
            result = self.compose()
            self.assertEqual(result.returncode, 0, result.stderr)
            images = result.stdout.splitlines()
            self.assertEqual(images.count("ghcr.io/justinrooks/arcus-signal:" + tag), 2)
            self.assertNotIn("secret-text", result.stdout + result.stderr)
        self.assertTrue(self.env_file.read_bytes().startswith(original))


if __name__ == "__main__":
    unittest.main(verbosity=2)
