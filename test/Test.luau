local Format = require("../src/Modules/Format")
local Parser = require("../src/Parser")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local Compiler = "init"
local Sources = fs.readDir("./Sources")

local COMPILE_TEST_FILE = "../../test/Sources/Test"

local function OkPrint(Message: string)
	stdio.write(`\r[{stdio.color("green")}OK{stdio.color("reset")}] {Message}\n`)
end

local function ErrorPrint(Message: string)
	stdio.write(`\r[{stdio.color("red")}ERROR{stdio.color("reset")}] {Message}\n`)
	process.exit(20)
end

local function PrettyPrint(Color: stdio.Color, Message: string, DontReturn: boolean?)
	stdio.write(`{stdio.color(Color)}{Message}{not DontReturn and "\n" or ""}{stdio.color("reset")}`)
end

if table.find(process.args, "--yes") or stdio.prompt("confirm" :: "confirm", "Compile files?") then
	PrettyPrint("blue", "Clearing Network folder...")
	if fs.isDir("../Network") then
		fs.removeDir("../Network")
		fs.writeDir("../Network")
		OkPrint(`Cleared Network folder.`)
	end

	PrettyPrint("blue", "Compiling source files...")
	for _, File in Sources do
		local Metadata = fs.metadata(`./Sources/{File}`)
		if Metadata.kind ~= "file" then
			continue
		end

		local Path = `../../test/Sources/{File}`
		PrettyPrint("cyan", `Compiling: {File}...`, true)
		local Result = process.exec("lune", { "run", Compiler, Path, "--", "--yes" }, { cwd = "../src/CLI" })
		if not Result.ok then
			ErrorPrint(`{File} failed to compile!\n{Result.stderr}`)
		else
			OkPrint(`{File} compiled successfully.`)
		end
	end

	PrettyPrint("green", `Successfully compiled {#Sources}/{#Sources} source files!`)
end

local Shared = require("./Shared")
local BaseEnvironment = Shared.GetEnvironment()
local ClientEnvironment = require("./Client")
local ServerEnvironment = require("./Server")

local function MockTypeof(a: any)
	local TypeofA = typeof(a)
	if TypeofA == "table" and a.__typeof then
		return a.__typeof
	end

	return TypeofA
end

local Warnings = {}
local function MockWarn(Message: string)
	table.insert(Warnings, Message)
end

local function MockRequire(Path: string, Environment)
	local Source = fs.readFile(Path)
	local Bytecode = luau.compile(Source, {
		optimizationLevel = 1,
		debugLevel = 2,
	})

	Environment._G = {}
	Environment.task = task
	Environment.typeof = MockTypeof
	Environment.warn = MockWarn
	Environment.require = function()
		error("require is not supported")
	end

	local Execute = luau.load(Bytecode, {
		debugName = Path,
		environment = Environment,
	})

	return Execute()
end

local Client: typeof(require("../Network/Client")) = MockRequire("../Network/Client.luau", {
	game = ClientEnvironment.game,
	Color3 = ClientEnvironment.Color3,
	DateTime = ClientEnvironment.DateTime,
	BrickColor = ClientEnvironment.BrickColor,
})

local Server: typeof(require("../Network/Server")) = MockRequire("../Network/Server.luau", {
	game = ServerEnvironment.game,
	Color3 = ServerEnvironment.Color3,
	DateTime = ServerEnvironment.DateTime,
	BrickColor = ServerEnvironment.BrickColor,
})

local ClientExports = Client.Exports
local ServerExports = Server.Exports

--> Helper functions
local function GetFlags(Amount: number): { [string]: boolean }
	local Flags = {}
	for Index = 1, Amount do
		Flags[`F{Index}`] = (math.random(1, 2) == 2)
	end
	return Flags
end

local function Fail(Name: string, Expect: any, Got: any)
	ErrorPrint(`Failed "{Name}"\nExpected: {Format(Expect)}\nGot: {Format(Got)}.`)
end

local function Equals(a: any, b: any)
	local Cyclic = {}
	local function Compare(a: any, b: any)
		local TypeA = type(a)
		local TypeB = type(b)

		if TypeA ~= TypeB then
			return false
		end

		if TypeA == "table" then
			if Cyclic[a] then
				return Cyclic[a] == b
			end

			Cyclic[a] = b

			local KeysB = {}
			local TableKeysB = {}

			for Key in b do
				if type(Key) == "table" then
					table.insert(TableKeysB, Key)
				end

				KeysB[Key] = true
			end

			for KeyA, ValueA in pairs(a) do
				local ValueB = b[KeyA]
				if type(KeyA) == "table" then
					local Match = false
					for Index, Key in TableKeysB do
						if Equals(KeyA, Key) and Compare(ValueA, b[Key]) then
							Match = true
							KeysB[Key] = nil
							table.remove(TableKeysB, Index)
							break
						end
					end

					if Match == false then
						return false
					end
				else
					if ValueB == nil then
						return false
					end

					KeysB[KeyA] = nil

					if not Compare(ValueA, ValueB) then
						return false
					end
				end
			end

			if next(KeysB) then
				return false
			end

			return true
		elseif TypeA == "buffer" then
			return buffer.tostring(a) == buffer.tostring(b)
		end

		return a == b
	end

	return Compare(a, b)
