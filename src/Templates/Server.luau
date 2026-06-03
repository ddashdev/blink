return [[local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsServer() then
    error("Server network module can only be required from the server.")
end

local Reliable: RemoteEvent = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
if not Reliable then
    local RemoteEvent = Instance.new("RemoteEvent")
    RemoteEvent.Name = BASE_EVENT_NAME .. "_RELIABLE_REMOTE"
    RemoteEvent.Parent = ReplicatedStorage
    Reliable = RemoteEvent
end

local Unreliable: UnreliableRemoteEvent = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent
if not Unreliable then
    local UnreliableRemoteEvent = Instance.new("UnreliableRemoteEvent")
    UnreliableRemoteEvent.Name = BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE"
    UnreliableRemoteEvent.Parent = ReplicatedStorage
    Unreliable = UnreliableRemoteEvent
end

local PlayersMap: {[Player]: BufferSave} = {}
local ReadyPlayers: {[Player]: true?} = {}
local ReadyPlayerCallbacks: { (Player) -> () } = {}

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
    ReadyPlayers[Player] = nil
end)

local function MarkPlayerReady(Player: Player)
    if ReadyPlayers[Player] then
        return
    end

    ReadyPlayers[Player] = true

    for _, Callback in ReadyPlayerCallbacks do
        task.spawn(Callback, Player)
    end
end

local function OnNewReadyPlayer(Callback: (Player: Player) -> ()): () -> ()
    table.insert(ReadyPlayerCallbacks, Callback)

    return function()
        local Index = table.find(ReadyPlayerCallbacks, Callback)
        if Index then
            table.remove(ReadyPlayerCallbacks, Index)
        end
    end
end

local function StepReplication()
    if not Started then
        WarnNotStarted("StepReplication")
        return
    end

    for Player, Send in PlayersMap do
        if ReadyPlayers[Player] ~= true then
            continue
        end

        if Send.Cursor <= 0 then
            continue
        end

        local Buffer = buffer.create(Send.Cursor)
        buffer.copy(Buffer, 0, Send.Buffer, 0, Send.Cursor)
        Reliable:FireClient(Player, Buffer, Send.Instances)

        Send.Size = 64
        Send.Cursor = 0
        Send.Buffer = buffer.create(64)
        table.clear(Send.Instances)
    end
end
]]
