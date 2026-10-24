--!strict
-- Server entry point. Requires every ModuleScript in Services (in name order), calls init() on all of
-- them, then start() on all of them. init() sets up state and must not yield or use other services;
-- start() runs in its own thread, so it may yield and may use any service.

type Lifecycle = {
	init: (() -> ())?,
	start: (() -> ())?,
}

local servicesFolder = (script.Parent :: Instance):WaitForChild("Services")

local moduleScripts: { ModuleScript } = {}
for _, child in servicesFolder:GetChildren() do
	if child:IsA("ModuleScript") then
		table.insert(moduleScripts, child)
	end
end
table.sort(moduleScripts, function(a, b)
	return a.Name < b.Name
end)

-- Services are discovered at runtime, so these requires cannot be resolved statically.
local requireDynamic = require :: any

local services: { Lifecycle } = {}
for _, moduleScript in moduleScripts do
	table.insert(services, requireDynamic(moduleScript))
end

for _, service in services do
	if service.init then
		service.init()
	end
end
for _, service in services do
	if service.start then
		task.spawn(service.start)
	end
end