end

local function FireAndFail(Name: string, OutgoingEvent: any, IncomingEvent: any, Data: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local Disconnect = IncomingEvent.On(function(First, Second)
		Result = if Second ~= nil then Second else First
	end)

	local Success = pcall(function()
		if OutgoingEvent.FireAll then
			OutgoingEvent.FireAll(Data)
		else
			OutgoingEvent.Fire(Data)
		end
	end)

	if not Success then
		OkPrint(`Event "{Name}" passed!`)
		return
	end

	--> Wait for replication
	task.wait(1 / 30)

	if Result ~= nil then
		ErrorPrint(`Failed "{Name}", expected it to fail, got "{Result}" instead.`)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	local Disconnect = IncomingEvent.On(function(First, Second)
		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end)

	if IsServerSending then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function InvokeAndExpect(
	Name: string,
	ClientFunction: any,
	ServerFunction: any,
	Data: any,
	Return: boolean?,
	YieldFor: number?
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local ServerRecieve: unknown
	ServerFunction.On(function(Player, Recieve: any)
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to {Name} to be Player, got {Player} instead.`)
		end

		ServerRecieve = Recieve
		if not Return then
			error("Expects fail")
		end

		if YieldFor then
			task.wait(YieldFor)
		end

		return Recieve
	end)

	local Success, Result = pcall(function()
		return ClientFunction.Invoke(Data)
	end)

	if not Return and Success then
		ErrorPrint(`Expected {Name} to encounter an error but it succeeded.`)
	elseif not Success and Return then
		ErrorPrint(`Expected {Name} to succeed but it encountered an error, {Result}.`)
	elseif Success and Return then
		if ServerRecieve ~= Data then
			ErrorPrint(`Expected server {Name} to recieve {Data}, got {ServerRecieve} instead.`)
		end

		if not Equals(Result, Data) then
			ErrorPrint(`Expected client {Name} to recieve {Data}, got {Result} instead.`)
		end
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function QueueAndExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	if OutgoingEvent.FireAll then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Let it sit in queue
	task.wait(0.5)

	local Disconnect = IncomingEvent.On(function(First, Second)
		Result = if Second ~= nil then Second else First
	end)

	--> Wait for queue to empty
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectAll(Name: string, OutgoingEvent: any, IncomingEvent: any, Values: { any })
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Events = 0
	local Results: { unknown } = {}
	local Disconnect = IncomingEvent.On(function(First, Second)
		local Value = (if Second ~= nil then Second else First)

		Events += 1
		Results[Events] = Value
	end)

	local Method = OutgoingEvent.FireAll or OutgoingEvent.Fire
	for Index = 1, table.maxn(Values) do
		Method(Values[Index])
	end

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Expect in Values do
		local Result = Results[Index]
		if not Equals(Expect, Result) then
			Fail(Name, Expect, Result)
		end
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAllAndExpectAll(
	Name: string,
	Times: number,
	Events: { [string]: { Outgoing: any, Incoming: any, Data: { any } } }
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { { unknown } } = {}
	local Disconnects: { () -> () } = {}

	--> Connect to events
	for Index, Event in Events do
		local EventResults = {}
		Results[Index] = EventResults
		table.insert(
			Disconnects,
			Event.Incoming.On(function(...)
				table.insert(EventResults, { ... })
			end)
		)
	end

	--> Fire events
	for Index, Event in Events do
		local Outgoing = Event.Outgoing
		local Method = Outgoing.FireAll or Outgoing.Fire
		for Index = 1, Times do
			Method(table.unpack(Event.Data))
		end
	end

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Event in Events do
		local Data = Event.Data
		local EventResults = Results[Index]
		for ResultIndex = 1, Times do
			local Result = EventResults[ResultIndex]
			if not Equals(Data, Result) then
				ErrorPrint(`Failed "{Name}" at {Index}, mismatched value at {ResultIndex}.`)
			end
		end
	end

	for _, Disconnect in Disconnects do
		Disconnect()
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectTuple(Name: string, OutgoingEvent: any, IncomingEvent: any, ...: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { unknown } = {}
	local Disconnect = IncomingEvent.On(function(...)
		Results = { ... }
	end)

	local Method = OutgoingEvent.FireAll or OutgoingEvent.Fire
	Method(...)

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Expect in { ... } do
		local Result = Results[Index]
		if not Equals(Expect, Result) then
			ErrorPrint(`Failed "{Name}", mismatched value at {Index}. Expected {Expect}, got {Result} instead.`)
		end
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function InvokeAndExpectTuple(
	Name: string,
	ClientFunction: any,
	ServerFunction: any,
	Data: { any },
	Return: { any }
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local ServerRecieve: { unknown }
	ServerFunction.On(function(Player, ...)
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to {Name} to be Player, got {Player} instead.`)
		end

		ServerRecieve = { ... }
		return table.unpack(Return)
	end)

	local ClientRecieve: { unknown }
	local Success, Error = pcall(function()
		ClientRecieve = { ClientFunction.Invoke(table.unpack(Data)) }
	end)

	if not Success then
		ErrorPrint(`Expected {Name} to succeed but it encountered an error, {Error}.`)
	elseif Success and Return then
		if not Equals(ServerRecieve, Data) then
			ErrorPrint(`Expected server {Name} to recieve {Data}, got {ServerRecieve} instead.`)
		end

		if not Equals(ClientRecieve, Return) then
			ErrorPrint(`Expected client {Name} to recieve {Data}, got {ClientRecieve} instead.`)
		end
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireManyAndExpectMany(Name: string, Count: number, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { unknown } = {}
	local Disconnects: { () -> () } = {}

	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	for _ = 1, Count do
		table.insert(
			Disconnects,
			IncomingEvent.On(function(First, Second)
				local Value: unknown
				if IsServerRecieving then
					if tostring(First) ~= "Player" then
						ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
					end

					Value = Second
				else
					Value = First
				end

				table.insert(Results, Value)
			end)
		)
	end

	if IsServerSending then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if #Results ~= Count then
		ErrorPrint(`Failed "{Name}", expected to recieve {Count} events, got {#Results} instead.`)
	end

	for _, Result in Results do
		if not Equals(Result, Expect) then
			Fail(Name, Expect, Result)
		end
	end

	for _, Disconnect in Disconnects do
		Disconnect()
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndPollExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result = "this is wrong"
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)
	local FireEvent = IsServerSending and OutgoingEvent.FireAll or OutgoingEvent.Fire

	FireEvent(Expect)

	--> Wait for replication
	task.wait(1 / 30)

	for Index, First, Second in IncomingEvent.Iter() do
		if Index ~= 1 then
			ErrorPrint(`Failed "{Name}", expected only 1 event in the queue.`)
		end

		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectSeparate(Name: string, OutgoingEvent: any, IncomingEvent: any, Value: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	local Disconnect = IncomingEvent.On(function(First, Second)
		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end)

	if IsServerSending then
		OutgoingEvent.FireAll(Value)
	else
		OutgoingEvent.Fire(Value)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function RunClosure(Name: string, Closure: () -> ())
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Trace: string?
	local Success = xpcall(Closure, function(Error)
		Trace = debug.traceback(`Failed "{Name}": {Error}`, 2)
	end)

	if not Success then
		ErrorPrint(Trace or `Failed "{Name}"`)
	end

	OkPrint(`Test "{Name}" passed!`)

	-- cleanup
	pcall(function()
		Client.StepReplication()
		Server.StepReplication()
	end)
end

--> Tests
local Instance = setmetatable({
	__typeof = "Instance",
	IsA = function(self)
		return true
	end,
}, {
	__tostring = function()
		return "Instance"
	end,
})

local InstanceNeverIsA = setmetatable({
	__typeof = "Instance",
	ClassName = "Never",
	IsA = function(self)
		return false
	end,
}, {
	__tostring = function()
		return "Instance (Invalid)"
	end,
})

local Example: Client.Example = {
	Field = 0,
	Float16Field = 0,
	Enum = "A",
	Nested = {
		Guh = 1,
		Array = table.create(10, 0),
	},
}

PrettyPrint("blue", "Running output tests...")

FireAndExpect("Reliable Server", ServerExports.ReliableServer, ClientExports.ReliableServer, 1)
FireAndExpect("Unreliable Server", ServerExports.UnreliableServer, ClientExports.UnreliableServer, 1)
FireAndExpect("Empty Reliable Server", ServerExports.EmptyEvent, ClientExports.EmptyEvent, nil)
FireAndExpect("Empty Unreliable Server", ServerExports.EmptyUnreliableEvent, ClientExports.EmptyUnreliableEvent, nil)

FireAndExpect("Reliable Client", ClientExports.ReliableClient, ServerExports.ReliableClient, 1)
FireAndExpect("Unreliable Client", ClientExports.UnreliableClient, ServerExports.UnreliableClient, 1)
FireAndExpect("Empty Reliable Client", ClientExports.ClientEmptyEvent, ServerExports.ClientEmptyEvent, nil)
FireAndExpect(
	"Empty Unreliable Client",
	ClientExports.ClientEmptyUnreliableEvent,
	ServerExports.ClientEmptyUnreliableEvent,
	nil
)

RunClosure("Remote tamper check rejects malformed client calls", function()
	local Detected = {}
	local DisconnectTamper = Server.OnRemoteTamperingDetected(function(Player)
		table.insert(Detected, Player)
	end)

	local Called = false
	local Disconnect = ServerExports.ReliableClient.On(function()
		Called = true
	end)

	Shared.Bridge:Fire("Client", "BLINK_RELIABLE_REMOTE", buffer.create(0), {})
	task.wait(1 / 30)

	Shared.Bridge:Fire("Client", "BLINK_RELIABLE_REMOTE", buffer.create(0), {}, 1, 2, 3)
	task.wait(1 / 30)

	Disconnect()
	DisconnectTamper()

	if Called then
		ErrorPrint("Expected malformed client buffers to be dropped before listener dispatch.")
	end

	if #Detected ~= 2 or tostring(Detected[1]) ~= "Player" or tostring(Detected[2]) ~= "Player" then
		ErrorPrint(`Expected two remote tamper detections for Player, got {Format(Detected)}.`)
	end
end)

RunClosure("Server byte limit rejects oversized client buffers", function()
	local Called = false
	local Disconnect = ServerExports.ReliableClient.On(function()
		Called = true
	end)

	local BeforeWarnings = #Warnings
	Shared.Bridge:Fire(
		"Client",
		"BLINK_RELIABLE_REMOTE",
		buffer.create(99999),
		{},
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil
	)
	task.wait(1 / 30)
	Disconnect()

	if Called then
		ErrorPrint("Expected oversized client buffer to be dropped before listener dispatch.")
	end

	local Warning = Warnings[BeforeWarnings + 1]
	if not Warning or not string.find(Warning, "123456", 1, true) or not string.find(Warning, "99999", 1, true) then
		ErrorPrint(`Expected oversized buffer warning with user id and byte size, got {Format(Warning)}.`)
	end
end)

FireManyAndExpectMany("Many Reliable Sync Server", 8, ServerExports.ManyReliableSync, ClientExports.ManyReliableSync, 1)
FireManyAndExpectMany(
	"Many Reliable Async Server",
	8,
	ServerExports.ManyReliableAsync,
	ClientExports.ManyReliableAsync,
	1
)
FireManyAndExpectMany(
	"Many Unreliable Sync Server",
	8,
	ServerExports.ManyUnreliableSync,
	ClientExports.ManyUnreliableSync,
	1
)
FireManyAndExpectMany(
	"Many Unreliable Async Server",
	8,
	ServerExports.ManyUnreliableAsync,
	ClientExports.ManyUnreliableAsync,
	1
)

FireAndExpect("Unknown", ServerExports.Unknown, ClientExports.Unknown, newproxy())
FireAndExpect("Unknown (false)", ServerExports.Unknown, ClientExports.Unknown, false)
FireAndExpectAll(
	"Unknown (nil mixed)",
	ServerExports.Unknown,
	ClientExports.Unknown,
	{ "a", nil, "b", nil, nil, nil, "c" }
)

FireAndExpect(
	"Generic",
	ServerExports.Generic,
	ClientExports.Generic,
	{ Data = 0, Array = { 0 }, Optional = nil, Nested = { Value = 0 } }
)

FireAndExpect("Set 8", ServerExports.Flags8, ClientExports.Flags8, GetFlags(8))
FireAndExpect("Set 16", ServerExports.Flags16, ClientExports.Flags16, GetFlags(16))
FireAndExpect("Set 32", ServerExports.Flags32, ClientExports.Flags32, GetFlags(32))
FireAndExpect("Set >32", ServerExports.Flags33, ClientExports.Flags33, GetFlags(33))

FireAndExpect("Map", ServerExports.MapEvent, ClientExports.MapEvent, { ["string"] = 1 })
FireAndExpect("Map Struct", ServerExports.MapStructEvent, ClientExports.MapStructEvent, { Map = { string = 1 } })
FireAndExpect(
	"Map Complex",
	ServerExports.MapComplexEvent,
	ClientExports.MapComplexEvent,
	{ string = table.create(8, 1) }
)
FireAndExpect("Map Reference", ServerExports.MapReferenceEvent, ClientExports.MapReferenceEvent, { A = "A" })

FireAndExpect("Struct", ServerExports.Reference, ClientExports.Reference, Example)
FireAndExpect("Array", ServerExports.ArrayPrimitive, ClientExports.ArrayPrimitive, { 1, 2, 3, 4, 5, 6, 7, 8 })
FireAndExpect("Optional", ServerExports.OptionalPrimitive, ClientExports.OptionalPrimitive, 1)
FireAndExpect("Optional (nil)", ServerExports.OptionalPrimitive, ClientExports.OptionalPrimitive, nil)

FireAndExpect("Instance Any", ServerExports.InstanceAny, ClientExports.InstanceAny, Instance)
FireAndExpect("Instance Type", ServerExports.InstanceOfType, ClientExports.InstanceOfType, Instance)
FireAndFail("Instance Type (Fail)", ServerExports.InstanceOfType, ClientExports.InstanceOfType, nil)
FireAndExpect("Instance Optional", ServerExports.InstanceOptional, ClientExports.InstanceOptional, Instance)
FireAndExpectSeparate(
	"Instance Optional (nil)",
	ServerExports.InstanceOptional,
	ClientExports.InstanceOptional,
	Shared.ServerOnlyInstance,
	nil
)

local Array = table.create(8, Example)
FireAndExpect("Reference", ServerExports.Reference, ClientExports.Reference, Example)
FireAndExpect("Referency Array", ServerExports.ReferenceArray, ClientExports.ReferenceArray, Array)
FireAndExpect("Referency Optional", ServerExports.ReferenceOptional, ClientExports.ReferenceOptional, Example)
FireAndExpect("Referency Optional (nil)", ServerExports.ReferenceOptional, ClientExports.ReferenceOptional, nil)

InvokeAndExpect("Remote Function", ClientExports.RemoteFunction, ServerExports.RemoteFunction, 1, true)
InvokeAndExpect("Remote Function (yield)", ClientExports.RemoteFunction, ServerExports.RemoteFunction, 1, true, 1)
InvokeAndExpect("Remote Function (error)", ClientExports.RemoteFunction, ServerExports.RemoteFunction, 1, false)
InvokeAndExpect("Empty Remote Function", ClientExports.EmptyFunction, ServerExports.EmptyFunction, nil, true)
InvokeAndExpect("Unit Remote Function", ClientExports.UnitFunction, ServerExports.UnitFunction, nil, true)

QueueAndExpect("Reliable Queue", ServerExports.ReliableServer, ClientExports.ReliableServer, 1)
QueueAndExpect("Many Reliable Sync Queue", ServerExports.ManyReliableSync, ClientExports.ManyReliableSync, 1)
QueueAndExpect("Many Reliable Async Queue", ServerExports.ManyReliableAsync, ClientExports.ManyReliableAsync, 1)
--QueueAndExpect("Unreliable Queue", ServerExports.UnreliableServer, ClientExports.UnreliableServer, 1)

FireAndFail("Invalid Instance Any", ServerExports.InstanceAny, ClientExports.InstanceAny, true)
FireAndFail("Invalid Instance Type", ServerExports.InstanceOfType, ClientExports.InstanceOfType, InstanceNeverIsA)

FireAndExpectAll("Correct order", ServerExports.ReliableServer, ClientExports.ReliableServer, { 1, 2, 3, 4 })
FireAndExpectAll(
	"Multiple instances (nil and non nil)",
	ServerExports.InstanceOptional,
	ClientExports.InstanceOptional,
	{ nil, Instance, nil, Instance, Instance }
)

FireAndExpectAll("Many primitive", ServerExports.ReliableServer, ClientExports.ReliableServer, table.create(255, 1))
FireAndExpectAll("Many structs", ServerExports.Reference, ClientExports.Reference, table.create(255, Example))

FireAndExpectTuple(
	"Reliable Tuple",
	ServerExports.Tuple,
	ClientExports.Tuple,
	255,
	"A",
	65535,
	Instance,
	Instance,
	table.create(8, 0)
)
FireAndExpectTuple(
	"Unreliable Tuple",
	ServerExports.TupleUnreliable,
	ClientExports.TupleUnreliable,
	255,
	"A",
	65535,
	Instance,
	Instance
)
InvokeAndExpectTuple(
	"Function Tuple",
	ClientExports.TupleFunction,
	ServerExports.TupleFunction,
	{ 255, "A", 65535, Instance, Instance },
	{ Instance, Instance, 65535, "A", 255 }
)

FireAllAndExpectAll("Many events", 32, {
	Reliable = {
		Data = { 0 },
		Outgoing = ServerExports.ReliableServer,
		Incoming = ClientExports.ReliableServer,
	},
	Unreliable = {
		Data = { 0 },
		Outgoing = ServerExports.UnreliableServer,
		Incoming = ClientExports.UnreliableServer,
	},
	Reference = {
		Data = { Example },
		Outgoing = ServerExports.Reference,
		Incoming = ClientExports.Reference,
	},
	ReliableTuple = {
		Data = { 255, "A", 65535, Instance, Instance, table.create(8, 0) },
		Outgoing = ServerExports.Tuple,
		Incoming = ClientExports.Tuple,
	},
	UnreliableTuple = {
		Data = { 255, "A", 65535, Instance, Instance },
		Outgoing = ServerExports.TupleUnreliable,
		Incoming = ClientExports.TupleUnreliable,
	},
})

FireAndExpect(
	"TagEnum Join",
	ServerExports.PlayerEvent,
	ClientExports.PlayerEvent,
	{ Type = "Join", Name = "Player", UserId = 5 }
)
FireAndExpect(
	"TagEnum Chat",
	ServerExports.PlayerEvent,
	ClientExports.PlayerEvent,
	{ Type = "Chat", UserId = 5, Message = "Hello" }
)
FireAndExpect("TagEnum Leave", ServerExports.PlayerEvent, ClientExports.PlayerEvent, { Type = "Leave", UserId = 5 })

RunClosure("Color3", function()
	local Color = BaseEnvironment.Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))

	local Serialized = ServerExports.Color.Write(Color)
	local Deserialized = ServerExports.Color.Read(Serialized)

	assert(Color.R == Deserialized.R, `Expected {Color.R}, got {Deserialized.R}`)
	assert(Color.G == Deserialized.G, `Expected {Color.G}, got {Deserialized.G}`)
	assert(Color.B == Deserialized.B, `Expected {Color.B}, got {Deserialized.B}`)
end)

