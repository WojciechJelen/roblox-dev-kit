--!strict
-- Client entry point. Requires every ModuleScript in Controllers (in name order), calls init() on all of
-- them, then start() on all of them. init() sets up state and must not yield or use other controllers;
-- start() runs in its own thread, so it may yield and may use any controller.

type Lifecycle = {
	init: (() -> ())?,
	start: (() -> ())?,
}

local controllersFolder = (script.Parent :: Instance):WaitForChild("Controllers")

local moduleScripts: { ModuleScript } = {}
for _, child in controllersFolder:GetChildren() do
	if child:IsA("ModuleScript") then
		table.insert(moduleScripts, child)
	end
end
table.sort(moduleScripts, function(a, b)
	return a.Name < b.Name
end)

-- Controllers are discovered at runtime, so these requires cannot be resolved statically.
local requireDynamic = require :: any

local controllers: { Lifecycle } = {}
for _, moduleScript in moduleScripts do
	table.insert(controllers, requireDynamic(moduleScript))
end

for _, controller in controllers do
	if controller.init then
		controller.init()
	end
end
for _, controller in controllers do
	if controller.start then
		task.spawn(controller.start)
	end
end
