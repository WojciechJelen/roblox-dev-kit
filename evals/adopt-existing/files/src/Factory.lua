-- Builds car models from the templates in ServerStorage.Cars.
local Factory = {}

function Factory.build(name)
	local template = game:GetService("ServerStorage").Cars:FindFirstChild(name)
	return template and template:Clone()
end

return Factory