RunClosure("Color3 Array", function()
	local Array = {}
	for _ = 1, 32 do
		table.insert(
			Array,
			BaseEnvironment.Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))
		)
	end

	local Serialized = ServerExports.ColorArray.Write(Array)
	local Deserialized = ServerExports.ColorArray.Read(Serialized)

	assert(#Array == #Deserialized, `Expected {#Array} elements`)

	for Index, Got in Deserialized do
		local Expected = Array[Index]
		assert(Expected.R == Got.R, `Expected {Expected.R}, got {Got.R}`)
		assert(Expected.G == Got.G, `Expected {Expected.G}, got {Got.G}`)
		assert(Expected.B == Got.B, `Expected {Expected.B}, got {Got.B}`)
	end
end)

RunClosure("DateTime", function()
	for n = 1, 30 do
		local DateTime = BaseEnvironment.DateTime.fromUnixTimestamp(2 ^ n)
		local Serialized = ServerExports.DateSeconds.Write(DateTime)
		local Deserialized = ServerExports.DateSeconds.Read(Serialized)
		assert(
			DateTime.UnixTimestamp == Deserialized.UnixTimestamp,
			`Expected timestamp {DateTime.UnixTimestamp}, got {Deserialized.UnixTimestamp}`
		)
	end
end)

RunClosure("DateTimeMillis", function()
	for n = 1, 30 do
		local DateTime = BaseEnvironment.DateTime.fromUnixTimestampMillis(2 ^ n)
		local Serialized = ServerExports.DateMilliseconds.Write(DateTime)
		local Deserialized = ServerExports.DateMilliseconds.Read(Serialized)
		assert(
			DateTime.UnixTimestampMillis == Deserialized.UnixTimestampMillis,
			`Expected timestamp {DateTime.UnixTimestampMillis}, got {Deserialized.UnixTimestampMillis}`
		)
	end
end)

