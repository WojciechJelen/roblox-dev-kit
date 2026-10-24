local Factory = require(game:GetService("ReplicatedStorage").RivalsFactory)

game:GetService("Players").PlayerAdded:Connect(function(player)
	print(player.Name, "joined; car:", Factory.build("Starter"))
end)
