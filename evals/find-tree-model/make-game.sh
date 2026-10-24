#!/usr/bin/env bash
# A minimal Rojo game in the eval workspace: a project file and one server script.
set -euo pipefail
mkdir -p src/ServerScriptService
cat >default.project.json <<'JSON'
{
  "name": "Forest Run",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": { "$path": "src/ServerScriptService" }
  }
}
JSON
cat >src/ServerScriptService/Server.server.luau <<'LUAU'
--!strict
-- Forest Run: the forest level is a 400x400 stud baseplate with a path; it still needs trees.
print("Forest Run server started")
LUAU
