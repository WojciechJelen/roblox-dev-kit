"""Real Git/files/process tests; fake Rojo/Blender binaries, no Studio or network services."""

import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace


SCRIPT = Path(__file__).resolve().parents[1] / "skills/roblox-isolate/scripts/environment.py"
SPEC = importlib.util.spec_from_file_location("isolate", SCRIPT)
ISOLATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ISOLATE)


class EnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rdk-isolate-test-")
        self.base = Path(self.temporary.name).resolve()
        self.repo = self.base / "source game"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "tests@example.invalid")
        self.git("config", "user.name", "Isolation test")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "src").mkdir()
        (self.repo / "src/main.server.luau").write_text('--!strict\nprint("baseline")\n')
        (self.repo / "blender").mkdir()
        (self.repo / "blender/props.blend").write_bytes(b"fixture blend")
        (self.repo / "blender/build.py").write_text("print('fixture')\n")
        (self.repo / ".gitignore").write_text("Packages/\n")
        self.project = {"name": "Source Game", "placeId": 123, "gameId": 456,
                        "servePlaceIds": [123], "tree": {"$className": "DataModel",
                        "ServerScriptService": {"$path": "src"}}}
        self.json(self.repo / "default.project.json", self.project)
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.root = self.base / "environments"
        self.place = self.base / "saved map.rbxl"
        self.place.write_bytes(b"place content containing map")
        self.camera = self.base / "cameras.json"
        self.json(self.camera, {"views": [{"name": "overview", "camera_position": [1, 2, 3],
                                          "look_at_position": [0, 0, 0]}]})
        self.fake_rojo = self.base / "fake-rojo"
        self.fake_rojo.write_text(f'''#!{sys.executable}
import http.server, json, socketserver, sys, uuid
session = str(uuid.uuid4())
project_name = json.load(open(sys.argv[2]))['name']
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({{'sessionId': session, 'projectName': project_name}}).encode())
    def log_message(self, *args): pass
port = int(sys.argv[sys.argv.index('--port') + 1])
# HTTPServer.server_bind does a reverse DNS lookup before listen(); macOS CI
# can stall there for 30+ seconds. This fixture needs only a loopback TCP server.
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('127.0.0.1', port), Handler).serve_forever()
''')
        self.fake_rojo.chmod(0o755)

    def tearDown(self):
        for manifest in self.root.glob("*/*/environment.json"):
            self.cli("stop", str(manifest), ok=False)
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    @staticmethod
    def json(path, value):
        path.write_text(json.dumps(value))
        return str(path)

    def cli(self, *args, ok=True, variables=None):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True,
                                text=True, env=variables)
        if ok:
            logs = ""
            if result.returncode:
                for path in self.root.glob("*/*/logs/rojo.log"):
                    logs += f"\n{path}:\n{path.read_text()}"
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout + logs)
            return json.loads(result.stdout)
        return result

    def create(self, name="backyard", *extra):
        return self.cli("create", name, "--repo", str(self.repo), "--root", str(self.root),
                        "--place", str(self.place), "--cameras", str(self.camera), *extra)

    def start(self, env):
        return self.cli("start", env["directory"], "--rojo", str(self.fake_rojo))

    def bind(self, env, studio_id="studio-1", token=None, name=None, ok=True):
        listing = self.json(self.base / (studio_id + "-studios.json"), {"studios": [{
            "id": studio_id, "name": name or Path(env["place"]).stem}]})
        proof = self.json(self.base / (studio_id + "-proof.json"), {"environment_id": token or env["id"]})
        return self.cli("bind-studio", env["directory"], "--studio-id", studio_id,
                        "--studios", listing, "--proof", proof, ok=ok)

    def test_create_is_idempotent_and_does_not_touch_source_or_share_assets(self):
        env = self.create()
        self.assertEqual(self.create(), env)
        self.assertTrue(env["prepared"])
        self.assertNotEqual(env["branch"], self.git("branch", "--show-current"))
        self.assertEqual(self.git("status", "--porcelain"), "")
        copy = Path(env["worktree"]) / "blender/props.blend"
        copy.write_bytes(b"changed in worker")
        self.assertEqual((self.repo / "blender/props.blend").read_bytes(), b"fixture blend")
        self.assertEqual(Path(env["place"]).read_bytes(), self.place.read_bytes())
        project = json.loads(Path(env["rojo"]["project"]).read_text())
        self.assertNotIn("placeId", project)
        self.assertNotIn("gameId", project)
        self.assertNotIn("servePlaceIds", project)
        self.assertEqual(project["tree"]["ServerScriptService"]["$path"], "src")
        marker = project["tree"]["ReplicatedStorage"]["RDKEnvironmentId"]
        self.assertEqual(marker["$properties"]["Value"], env["id"])

    def test_dirty_source_requires_explicit_committed_baseline(self):
        (self.repo / "src/main.server.luau").write_text("dirty change")
        result = self.cli("create", "dirty", "--repo", str(self.repo), "--place", str(self.place),
                          "--root", str(self.root), ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("uncommitted", result.stderr)
        env = self.create("committed", "--committed-only")
        self.assertIn("baseline", (Path(env["worktree"]) / "src/main.server.luau").read_text())

    def test_parallel_create_allocates_distinct_resources(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            first, second = list(pool.map(self.create, ("backyard", "marsh")))
        for field in ("id", "directory", "worktree", "branch", "place", "review", "blender"):
            self.assertNotEqual(first[field], second[field])
        self.assertNotEqual(first["rojo"]["port"], second["rojo"]["port"])
        with concurrent.futures.ThreadPoolExecutor() as pool:
            started = list(pool.map(self.start, (first, second)))
        for env in started:
            self.assertTrue(self.cli("status", env["directory"])["rojo_running"])

    def test_same_name_concurrent_creates_reuse_one_branch(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            first, second = list(pool.map(self.create, ("backyard", "backyard")))
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(len(list(self.root.glob("*/*/environment.json"))), 1)

    def test_copies_explicit_dependencies_and_refuses_existing_resource_changes(self):
        (self.repo / "Packages").mkdir()
        (self.repo / "Packages/library.luau").write_text("dependency")
        env = self.create("packages", "--copy", "Packages")
        self.assertEqual((Path(env["worktree"]) / "Packages/library.luau").read_text(), "dependency")
        self.place.write_bytes(b"new baseline")
        result = self.cli("create", "packages", "--repo", str(self.repo), "--place", str(self.place),
                          "--root", str(self.root), ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(Path(env["place"]).read_bytes(), b"place content containing map")

    def test_dry_run_has_no_filesystem_effects(self):
        result = self.create("dry", "--dry-run")
        self.assertTrue(result["dry_run"])
        self.assertFalse(self.root.exists())
        self.assertNotIn("codex/", self.git("branch", "--list"))

    def test_shared_skills_are_read_only_tooling_but_shared_assets_are_rejected(self):
        skill = self.base / "shared-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("test tooling")
        installed = self.repo / ".agents/skills"
        installed.mkdir(parents=True)
        (installed / "example").symlink_to(skill)
        self.git("add", ".")
        self.git("commit", "-qm", "linked skill")
        env = self.create()
        self.assertEqual(len(env["shared_tooling"]), 1)
        (self.repo / "shared-assets").symlink_to(skill)
        self.git("add", ".")
        self.git("commit", "-qm", "linked assets")
        result = self.cli("create", "bad-assets", "--repo", str(self.repo), "--place", str(self.place),
                          "--root", str(self.root), ok=False)
        self.assertIn("symlink points outside", result.stderr)

    def test_rojo_handshake_supports_json_and_messagepack(self):
        # Structure used by Rojo 7.7.1, including uint64 cloud IDs and nil fields.
        payload = (b'\x85\xa9sessionId\xd9\x04test\xabprojectName\xa4test'
                   b'\xafprotocolVersion\x05\xb0expectedPlaceIds\x91\xcf'
                   + (93481376241097).to_bytes(8, 'big') + b'\xa6gameId\xc0')
        expected = {"sessionId": "test", "projectName": "test", "protocolVersion": 5,
                    "expectedPlaceIds": [93481376241097], "gameId": None}
        self.assertEqual(ISOLATE.decode_rojo_info(payload), expected)
        self.assertEqual(ISOLATE.decode_rojo_info(json.dumps(expected).encode()), expected)
        with self.assertRaises(ValueError):
            ISOLATE.decode_rojo_info(payload[:-1])

    def test_rojo_restart_and_stop_preserve_artifacts(self):
        env = self.start(self.create())
        self.assertEqual(env["rojo"]["process"], self.start(env)["rojo"]["process"])
        env = self.bind(env)
        self.cli("stop", env["directory"])
        status = self.cli("status", env["directory"])
        self.assertFalse(status["rojo_running"])
        self.assertIsNone(status["studio"])
        self.assertTrue(Path(env["place"]).exists())
        self.assertTrue(Path(env["worktree"]).exists())
        self.cli("stop", env["directory"])
        restarted = self.start(env)
        self.assertNotEqual(restarted["rojo"]["process"]["session_id"], env["rojo"]["process"]["session_id"])

    def test_wrong_instance_and_wrong_marker_are_rejected(self):
        env = self.start(self.create())
        wrong_marker = self.bind(env, token="wrong", ok=False)
        self.assertIn("different environment", wrong_marker.stderr)
        wrong_name = self.bind(env, name="Shared cloud game", ok=False)
        self.assertIn("exactly one Studio", wrong_name.stderr)
        self.assertIsNone(self.cli("status", env["directory"])["studio"])
        bound = self.bind(env)
        self.assertEqual(bound["studio"]["id"], "studio-1")
        second = self.start(self.create("marsh"))
        reused = self.bind(second, ok=False)
        self.assertIn("already assigned", reused.stderr)

    def test_duplicate_place_windows_cannot_be_bound(self):
        env = self.start(self.create())
        listing = self.json(self.base / "duplicates.json", {"studios": [
            {"id": identifier, "name": Path(env["place"]).stem} for identifier in ("one", "two")]})
        proof = self.json(self.base / "proof.json", {"environment_id": env["id"]})
        result = self.cli("bind-studio", env["directory"], "--studio-id", "one",
                          "--studios", listing, "--proof", proof, ok=False)
        self.assertIn("close duplicate copies", result.stderr)

    def test_stop_never_signals_unowned_pid(self):
        env = self.create()
        env["rojo"]["process"] = {"pid": os.getpid(), "fingerprint": "stale identity", "session_id": "stale"}
        self.json(Path(env["directory"]) / "environment.json", env)
        stopped = self.cli("stop", env["directory"])
        self.assertIsNone(stopped["rojo"]["process"])
        self.assertTrue(ISOLATE.fingerprint(os.getpid()))

    def test_studio_retry_during_login_reuses_launcher_even_with_reopen(self):
        env = self.create()
        args = SimpleNamespace(app="/Applications/RobloxStudio.app", reopen=False)
        child = mock.Mock(pid=12345)
        child.poll.return_value = None
        with mock.patch.object(ISOLATE.sys, "platform", "darwin"), \
                mock.patch.object(ISOLATE, "run", return_value=""), \
                mock.patch.object(ISOLATE, "fingerprint", return_value="owned launcher identity"), \
                mock.patch.object(ISOLATE.subprocess, "Popen", return_value=child) as launch:
            ISOLATE.open_studio(env, args)
            args.reopen = True
            ISOLATE.open_studio(env, args)
            self.assertEqual(launch.call_count, 1)
            self.assertIn("-W", launch.call_args.args[0])
            self.assertEqual(env["studio_launcher"]["pid"], 12345)

    def test_studio_reopen_checks_file_process_if_launcher_was_lost(self):
        env = self.create()
        env["studio_launch_requested"] = True
        env["studio_launcher"] = {"pid": 12345, "fingerprint": "previous identity"}
        args = SimpleNamespace(app="/Applications/RobloxStudio.app", reopen=True)
        running = "/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio -localPlaceFile " + env["place"]
        with mock.patch.object(ISOLATE.sys, "platform", "darwin"), \
                mock.patch.object(ISOLATE, "run", return_value=running), \
                mock.patch.object(ISOLATE, "fingerprint", return_value=""), \
                mock.patch.object(ISOLATE.subprocess, "Popen") as launch:
            ISOLATE.open_studio(env, args)
            launch.assert_not_called()

    def test_startup_failure_does_not_record_a_live_process(self):
        binary = self.base / "failed-rojo"
        binary.write_text("#!/bin/sh\nexit 7\n")
        binary.chmod(0o755)
        env = self.create()
        result = self.cli("start", env["directory"], "--rojo", str(binary), ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Rojo exited", result.stderr)
        self.assertFalse(self.cli("status", env["directory"])["rojo_running"])

    def test_path_escape_is_refused_and_partial_state_is_reported(self):
        self.project["tree"]["ServerScriptService"]["$path"] = str(self.repo / "src")
        self.json(self.repo / "default.project.json", self.project)
        self.git("add", ".")
        self.git("commit", "-qm", "external path")
        result = self.cli("create", "external", "--repo", str(self.repo), "--place", str(self.place),
                          "--root", str(self.root), ok=False)
        self.assertIn("escapes the worktree", result.stderr)
        failed = json.loads(next(self.root.glob("*/*/environment.json")).read_text())
        self.assertFalse(failed["prepared"])

    def test_captures_use_bound_id_and_identical_immutable_cameras(self):
        env = self.bind(self.start(self.create()))
        before = self.cli("capture-plan", env["directory"], "--phase", "before")[0]
        after = self.cli("capture-plan", env["directory"], "--phase", "after")[0]
        for key in ("studio_id", "camera_position", "look_at_position"):
            self.assertEqual(before["arguments"][key], after["arguments"][key])
        image = self.base / "image.png"
        image.write_bytes(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 640, 480))
        def record(phase, ok=True):
            return self.cli("record-capture", env["directory"], "--phase", phase, "--view", "overview",
                            "--image", str(image), ok=ok)
        self.assertIn("before image first", record("after", ok=False).stderr)
        record("before")
        self.assertIn("already recorded", record("before", ok=False).stderr)
        image.write_bytes(image.read_bytes()[:16] + struct.pack(">II", 320, 240))
        self.assertIn("same resolution", record("after", ok=False).stderr)
        image.write_bytes(image.read_bytes()[:16] + struct.pack(">II", 640, 480))
        record("after")
        (Path(env["review"]) / "cameras.json").write_text("{}")
        changed = self.cli("capture-plan", env["directory"], "--phase", "after", ok=False)
        self.assertIn("changed", changed.stderr)

    def test_blender_process_has_private_paths_and_propagates_failure(self):
        env = self.create()
        binary = self.base / "fake-blender"
        output = Path(env["directory"]) / "blender-arguments.json"
        binary.write_text(f'''#!{sys.executable}
import json, os, sys
with open(sys.argv[-1], 'w') as out:
    json.dump({{'argv': sys.argv, 'cwd': os.getcwd(), 'variables': dict(os.environ)}}, out)
sys.exit(7)
''')
        binary.chmod(0o755)
        result = self.cli("blender", env["directory"], "--binary", str(binary),
                          "--blend", "blender/props.blend", "blender/build.py", "--", str(output), ok=False,
                          variables=dict(os.environ, BLENDER_USER_CONFIG="/outside/preferences"))
        self.assertEqual(result.returncode, 7, result.stderr)
        called = json.loads(output.read_text())
        self.assertEqual(called["cwd"], env["worktree"])
        self.assertIn("--background", called["argv"])
        self.assertIn("--factory-startup", called["argv"])
        self.assertIn("--disable-autoexec", called["argv"])
        for name, value in called["variables"].items():
            if name.startswith("BLENDER_USER_") or name == "TMPDIR":
                self.assertTrue(ISOLATE.inside(value, env["directory"]), (name, value))
        escape = self.cli("blender", env["directory"], "--blend", str(self.repo / "blender/props.blend"),
                          "blender/build.py", ok=False)
        self.assertIn("inside this environment", escape.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
