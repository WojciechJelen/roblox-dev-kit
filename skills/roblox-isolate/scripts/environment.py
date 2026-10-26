#!/usr/bin/env python3
"""Local per-agent Roblox environments. Python 3.9+, standard library, macOS/Linux."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import urllib.request
import uuid


class EnvironmentError(RuntimeError):
    pass


def run(*argv, cwd=None):
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise EnvironmentError(result.stderr.strip() or result.stdout.strip() or str(argv))
    return result.stdout.strip()


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def digest(path):
    with Path(path).open("rb") as source:
        result = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


@contextlib.contextmanager
def lock(path):
    with Path(path).open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def inside(path, root):
    return Path(path).resolve().is_relative_to(Path(root).resolve())


def relative_path(value):
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or not path.parts or ".git" in path.parts:
        raise EnvironmentError(f"expected a project-relative path without '..' or '.git': {value}")
    return path


def local_path(env, value):
    path = Path(value)
    if not path.is_absolute():
        path = Path(env["worktree"]) / path
    path = path.resolve()
    if not inside(path, env["directory"]) or not path.is_file():
        raise EnvironmentError(f"file must exist inside this environment: {path}")
    return path


def manifests(root):
    for path in Path(root).glob("*/*/environment.json"):
        yield read_json(path)


def available(port):
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def reserve_port(root, requested):
    used = {env["rojo"]["port"] for env in manifests(root)}
    candidates = [requested] if requested else range(34873, 35873)
    for port in candidates:
        if 1024 <= port <= 65535 and port not in used and available(port):
            return port
    raise EnvironmentError("no available Rojo port; choose an unused --port (1024–65535)")


def validate_cameras(path):
    data = read_json(path)
    views = data.get("views", [])
    if not views:
        raise EnvironmentError("camera manifest needs at least one view")
    names = set()
    for view in views:
        name = view["name"]
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name) or name in names:
            raise EnvironmentError("camera view names must be unique lowercase slugs")
        names.add(name)
        for field in ("camera_position", "look_at_position"):
            vector = view[field]
            if (not isinstance(vector, list) or len(vector) != 3 or
                    any(type(n) not in (int, float) or not math.isfinite(n) for n in vector)):
                raise EnvironmentError(f"{name}.{field} must have three finite numbers")
        if view["camera_position"] == view["look_at_position"]:
            raise EnvironmentError(f"{name}: camera and target must differ")
    return data


def audit_project_paths(project, project_dir, worktree):
    """Catch explicit external Rojo paths, including nested project files and symlinks."""
    seen = set()

    def visit(node, base):
        if isinstance(node, list):
            for child in node:
                visit(child, base)
        elif isinstance(node, dict):
            for key, child in node.items():
                if key == "$path":
                    raw = child.get("optional") if isinstance(child, dict) else child
                    if not isinstance(raw, str):
                        raise EnvironmentError("unsupported Rojo $path; expected string or optional path")
                    path = (base / raw).resolve()
                    if not inside(path, worktree):
                        raise EnvironmentError(f"Rojo path escapes the worktree: {path}")
                    if path.is_dir() and (path / "default.project.json").exists():
                        path = path / "default.project.json"
                    if path.name.endswith(".project.json") and path.exists() and path not in seen:
                        seen.add(path)
                        visit(read_json(path), path.parent)
                else:
                    visit(child, base)
    visit(project, project_dir)


def verification_code(token):
    # A fresh MCP read of this marker proves which worktree the Rojo plugin actually synced.
    return '''--!strict
local RunService = game:GetService("RunService")
assert(not RunService:IsRunning(), "Verify in Edit mode before starting a playtest")
local marker = game:GetService("ReplicatedStorage"):FindFirstChild("RDKEnvironmentId")
assert(marker and marker:IsA("StringValue"), "Connect this environment's Rojo port first")
assert(marker.Value == "%s", "Wrong environment: stop and check the Studio/Rojo assignment")
return game:GetService("HttpService"):JSONEncode({
    environment_id = marker.Value,
    place_id = game.PlaceId,
    name = game.Name,
})
''' % token


def create(args):
    repo = Path(run("git", "-C", str(Path(args.repo).resolve()), "rev-parse", "--show-toplevel"))
    revision = run("git", "-C", str(repo), "rev-parse", "--verify", args.ref + "^{commit}")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.name) or len(args.name) > 48:
        raise EnvironmentError("name must be a lowercase slug of at most 48 characters")
    project = relative_path(args.project)
    place = Path(args.place).resolve()
    if not place.is_file() or place.suffix.lower() not in (".rbxl", ".rbxlx"):
        raise EnvironmentError("--place must be a saved .rbxl or .rbxlx containing the map")
    if not args.committed_only and run("git", "-C", str(repo), "status", "--porcelain"):
        raise EnvironmentError("source has uncommitted changes; checkpoint them or explicitly use --committed-only")
    copies = [relative_path(value) for value in args.copy]
    for relative in copies:
        source = repo / relative
        if not source.exists() or not inside(source, repo):
            raise EnvironmentError(f"copy source missing or outside the source repo: {source}")
        if source.is_symlink() or (source.is_dir() and any(p.is_symlink() for p in source.rglob("*"))):
            raise EnvironmentError(f"--copy refuses symlinks: {relative}")
    if args.cameras:
        validate_cameras(args.cameras)
    root = Path(args.root).expanduser().resolve()
    if inside(root, repo):
        raise EnvironmentError("environment root must be outside the source checkout")
    key = repo.name + "-" + hashlib.sha256(str(repo).encode()).hexdigest()[:8]
    directory = root / key / args.name
    request = dict(repo=str(repo), revision=revision, project=str(project), place=str(place),
                   place_sha256=digest(place), copies=[str(p) for p in copies],
                   cameras_sha256=digest(args.cameras) if args.cameras else None,
                   requested_port=args.port)
    if args.dry_run:
        return {"dry_run": True, "directory": str(directory), "request": request}
    root.mkdir(parents=True, exist_ok=True)
    with lock(root / ".registry.lock"):
        manifest = directory / "environment.json"
        if manifest.exists():
            env = read_json(manifest)
            if env["request"] != request or not env["prepared"]:
                raise EnvironmentError(f"environment already exists with different inputs or incomplete setup: {manifest}")
            return env
        if directory.exists():
            raise EnvironmentError(f"refusing to overwrite existing directory: {directory}")
        port = reserve_port(root, args.port)
        token = uuid.uuid4().hex
        worktree = directory / "worktree"
        branch = "codex/" + args.name + "-" + token[:8]
        local_place = directory / "studio" / ("rdk-" + args.name + "-" + token[:8] + place.suffix.lower())
        served_project = worktree / project.parent / ("rdk-" + token[:8] + ".project.json")
        env = {"schema_version": 1, "id": token, "name": args.name, "root": str(root),
               "directory": str(directory), "request": request, "prepared": False,
               "worktree": str(worktree), "branch": branch, "base_revision": revision,
               "place": str(local_place), "studio": None, "studio_launcher": None,
               "rojo": {"port": port, "project": str(served_project), "process": None},
               "review": str(directory / "review"), "blender": str(directory / "blender")}
        for name in ("studio", "review/before", "review/after", "blender", "tmp", "logs"):
            (directory / name).mkdir(parents=True, exist_ok=True)
        write_json(manifest, env)
        try:
            run("git", "-C", str(repo), "worktree", "add", "-b", branch, str(worktree), revision)
            for relative in copies:
                source, target = repo / relative, worktree / relative
                if target.exists() or target.is_symlink():
                    raise EnvironmentError(f"--copy would overwrite a tracked path: {relative}")
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir():
                    shutil.copytree(source, target)
                else:
                    shutil.copy2(source, target)
            # The kit installs skills as links; those are read-only tooling, not authoring data.
            # Keep that conventional installation usable without allowing shared game assets.
            env["shared_tooling"] = []
            for path in worktree.rglob("*"):
                if path.is_symlink() and not inside(path, worktree):
                    parts = path.relative_to(worktree).parts
                    if (len(parts) == 3 and parts[0] in (".agents", ".claude") and parts[1] == "skills"
                            and (path / "SKILL.md").is_file()):
                        env["shared_tooling"].append(str(path))
                        continue
                    raise EnvironmentError(f"worktree symlink points outside its environment: {path}")
            project_path = worktree / project
            data = read_json(project_path)
            audit_project_paths(data, project_path.parent, worktree)
            if data["tree"].get("$className") != "DataModel":
                raise EnvironmentError("isolation requires a Rojo DataModel project")
            replicated = data["tree"].setdefault("ReplicatedStorage", {"$className": "ReplicatedStorage"})
            if "RDKEnvironmentId" in replicated:
                raise EnvironmentError("project already uses the reserved RDKEnvironmentId node")
            replicated["RDKEnvironmentId"] = {"$className": "StringValue", "$properties": {"Value": token}}
            data["name"] = local_place.stem
            data["servePort"], data["serveAddress"] = port, "127.0.0.1"
            for field in ("placeId", "gameId", "servePlaceIds"):
                data.pop(field, None)
            write_json(served_project, data)
            # Exclude only this generated file; the shared Git exclude file does not hide assets.
            exclude = Path(run("git", "-C", str(worktree), "rev-parse", "--git-path", "info/exclude"))
            if not exclude.is_absolute():
                exclude = worktree / exclude
            exclude.parent.mkdir(parents=True, exist_ok=True)
            with exclude.open("a") as handle:
                handle.write("\n/" + str(served_project.relative_to(worktree)) + "\n")
            shutil.copy2(place, local_place)
            (directory / "verify-studio.luau").write_text(verification_code(token))
            if args.cameras:
                shutil.copy2(args.cameras, directory / "review/cameras.json")
                env["cameras_sha256"] = digest(directory / "review/cameras.json")
            env["prepared"] = True
            write_json(manifest, env)
        except Exception as error:
            env["preparation_error"] = str(error)
            write_json(manifest, env)
            raise EnvironmentError(f"setup incomplete; files retained for inspection at {directory}: {error}") from error
        return env


def load(value):
    path = Path(value).resolve()
    manifest = path / "environment.json" if path.is_dir() else path
    env = read_json(manifest)
    if env.get("schema_version") != 1 or Path(env["directory"]) != manifest.parent:
        raise EnvironmentError("invalid or relocated environment manifest")
    return env, manifest


def fingerprint(pid):
    result = subprocess.run(["ps", "-ww", "-p", str(pid), "-o", "lstart=", "-o", "command="],
                            text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def owned_process(env):
    process = env["rojo"]["process"]
    return process_is_alive(process)


def process_is_alive(process):
    return bool(process and fingerprint(process["pid"]) == process["fingerprint"])


def decode_rojo_info(payload):
    """Rojo 7.7 uses MessagePack; older releases return JSON. Bound the small handshake."""
    if payload.startswith(b"{"):
        return json.loads(payload)
    offset = 0

    def take(size):
        nonlocal offset
        value = payload[offset:offset + size]
        if len(value) != size:
            raise ValueError("truncated Rojo MessagePack response")
        offset += size
        return value

    def number(size, signed=False):
        return int.from_bytes(take(size), "big", signed=signed)

    def value(depth=0):
        if depth > 8:
            raise ValueError("Rojo handshake nesting exceeds limit")
        tag = number(1)
        if tag < 0x80:
            return tag
        if tag >= 0xE0:
            return tag - 256
        if tag in (0xC0, 0xC2, 0xC3):
            return {0xC0: None, 0xC2: False, 0xC3: True}[tag]
        if 0xCC <= tag <= 0xD3:
            return number(2 ** ((tag - 0xCC) % 4), signed=tag >= 0xD0)
        if 0xA0 <= tag <= 0xBF or tag in (0xD9, 0xDA, 0xDB):
            size = tag & 0x1F if tag <= 0xBF else number(2 ** (tag - 0xD9))
            return take(size).decode("utf-8")
        if 0x90 <= tag <= 0x9F or tag in (0xDC, 0xDD):
            size = tag & 0x0F if tag <= 0x9F else number(2 ** (tag - 0xDC + 1))
            if size > 4096:
                raise ValueError("Rojo handshake array exceeds limit")
            return [value(depth + 1) for _ in range(size)]
        if 0x80 <= tag <= 0x8F or tag in (0xDE, 0xDF):
            size = tag & 0x0F if tag <= 0x8F else number(2 ** (tag - 0xDE + 1))
            if size > 128:
                raise ValueError("Rojo handshake map exceeds limit")
            result = {}
            for _ in range(size):
                key = value(depth + 1)
                if not isinstance(key, str):
                    raise ValueError("Rojo handshake map keys must be strings")
                result[key] = value(depth + 1)
            return result
        raise ValueError(f"unsupported Rojo handshake MessagePack tag: {tag:#x}")

    result = value()
    if offset != len(payload) or not isinstance(result, dict):
        raise ValueError("invalid Rojo handshake")
    return result


def rojo_info(port):
    # Do not send a loopback request through an inherited proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f"http://127.0.0.1:{port}/api/rojo", timeout=1) as response:
        payload = response.read(65537)
        if len(payload) > 65536:
            raise ValueError("Rojo handshake exceeds size limit")
        return decode_rojo_info(payload)


def start(env, args):
    if not env["prepared"]:
        raise EnvironmentError("environment preparation is incomplete")
    if owned_process(env):
        return
    port = env["rojo"]["port"]
    if not available(port):
        raise EnvironmentError(f"port {port} is occupied by an unowned process; it will not be stopped")
    binary = args.rojo or shutil.which("rojo")
    if not binary:
        raise EnvironmentError("Rojo missing; install the project's pinned toolchain")
    command = [binary, "serve", env["rojo"]["project"], "--address", "127.0.0.1", "--port", str(port)]
    with (Path(env["directory"]) / "logs/rojo.log").open("ab") as output:
        child = subprocess.Popen(command, cwd=env["worktree"], stdin=subprocess.DEVNULL,
                                 stdout=output, stderr=output, start_new_session=True)
    try:
        deadline = time.monotonic() + args.timeout
        last_probe = "no handshake received"
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise EnvironmentError("Rojo exited; inspect logs/rojo.log")
            try:
                info = rojo_info(port)
                if info.get("sessionId") and info.get("projectName") == Path(env["place"]).stem:
                    identity = fingerprint(child.pid)
                    if identity and env["rojo"]["project"] in identity:
                        env["rojo"]["process"] = {"pid": child.pid, "fingerprint": identity,
                                                   "session_id": info["sessionId"]}
                        env["studio"] = None
                        return
                    last_probe = "process identity does not contain the isolated project path"
                else:
                    last_probe = "handshake does not match the isolated project name/session"
            except (OSError, ValueError) as error:
                last_probe = str(error)
            time.sleep(0.1)
        raise EnvironmentError(f"Rojo did not become ready ({last_probe}); inspect logs/rojo.log")
    except BaseException:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        raise


def stop(env):
    if owned_process(env):
        process = env["rojo"]["process"]
        os.kill(process["pid"], signal.SIGTERM)
        deadline = time.monotonic() + 5
        while owned_process(env) and time.monotonic() < deadline:
            time.sleep(0.1)
        if owned_process(env):
            raise EnvironmentError("owned Rojo process did not stop; retained its process record")
    env["rojo"]["process"] = None
    env["studio"] = None


def open_studio(env, args):
    if sys.platform != "darwin":
        raise EnvironmentError("automatic Studio launch requires macOS; open the manifest's place manually")
    if process_is_alive(env.get("studio_launcher")):
        # open -W remains alive during login/loading and until the application exits.
        # A missing MCP listing is not evidence that the previous launch failed.
        return
    app = args.app or os.environ.get("RDK_STUDIO_APP", "/Applications/RobloxStudio.app")
    binary = str(Path(app) / "Contents/MacOS/RobloxStudio")
    processes = run("ps", "-ww", "-axo", "command=").splitlines()
    for command in processes:
        if (command.strip().startswith(binary + " ") and "-localPlaceFile" in command
                and re.search(r"(?:^|\s)" + re.escape(env["place"]) + r"(?:$|\s)", command)):
            return
    if env.get("studio_launch_requested") and not args.reopen:
        return
    if env.get("studio_launch_requested") and not env.get("studio_launcher"):
        raise EnvironmentError("previous Studio launch has no lifecycle record; inspect/close it before creating a new environment")
    # Pass the document to the new process, rather than a LaunchServices document-open event
    # that can be routed to another Studio when several instances start together.
    command = ["open", "-n", "-W", "-a", app, "--args", "-task", "EditFile", "-localPlaceFile", env["place"]]
    with (Path(env["directory"]) / "logs/studio-launch.log").open("ab") as output:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                                 start_new_session=True)
    # The launcher is deliberately kept alive by -W; persist it before returning to the agent.
    identity = fingerprint(child.pid)
    if not identity or child.poll() is not None:
        raise EnvironmentError("Studio launcher exited; inspect logs/studio-launch.log before retrying")
    env["studio_launcher"] = {"pid": child.pid, "fingerprint": identity}
    env["studio_launch_requested"] = True
    env["studio"] = None


def bind(env, args):
    if not owned_process(env):
        raise EnvironmentError("start this environment's Rojo before binding Studio")
    instances = read_json(args.studios)["studios"]
    local_matches = [entry for entry in instances if Path(env["place"]).stem in entry["name"]]
    if len(local_matches) != 1:
        raise EnvironmentError("expected exactly one Studio with this local filename; close duplicate copies before binding")
    matches = [entry for entry in instances if entry["id"] == args.studio_id]
    if len(matches) != 1 or Path(env["place"]).stem not in matches[0]["name"]:
        raise EnvironmentError("studio_id must identify the uniquely named local place in a fresh Studio listing")
    proof = read_json(args.proof)
    if proof.get("environment_id") != env["id"]:
        raise EnvironmentError("Studio proof is for a different environment")
    for other in manifests(env["root"]):
        if other["id"] != env["id"] and (other.get("studio") or {}).get("id") == args.studio_id:
            raise EnvironmentError("studio_id is already assigned to another environment")
    env["studio"] = {"id": args.studio_id, "name": matches[0]["name"],
                     "verified_at": time.time(), "rojo_session_id": env["rojo"]["process"]["session_id"]}


def cameras(env):
    path = Path(env["review"]) / "cameras.json"
    if not path.exists() or digest(path) != env.get("cameras_sha256"):
        raise EnvironmentError("review cameras missing or changed; create with --cameras for a reproducible review")
    return validate_cameras(path)


def capture_plan(env, phase):
    if not env["studio"] or not owned_process(env):
        raise EnvironmentError("bind a verified Studio instance before capturing")
    return [{"tool": "screen_capture", "arguments": {
        "studio_id": env["studio"]["id"], "capture_id": env["name"] + "-" + phase + "-" + view["name"],
        "camera_position": view["camera_position"], "look_at_position": view["look_at_position"]},
        "save_to": str(Path(env["review"]) / phase / (view["name"] + ".png"))}
        for view in cameras(env)["views"]]


def record_capture(env, args):
    if not env["studio"]:
        raise EnvironmentError("bind a verified Studio instance before recording captures")
    views = {view["name"] for view in cameras(env)["views"]}
    if args.view not in views:
        raise EnvironmentError("unknown camera view")
    source = Path(args.image).resolve()
    with source.open("rb") as handle:
        header = handle.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise EnvironmentError("capture must be a PNG image")
    size = list(struct.unpack(">II", header[16:24]))
    directory = Path(env["review"]) / args.phase
    destination = directory / (args.view + ".png")
    record = directory / (args.view + ".json")
    if record.exists():
        raise EnvironmentError("capture already recorded; keep the baseline or create another review environment")
    if args.phase == "after":
        before = Path(env["review"]) / "before" / (args.view + ".json")
        if not before.exists() or read_json(before)["size"] != size:
            raise EnvironmentError("record the matching before image first, at the same resolution")
    if source != destination:
        shutil.copy2(source, destination)
    write_json(record, {"environment_id": env["id"], "studio_id": (env["studio"] or {}).get("id"),
                        "view": args.view, "phase": args.phase, "size": size,
                        "camera_sha256": env["cameras_sha256"], "image_sha256": digest(destination)})
    return {"image": str(destination), "record": str(record)}


def blender(env, args):
    if not env["prepared"]:
        raise EnvironmentError("environment preparation is incomplete")
    script = local_path(env, args.script)
    blend = local_path(env, args.blend) if args.blend else None
    binary = args.binary or os.environ.get("RDK_BLENDER_BIN") or shutil.which("blender")
    if not binary and Path("/Applications/Blender.app/Contents/MacOS/Blender").exists():
        binary = "/Applications/Blender.app/Contents/MacOS/Blender"
    if not binary:
        raise EnvironmentError("Blender missing; set RDK_BLENDER_BIN")
    variables = os.environ.copy()
    for suffix in ("RESOURCES", "CONFIG", "SCRIPTS", "EXTENSIONS", "DATAFILES"):
        directory = Path(env["blender"]) / ("user-" + suffix.lower())
        directory.mkdir(exist_ok=True)
        variables["BLENDER_USER_" + suffix] = str(directory)
    variables["TMPDIR"] = str(Path(env["directory"]) / "tmp")
    command = [binary, "--background", "--factory-startup", "--disable-autoexec"]
    if blend:
        command.append(str(blend))
    script_args = args.script_args[1:] if args.script_args[:1] == ["--"] else args.script_args
    command += ["--python-exit-code", "1", "--python", str(script), "--"] + script_args
    # One writer per environment, while different environments can render concurrently.
    with lock(Path(env["directory"]) / ".blender.lock"):
        return subprocess.call(command, cwd=env["worktree"], env=variables)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    new = commands.add_parser("create", help="create a worktree, place copy and per-agent resources")
    new.add_argument("name")
    new.add_argument("--repo", default=".")
    new.add_argument("--ref", default="HEAD")
    new.add_argument("--place", required=True)
    new.add_argument("--project", default="default.project.json")
    default_home = Path(os.environ.get("RDK_HOME", str(Path.home())))
    new.add_argument("--root", default=str(default_home / ".local/share/roblox-dev-kit/environments"))
    new.add_argument("--port", type=int)
    new.add_argument("--copy", action="append", default=[], help="copy an untracked dependency, relative to source repo")
    new.add_argument("--committed-only", action="store_true", help="explicitly exclude dirty working-tree changes")
    new.add_argument("--cameras", help="immutable JSON views for before/after review")
    new.add_argument("--dry-run", action="store_true")
    for name in ("status", "start", "stop", "open-studio", "bind-studio", "capture-plan", "record-capture", "blender"):
        command = commands.add_parser(name)
        command.add_argument("environment", help="environment directory or environment.json")
        if name == "start":
            command.add_argument("--rojo")
            command.add_argument("--timeout", type=float, default=15)
        elif name == "open-studio":
            command.add_argument("--app")
            command.add_argument("--reopen", action="store_true", help="launch again after the previous instance was closed")
        elif name == "bind-studio":
            command.add_argument("--studio-id", required=True)
            command.add_argument("--studios", required=True, help="fresh list_roblox_studios JSON")
            command.add_argument("--proof", required=True, help="JSON returned by verify-studio.luau in that instance")
        elif name in ("capture-plan", "record-capture"):
            command.add_argument("--phase", choices=("before", "after"), required=True)
            if name == "record-capture":
                command.add_argument("--view", required=True)
                command.add_argument("--image", required=True)
        elif name == "blender":
            command.add_argument("--binary")
            command.add_argument("--blend")
            command.add_argument("script")
            command.add_argument("script_args", nargs=argparse.REMAINDER)
    return result


def main():
    args = parser().parse_args()
    try:
        if args.command == "create":
            output = create(args)
        else:
            env, manifest = load(args.environment)
            if args.command == "blender":
                return blender(env, args)
            with lock(Path(env["root"]) / ".registry.lock"):
                env, manifest = load(args.environment)
                if args.command == "status":
                    output = dict(env, rojo_running=owned_process(env),
                                  studio_binding="recorded; reverify via MCP" if env["studio"] else "unbound")
                elif args.command == "capture-plan":
                    output = capture_plan(env, args.phase)
                elif args.command == "record-capture":
                    output = record_capture(env, args)
                else:
                    {"start": start, "open-studio": open_studio, "bind-studio": bind}.get(
                        args.command, lambda value, _: stop(value))(env, args)
                    write_json(manifest, env)
                    output = env
        print(json.dumps(output, indent=2))
        return 0
    except (EnvironmentError, OSError, ValueError, KeyError) as error:
        print(f"roblox-isolate: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
