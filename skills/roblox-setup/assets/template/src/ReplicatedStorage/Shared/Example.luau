--!strict
-- Code shared by server and client lives in ReplicatedStorage.Shared.

local Example = {}

function Example.greet(name: string): string
	return `Hello, {name}!`
end

return Example