RunClosure("BrickColor", function()
	local BrickColor = BaseEnvironment.BrickColor.new(373)
	local Serialized = ServerExports.BrickkColor.Write(BrickColor)
	local Deserialized = ServerExports.BrickkColor.Read(Serialized)

	assert(
		BrickColor.Number == Deserialized.Number,
		`Expected BrickColor number to be {BrickColor.Number}, got {Deserialized.Number}`
	)
end)

RunClosure("Nested Map", function()
	local Map = { string = 1 }
	local Serialized = ServerExports.MapNested.Write({ [Map] = Map })
	local Deserialized = ServerExports.MapNested.Read(Serialized)

	local Elements = 0
	for KeyMap, ValueMap in Deserialized do
		if Elements >= 1 then
			error("Deserialized doesn't match original")
		end

		Elements += 1
		assert(type(KeyMap) == "table", "Deserialized doesn't match original")
		assert(type(ValueMap) == "table", "Deserialized doesn't match original")
		assert(type(KeyMap.string) == "number", "Deserialized doesn't match original")
		assert(type(ValueMap.string) == "number", "Deserialized doesn't match original")
	end
end)

RunClosure("Standalone", function()
	local Original = {
		One = 1,
		Two = 2,
		Three = 3,
		Event = { Type = "Join", Name = "JohnDoe", UserId = 1 },
		Nested = {
			Four = "ABC",
			Five = "DEF",
		},
	}

	local Serialized = ServerExports.Standalone.Write(Original)
	local Deserialized = ServerExports.Standalone.Read(Serialized)

	assert(Equals(Original, Deserialized), "Deserialized doesn't match original")
end)

