"""Opt-in real Rojo/Blender smoke test; makes disposable places, never opens the user's game."""

import argparse
import concurrent.futures
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


KIT = Path(__file__).resolve().parents[2]
SCRIPT = KIT / "skills/roblox-isolate/scripts/environment.py"


def command(argv, cwd=None):
    result = subprocess.run([str(arg) for arg in argv], cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def cli(*args):
    return json.loads(command([sys.executable, SCRIPT, *args]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rojo", required=True, help="real Rojo executable (not a Rokit shim)")
    parser.add_argument("--blender", required=True)
    parser.add_argument("--keep-running", action="store_true", help="keep Rojo servers for manual Studio verification")
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix="rdk-isolate-smoke-")).resolve()
    source = directory / "source"
    source.mkdir()
    (source / "blender").mkdir()
    (source / "blender/build.py").write_text('''import bpy, json, os
from pathlib import Path
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.mesh.primitive_cube_add()
bpy.context.active_object.name = Path.cwd().parent.name
bpy.ops.wm.save_as_mainfile(filepath=str(Path.cwd() / "blender/model.blend"))
bpy.ops.wm.save_userpref()
Path("blender/result.json").write_text(json.dumps({
    "name": bpy.context.active_object.name,
    "blend": bpy.data.filepath,
    "config": bpy.utils.user_resource("CONFIG"),
    "cwd": str(Path.cwd()),
}))
''')
    project = {"name": "Isolation smoke fixture", "tree": {"$className": "DataModel", "Workspace": {
        "Cube": {"$className": "Part", "$properties": {"Anchored": True, "Size": [4, 4, 4],
                                                          "Position": [0, 4, 0], "Color": [0.4, 0.7, 0.9]}}}}}
    (source / "default.project.json").write_text(json.dumps(project))
    for git_args in (["init", "-q"], ["add", "."], ["-c", "user.email=test@example.invalid",
                     "-c", "user.name=Smoke Test", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"]):
        command(["git", *git_args], cwd=source)
    place = directory / "baseline.rbxlx"
    command([args.rojo, "build", "default.project.json", "-o", place], cwd=source)
    camera = directory / "cameras.json"
    camera.write_text(json.dumps({"views": [{"name": "overview", "camera_position": [12, 12, 12],
                                            "look_at_position": [0, 4, 0]}]}))
    environments = []
    try:
        for name in ("backyard", "marsh"):
            environments.append(cli("create", name, "--repo", source, "--place", place,
                                    "--root", directory / "environments", "--cameras", camera))
        def exercise(env):
            env = cli("start", env["directory"], "--rojo", args.rojo)
            command([sys.executable, SCRIPT, "blender", env["directory"], "--binary", args.blender,
                     "blender/build.py"])
            result = json.loads((Path(env["worktree"]) / "blender/result.json").read_text())
            assert result["cwd"] == env["worktree"]
            assert Path(result["config"]).is_relative_to(env["blender"])
            assert Path(result["blend"]).is_file()
            # Compile the real generated Rojo project, including its verification marker.
            command([args.rojo, "build", env["rojo"]["project"], "-o",
                     Path(env["directory"]) / "marker-check.rbxlx"], cwd=env["worktree"])
            assert env["id"] in (Path(env["directory"]) / "marker-check.rbxlx").read_text()
            return env
        with concurrent.futures.ThreadPoolExecutor() as pool:
            environments = list(pool.map(exercise, environments))
        assert environments[0]["rojo"]["port"] != environments[1]["rojo"]["port"]
        assert not (source / "blender/model.blend").exists()
        output = {"directory": str(directory), "environments": environments,
                  "result": "two real Rojo servers and two private Blender processes passed"}
        (directory / "result.json").write_text(json.dumps(output, indent=2))
        print(json.dumps(output, indent=2))
    finally:
        if not args.keep_running:
            for env in environments:
                cli("stop", env["directory"])
            shutil.rmtree(directory)


if __name__ == "__main__":
    main()
