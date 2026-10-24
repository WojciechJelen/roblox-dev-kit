--!strict
-- Example service. Copy this file to add a service; Server.server.luau picks it up automatically.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Example = require(ReplicatedStorage.Shared.Example)

local ExampleService = {}

function ExampleService.init()
	-- Create state, remotes and caches here. Do not yield or call other services yet.
end

function ExampleService.start()
	Players.PlayerAdded:Connect(function(player)
		print(Example.greet(player.Name))
	end)
end

return ExampleService