RunClosure("Disconnect & Queue", function()
	local Expect = 1
	local Events = {
		"ReliableServer",
		"UnreliableServer",
		"ManyReliableSync",
		"ManyReliableAsync",
		"ManyUnreliableSync",
		"ManyUnreliableAsync",
	}

	for _, Event in Events do
		local Outgoing = ServerExports[Event]
		local Incoming = ClientExports[Event]

		local NeverRecieve: never
		Incoming.On(function(Value: never)
			NeverRecieve = Value
		end)()

		local Recieve: typeof(Expect)
		local RecieveDisconnect = Incoming.On(function(Value: typeof(Expect))
			Recieve = Value
		end)

		Outgoing.FireAll(Expect)

		task.wait(0.5)

		if Recieve ~= Expect then
			error(`Failed queue test on {Event}, expected "{Expect}", got "{Recieve}"`)
		end

		if NeverRecieve ~= nil then
			error(`Failed disconnect test on {Event}, disconnected listener still recieving.`)
		end

		RecieveDisconnect()
	end
end)

local Element = { Static = 0, Dynamic = buffer.create(64) }

FireAndExpect(
	"Dynamic Array Data Integrity",
	ServerExports.DynamicArray,
	ClientExports.DynamicArray,
	table.create(12, Element)
)
FireAndExpect(
	"Dynamic Map Data Integrity",
	ServerExports.DynamicMap,
	ClientExports.DynamicMap,
	table.create(64, Element)
)

