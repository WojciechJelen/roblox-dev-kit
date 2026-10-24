--!strict
-- Example controller. Copy this file to add a controller; Client.client.luau picks it up automatically.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Example = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Example"))

local ExampleController = {}

function ExampleController.init()
	-- Look up UI and local state here. Do not yield or call other controllers yet.
end

function ExampleController.start()
	print(Example.greet(Players.LocalPlayer.DisplayName))
end

return ExampleController
