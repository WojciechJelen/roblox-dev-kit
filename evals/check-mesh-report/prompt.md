---
tags: [blender-to-roblox, requires-blender]
max_turns: 25
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Bash]
---

Is the car in ./car.blend ready to go into my Roblox game? Check every mesh against Roblox's limits and tell me each one's triangle count. Don't change or export anything yet.

Load ./blender.env in the same shell command whenever you run Blender (`set -a; . ./blender.env; set +a; ...`); it keeps Blender's settings inside this folder.