RunClosure("CLI compile prompt", function()
	pcall(function()
		fs.removeDir("../Network")
	end)

	local Result: process.ExecResult
	local Thread = task.spawn(function()
		Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE }, { cwd = "../src/CLI" })
	end)

	if coroutine.status(Thread) ~= "suspended" then
		error(Result and Result.stderr or "CLI didn't prompt")
	end

	task.cancel(Thread)
end)

RunClosure("CLI compile --yes", function()
	local Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE, "--", "--yes" }, { cwd = "../src/CLI" })
	assert(Result.ok, Result.stderr)
end)

RunClosure("ServerByteLimit rejects invalid values", function()
	for _, Limit in { "0", "1.5" } do
		local SourceParser = Parser.new()
		local Success = pcall(function()
			SourceParser:Parse(`option ServerByteLimit = {Limit}`)
		end)

		if Success then
			ErrorPrint(`Expected ServerByteLimit = {Limit} to fail.`)
		end
	end
end)

local MergeStruct: Server.MergeStruct = {
	Data = 1,
	Field = 0,
	Float16Field = 0,
	Enum = "A",
	Nested = {
		Guh = 1,
		Array = table.create(10, 0),
	},
	AnotherNested = {
		Value = 1,
	},
	Map = {
		[{ 0 }] = 0,
	},
	Struct = {
		Data = 0,
		Array = { 0 },
		Nested = {
			Value = "hi",
		},
	},
}

