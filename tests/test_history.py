"""No network: exercise real Git pushes to a temporary local bare repository."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/history.py"
spec = importlib.util.spec_from_file_location("history", SCRIPT)
history = importlib.util.module_from_spec(spec)
spec.loader.exec_module(history)


class DurableHistory(unittest.TestCase):
    def setUp(self):
        root = SCRIPT.parents[1] / ".local"
        root.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="storage-test-", dir=root)
        self.root = Path(self.temp.name).resolve()
        self.remote = self.root / "archive.git"
        subprocess.run(["git", "init", "--bare", str(self.remote)], check=True, capture_output=True)
        self.previous = Path.cwd()
        self.checkout("one")

    def tearDown(self):
        os.chdir(self.previous)
        self.temp.cleanup()

    def checkout(self, name):
        directory = self.root / name
        directory.mkdir()
        os.chdir(directory)
        history.git("init", "-b", "main")
        history.git("config", "user.name", "Offline test")
        history.git("config", "user.email", "test@example.invalid")
        history.git("config", "core.autocrlf", "false")
        history.git("remote", "add", "origin", str(self.remote))
        Path("source.txt").write_text("source only", encoding="utf-8")
        Path(".gitattributes").write_text("Data/** -text\n", encoding="utf-8")
        history.git("add", ".gitattributes")
        history.git("add", "source.txt")
        history.git("commit", "-m", "Source")
        history.hydrate("origin", "data")

    def observation(self, body, outcome="success"):
        before = set(Path("Data/projected_goalies/history").iterdir())
        history.begin()
        directory = (set(Path("Data/projected_goalies/history").iterdir()) - before).pop()
        (directory / "coverage.csv").write_text(body, encoding="utf-8")
        (directory / "lineups.html").write_bytes(b"raw response\r\nraw bytes\r\n")
        history.finalize(directory, outcome)
        return directory

    def test_fresh_runner_repeated_and_failed_observations_keep_cache(self):
        first = self.observation("matched")
        Path("Data/projected_goalies/goalie_directory_history.rds").write_bytes(b"identity cache")
        history.persist("origin", "data")
        first_hash = history.digest(first / "coverage.csv")
        self.assertEqual(set(history.git("ls-tree", "--name-only", "HEAD").decode().splitlines()), {"source.txt", ".gitattributes"})
        self.checkout("two")
        self.assertEqual(history.digest(first / "coverage.csv"), first_hash)
        self.assertEqual((first / "lineups.html").read_bytes(), b"raw response\r\nraw bytes\r\n")
        self.assertEqual(Path("Data/projected_goalies/goalie_directory_history.rds").read_bytes(), b"identity cache")
        second = self.observation("stale")
        third = self.observation("execution failed", "failure")
        self.assertNotEqual(second, third)
        history.persist("origin", "data")
        self.checkout("three")
        self.assertEqual(len(list(Path("Data/projected_goalies/history").iterdir())), 3)
        self.assertEqual(history.digest(first / "coverage.csv"), first_hash)
        self.assertEqual(json.loads((third / "run.json").read_text())["state"], "failure")
        manifest = json.loads((first / "sha256.json").read_text())
        self.assertEqual(manifest["coverage.csv"], first_hash)
        parent = history.fetch("origin", "data")
        self.assertEqual(set(history.git("ls-tree", "--name-only", parent).decode().splitlines()), {"Data", ".gitattributes"})

    def test_rewriting_archived_observation_fails(self):
        first = self.observation("matched")
        history.persist("origin", "data")
        self.checkout("two")
        self.observation("new observation")
        (first / "coverage.csv").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "changed or removed"):
            history.persist("origin", "data")

    def test_concurrent_writer_fails_without_overwriting(self):
        first = self.observation("matched")
        history.persist("origin", "data")
        one = Path.cwd()
        self.checkout("two")
        self.observation("runner two")
        two = Path.cwd()
        self.checkout("three")
        self.observation("runner three")
        history.persist("origin", "data")
        latest = history.head("origin", "data")
        os.chdir(two)
        with self.assertRaisesRegex(RuntimeError, "changed during collection"):
            history.persist("origin", "data")
        self.assertEqual(history.head("origin", "data"), latest)

    def test_unavailable_remote_and_push_rejection_fail(self):
        self.observation("matched")
        with self.assertRaises(RuntimeError):
            history.hydrate(str(self.root / "missing.git"), "data")
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        hook.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "push failed"):
            history.persist("origin", "data")
        self.assertIsNone(history.head("origin", "data"))

    def test_bootstrap_receipt_survives_restore_failure_then_is_adopted(self):
        # Simulate a clean checkout before any Data is created.
        directory = self.root / "bootstrap"
        directory.mkdir()
        os.chdir(directory)
        history.git("init", "-b", "main")
        history.git("remote", "add", "origin", str(self.remote))
        env_file = directory / "github-env.txt"
        with patch.dict(os.environ, {"GITHUB_ENV": str(env_file)}):
            history.begin(pending=True)
            pending = env_file.read_text().split("PG_RUN_DIR=", 1)[1].strip()
            with patch.dict(os.environ, {"PG_RUN_DIR": pending}):
                with self.assertRaises(RuntimeError):
                    history.hydrate(str(self.root / "missing.git"), "data")
                history.finalize(pending, "failure")
                self.assertTrue((Path(pending) / "sha256.json").exists())
                history.hydrate("origin", "data")
            adopted = env_file.read_text().splitlines()[-1].split("=", 1)[1]
            self.assertFalse(Path(pending).exists())
            self.assertTrue((Path(adopted) / "run.json").exists())


if __name__ == "__main__":
    unittest.main()
