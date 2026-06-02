local Shared = require("./Shared")

local Signal = Shared.Signal
local ServerEnviornment = Shared.GetEnvironment()

local function Clone(Source: buffer): buffer
	local Size = buffer.len(Source)
	local Target = buffer.create(Size)
	buffer.copy(Target, 0, Source, 0, Size)
	return Target
end

local function Fire(Reliable: boolean, ...)
	local Buffer, Instances = ...

	Buffer = Clone(Buffer)
	Instances = table.clone(Instances)

	Shared.Bridge:Fire("Server", Reliable and "BLINK_RELIABLE_REMOTE" or "BLINK_UNRELIABLE_REMOTE", Buffer, Instances, select(3, ...))
end

ServerEnviornment.Instances.BLINK_RELIABLE_REMOTE = {
	FireClient = function(self, Player, Buffer, Instances, ...)
		Fire(true, Buffer, Instances, ...)
	end,
	FireAllClients = function(self, Buffer, Instances, ...)
		Fire(true, Buffer, Instances, ...)
	end,
	OnServerEvent = Signal.new(),
}

ServerEnviornment.Instances.BLINK_UNRELIABLE_REMOTE = {
	FireClient = function(self, Player, Buffer, Instances, ...)
		Fire(false, Buffer, Instances, ...)
	end,
	FireAllClients = function(self, Buffer, Instances, ...)
		Fire(false, Buffer, Instances, ...)
	end,
	OnServerEvent = Signal.new(),
}

Shared.Bridge:Connect(function(From: string, Remote: string, Buffer: buffer, Instances: { Instance }, ...)
	if From == "Server" then
		return
	end

	ServerEnviornment.Instances[Remote].OnServerEvent:Fire(Shared.Player, Buffer, Instances, ...)
end)

return ServerEnviornment