FireAndPollExpect("Poll Reliable Client", ClientExports.ClientPollEvent, ServerExports.ClientPollEvent, MergeStruct)
FireAndPollExpect("Poll Reliable Server", ServerExports.ServerPollEvent, ClientExports.ServerPollEvent, MergeStruct)
FireAndPollExpect(
	"Poll Unreliable Client",
	ClientExports.ClientUnreliablePollEvent,
	ServerExports.ClientUnreliablePollEvent,
	MergeStruct
)
FireAndPollExpect(
	"Poll Unreliable Server",
	ServerExports.ServerUnreliablePollEvent,
	ClientExports.ServerUnreliablePollEvent,
	MergeStruct
)
FireAndPollExpect(
	"Poll Empty Reliable Client",
	ClientExports.ClientEmptyPollEvent,
	ServerExports.ClientEmptyPollEvent,
	nil
)
FireAndPollExpect(
	"Poll Empty Reliable Server",
	ServerExports.ServerEmptyPollEvent,
	ClientExports.ServerEmptyPollEvent,
	nil
)
FireAndPollExpect(
	"Poll Empty Unreliable Client",
	ClientExports.ClientEmptyUnreliablePollEvent,
	ServerExports.ClientEmptyUnreliablePollEvent,
	nil
)
FireAndPollExpect(
	"Poll Empty Unreliable Server",
	ServerExports.ServerEmptyUnreliablePollEvent,
	ClientExports.ServerEmptyUnreliablePollEvent,
	nil
)

