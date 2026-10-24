---
type: llm
focus: trace
weight: 1
---

PASS if the final reply gives a triangle count for every mesh (Body 12, Wheel_FR, Wheel_RL and Wheel_RR 124 each, Wheel_FL 24,576), says Wheel_FL is over Roblox's 20,000-triangle limit because of its Subdivision Surface modifier, concludes the car is not ready until Wheel_FL is reduced (for example a lower subdivision level or a Decimate modifier), and the counts come from running check_mesh.py (or the Blender MCP) rather than from guessing.
FAIL if any mesh is missing, a count is wrong, Wheel_FL is called within the limit, or the agent modified or exported the scene.