RunClosure("Queue up and poll", function()
	local Expect = 10
	local Results = {
		Client = {},
		Server = {},
	}

	for _ = 1, Expect do
		ClientExports.ClientPollEvent.Fire(MergeStruct)
		ServerExports.ServerPollEvent.FireAll(MergeStruct)
	end

	task.wait(1 / 30)

	for Index, Value in ClientExports.ServerPollEvent.Iter() do
		table.insert(Results.Client, Value)
	end

	for Index, Player, Value in ServerExports.ClientPollEvent.Iter() do
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to be Player, got {Player} instead.`)
		end

		table.insert(Results.Server, Value)
	end

	for _, Context in Results do
		if #Context ~= Expect then
			ErrorPrint(`Expected to poll {Expect} events, got {#Results.Client} instead`)
		end

		for _, Result in Context do
			if not Equals(Result, MergeStruct) then
				Fail("Closure", Expect, Result)
			end
		end
	end
end)

RunClosure("Ranges should be enforced", function()
	do
		local UpperSuccess = pcall(function()
			ClientExports.NegativeRange.Write(11)
		end)

		local LowerSuccess = pcall(function()
			ClientExports.NegativeRange.Write(-6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected integer range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			ClientExports.DecimalRange.Write(10.6)
		end)

		local LowerSuccess = pcall(function()
			ClientExports.DecimalRange.Write(-5.6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected decimal range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			ClientExports.UnboundUpper.Write(2 ^ 53 + 1)
		end)

		local LowerSuccess = pcall(function()
			ClientExports.UnboundUpper.Write(-1)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected unbound upper range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			ClientExports.UnboundLower.Write(1)
		end)

		local LowerSuccess = pcall(function()
			ClientExports.UnboundLower.Write(-(2 ^ 53 + 1))
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected unbound upper range to be enforced.")
		end
	end

	ClientExports.ExactRange.Write(0)

	ClientExports.DecimalRange.Write(-5.5)
	ClientExports.DecimalRange.Write(10)

	ClientExports.NegativeRange.Write(-5)
	ClientExports.NegativeRange.Write(10)

	ClientExports.UnboundUpper.Write(0)
	ClientExports.UnboundUpper.Write(16777216)

	ClientExports.UnboundLower.Write(-16777216)
	ClientExports.UnboundLower.Write(0)
end)

RunClosure("Multi Dimensional Array", function()
	local Array = { { { 1, 2, 3, 4, 5, 6 } } }
	local Serialized = ClientExports.MultiDimensionalArray.Write(Array)
	local Deserialized = ClientExports.MultiDimensionalArray.Read(Serialized)

	if not Equals(Array, Deserialized) then
		ErrorPrint(`Expected: {Format(Array)}, got: {Format(Deserialized)} instead`)
	end
end)

do
	local foo: Client.Issue33_Foo = "One"
	local map: Client.Issue33_Map<number> = { [foo] = 0 }
	local enum: Client.Issue33_Enum<number> = { Tag = "Variant", field = foo }
	local struct: Client.Issue33_Struct<number> = { field = foo }

	FireAndExpectTuple(
		"Generics containing a unit enum value",
		ServerExports.Issue33.Event,
		ClientExports.Issue33.Event,
		map,
		enum,
		struct
	)
end

RunClosure("Export buffer trimming", function()
	local Buffer = ClientExports.Byte.Write(0)
	if buffer.len(Buffer) ~= 1 then
		ErrorPrint(`Expected buffer to be trimmed to 1 byte`)
	end
end)

do
	local enum: Client.Indexers_TestEnums = "b b"
	local flags: Client.Indexers_TestFlags = { ["a a"] = true }
	local struct: Client.Indexers_TestStruct = {
		["z z"] = 0,
		["1 1"] = 1,
		["2 2"] = 2,
		["3 3"] = 3,
	}
	local tagged: Client.Indexers_TestTaggedEnums = {
		Type = "c c",
		Test = 1,
	}

	FireAndExpectTuple(
		"Indexers",
		ServerExports.Indexers.TestEvent,
		ClientExports.Indexers.TestEvent,
		struct,
		flags,
		enum,
		tagged
	)
end

RunClosure("Buffer (Default, Fixed, Bounded)", function()
	local ExactBuffer = buffer.create(9)
	local BoundedBuffer = buffer.create(256)

	-- write some random bytes
	for offset = 0, 8, 4 do
		buffer.writeu8(ExactBuffer, offset, math.random(0, 2 ^ 30))
	end

	for offset = 0, 255, 4 do
		buffer.writeu8(BoundedBuffer, offset, math.random(0, 2 ^ 30))
	end

	-- test serdes
	do
		local Serialised = ClientExports.Buffer.Write(BoundedBuffer)
		local Deserialised = ClientExports.Buffer.Read(Serialised)
		assert(Equals(BoundedBuffer, Deserialised), `Default buffer serdes failed`)
	end

	do
		local Serialised = ClientExports.ExactBuffer.Write(ExactBuffer)
		local Deserialised = ClientExports.ExactBuffer.Read(Serialised)
		assert(Equals(ExactBuffer, Deserialised), `Fixed buffer serdes failed`)
	end

	do
		local Serialised = ClientExports.BoundedBuffer.Write(BoundedBuffer)
		local Deserialised = ClientExports.BoundedBuffer.Read(Serialised)
		assert(Equals(BoundedBuffer, Deserialised), `Bounded buffer serdes failed`)
	end
end)

PrettyPrint("green", `All tests passed successfully!`)

process.exit(0)
