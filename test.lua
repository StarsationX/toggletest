local ToggleRunner = {}
ToggleRunner.__index = ToggleRunner

local function GetEnv()
	if typeof(getgenv) == "function" then
		local Success, Env = pcall(getgenv)

		if Success and type(Env) == "table" then
			return Env
		end
	end

	return _G
end

local function GetGameRef()
	local GameRef = rawget(_G, "game") or game

	if typeof(cloneref) == "function" then
		local Success, ClonedGame = pcall(cloneref, GameRef)

		if Success and ClonedGame then
			return ClonedGame
		end
	end

	return GameRef
end

local function GetSharedValue(Name)
	local SharedTable = rawget(_G, "shared")

	if type(SharedTable) == "table" then
		return rawget(SharedTable, Name)
	end

	return nil
end

local function Traceback(Error)
	if debug and type(debug.traceback) == "function" then
		return debug.traceback(tostring(Error), 2)
	end

	return tostring(Error)
end

local function NormalizeModeName(Mode)
	if Mode == "TaskSpawn" or Mode == "task.spawn" or Mode == "Spawn" then
		return "spawn"
	end

	if Mode == "Render" or Mode == "Renderstep" then
		return "RenderStepped"
	end

	if Mode == "Heart" then
		return "Heartbeat"
	end

	if Mode == "Step" then
		return "Stepped"
	end

	if Mode == "Once" or Mode == "call" then
		return "Call"
	end

	return Mode
end

local function ResolveServices(Config)
	local Env = GetEnv()

	local Services =
		(Config and Config.Services)
		or rawget(Env, "Services")
		or rawget(_G, "Services")
		or GetSharedValue("Services")

	if type(Services) ~= "table" then
		Services = {}
	end

	local RunService =
		Services.RunService
		or (Config and Config.RunService)
		or rawget(Env, "RunService")
		or rawget(_G, "RunService")
		or GetSharedValue("RunService")

	if not RunService and not (Config and Config.DisableAutoServices) then
		local GameRef = GetGameRef()

		if GameRef and type(GameRef.GetService) == "function" then
			local Success, Result = pcall(GameRef.GetService, GameRef, "RunService")

			if Success and Result then
				RunService = Result
				Services.RunService = Result
			end
		end
	end

	return Services, RunService
end

local function ResolveFluent(Config)
	local Env = GetEnv()

	local Fluent =
		(Config and Config.Fluent)
		or rawget(Env, "Fluent")
		or rawget(_G, "Fluent")
		or GetSharedValue("Fluent")

	local Options =
		(Config and Config.Options)
		or (Fluent and Fluent.Options)
		or rawget(Env, "Options")
		or GetSharedValue("Options")
		or {}

	return Fluent, Options
end

local function SafeDisconnect(Object)
	if Object and type(Object.Disconnect) == "function" then
		pcall(function()
			Object:Disconnect()
		end)
	end
end

local function SafeCancel(Thread)
	if Thread then
		pcall(function()
			task.cancel(Thread)
		end)
	end
end

function ToggleRunner.New(Config)
	Config = Config or {}

	local Self = setmetatable({}, ToggleRunner)

	Self.Services, Self.RunService = ResolveServices(Config)
	Self.Fluent, Self.Options = ResolveFluent(Config)

	Self.ErrorMode = Config.ErrorMode or "silent"
	Self.ErrorCallback = Config.ErrorCallback
	Self.AllowConcurrent = Config.AllowConcurrent == true

	Self.RootResolver = Config.RootResolver or function(Name)
		local Env = GetEnv()
		return rawget(Env, Name) or rawget(_G, Name) or GetSharedValue(Name)
	end

	Self.Entries = {}
	Self.Cleaners = {}
	Self.Hooked = false
	Self.Destroyed = false

	return Self
end

function ToggleRunner:_HandleError(Flag, ErrorText)
	if self.ErrorCallback then
		pcall(self.ErrorCallback, Flag, ErrorText)
	end

	if self.ErrorMode == "warn" then
		warn(("[ToggleRunner][%s]\n%s"):format(tostring(Flag), tostring(ErrorText)))
	elseif self.ErrorMode == "throw" then
		error(("[ToggleRunner][%s]\n%s"):format(tostring(Flag), tostring(ErrorText)), 0)
	end
end

function ToggleRunner:SetErrorMode(Mode)
	self.ErrorMode = Mode or "silent"
end

function ToggleRunner:SetAllowConcurrent(State)
	self.AllowConcurrent = State == true
end

function ToggleRunner:_AddCleaner(Cleaner)
	if Cleaner then
		self.Cleaners[#self.Cleaners + 1] = Cleaner
	end

	return Cleaner
end

function ToggleRunner:_HookFluentUnloadOnce()
	if self.Hooked or self.Destroyed then
		return
	end

	local Fluent = self.Fluent

	if type(Fluent) ~= "table" then
		return
	end

	local UnloadSignal = rawget(Fluent, "Unloaded") or rawget(Fluent, "_unloaded") or rawget(Fluent, "Destroyed")

	if typeof(UnloadSignal) == "RBXScriptSignal" then
		local Connection = UnloadSignal:Connect(function()
			self:StopAll()
		end)

		self:_AddCleaner(function()
			SafeDisconnect(Connection)
		end)

		self.Hooked = true
	end

	for _, MethodName in ipairs({ "Unload", "Destroy" }) do
		local Method = rawget(Fluent, MethodName)
		local WrappedKey = "__ToggleRunnerWrapped_" .. MethodName

		if type(Method) == "function" and not rawget(Fluent, WrappedKey) then
			rawset(Fluent, WrappedKey, true)

			rawset(Fluent, MethodName, function(...)
				self:StopAll()
				return Method(...)
			end)

			self.Hooked = true
		end
	end
end

function ToggleRunner:_CleanupEntry(Entry)
	if not Entry then
		return
	end

	Entry.Stopped = true
	Entry.Pending = false
	Entry.Running = false

	if Entry.Connection then
		SafeDisconnect(Entry.Connection)
	end

	if Entry.Connections then
		for _, Connection in ipairs(Entry.Connections) do
			SafeDisconnect(Connection)
		end
	end

	if Entry.Thread then
		SafeCancel(Entry.Thread)
	end

	if Entry.Threads then
		for _, Thread in ipairs(Entry.Threads) do
			SafeCancel(Thread)
		end
	end

	Entry.Connection = nil
	Entry.Connections = nil
	Entry.Thread = nil
	Entry.Threads = nil
end

function ToggleRunner:StopAll()
	for Flag, Entry in pairs(self.Entries) do
		self:_CleanupEntry(Entry)
		self.Entries[Flag] = nil
	end
end

function ToggleRunner:StopFlag(Flag)
	local Entry = self.Entries[Flag]

	if not Entry then
		return false
	end

	self:_CleanupEntry(Entry)
	self.Entries[Flag] = nil

	return true
end

function ToggleRunner:_StopFlag(Flag)
	return self:StopFlag(Flag)
end

function ToggleRunner:GetEntry(Flag)
	return self.Entries[Flag]
end

function ToggleRunner:IsRunning(Flag)
	local Entry = self.Entries[Flag]

	return Entry ~= nil and Entry.Stopped ~= true
end

function ToggleRunner:IsBusy(Flag)
	local Entry = self.Entries[Flag]

	if not Entry then
		return false
	end

	return Entry.Running == true or Entry.Pending == true
end

function ToggleRunner:_WrapPath(Path)
	if type(Path) ~= "string" then
		return nil
	end

	local TableName, Separator, FunctionName = Path:match("^([%w_]+)([:%.])([%w_]+)$")

	if not TableName then
		return nil
	end

	local Root = self.RootResolver(TableName)

	if type(Root) ~= "table" then
		return nil
	end

	local Function = Root[FunctionName]

	if type(Function) ~= "function" then
		return nil
	end

	if Separator == ":" then
		return function(...)
			return Function(Root, ...)
		end
	end

	return function(...)
		return Function(...)
	end
end

function ToggleRunner:_ToCallable(Value)
	if type(Value) == "function" then
		return Value
	end

	if type(Value) == "string" then
		return self:_WrapPath(Value)
	end

	return nil
end

function ToggleRunner:_Dispatch(Flag, Entry, Callable, PassState, StateValue)
	if self.Destroyed then
		return false
	end

	if Entry and Entry.Running and not Entry.AllowConcurrent then
		return false
	end

	if Entry then
		Entry.Running = true
	end

	local Success, Result = xpcall(function()
		if PassState then
			return Callable(StateValue)
		end

		return Callable()
	end, Traceback)

	if Entry then
		Entry.Running = false
	end

	if not Success then
		self:_HandleError(Flag, Result)
	end

	return Success, Result
end

function ToggleRunner:_NormalizeModes(Mode)
	if type(Mode) == "table" then
		local Result = {}

		for _, ModeName in ipairs(Mode) do
			if type(ModeName) == "string" then
				Result[#Result + 1] = NormalizeModeName(ModeName)
			end
		end

		if #Result == 0 then
			return { "spawn" }
		end

		return Result
	end

	if type(Mode) == "string" then
		return { NormalizeModeName(Mode) }
	end

	return { "spawn" }
end

function ToggleRunner:_IsModeSupported(Mode)
	Mode = NormalizeModeName(Mode)

	if Mode == "spawn" or Mode == "Call" then
		return true
	end

	if not self.RunService then
		return false
	end

	if Mode == "Heartbeat" then
		return typeof(self.RunService.Heartbeat) == "RBXScriptSignal"
	end

	if Mode == "RenderStepped" then
		return typeof(self.RunService.RenderStepped) == "RBXScriptSignal"
	end

	if Mode == "Stepped" then
		return typeof(self.RunService.Stepped) == "RBXScriptSignal"
	end

	return false
end

function ToggleRunner:_SelectMode(Mode)
	local Modes = self:_NormalizeModes(Mode)

	for _, ModeName in ipairs(Modes) do
		if self:_IsModeSupported(ModeName) then
			return ModeName
		end
	end

	return "spawn"
end

function ToggleRunner:_ResolveThreshold(Value)
	if type(Value) == "function" then
		local Success, Result = pcall(Value)

		if Success then
			return math.max(tonumber(Result) or 0, 0)
		end

		return 0
	end

	return math.max(tonumber(Value) or 0, 0)
end

function ToggleRunner:SetThreshold(Flag, Threshold)
	local Entry = self.Entries[Flag]

	if not Entry then
		return false
	end

	Entry.Threshold = Threshold

	return true
end

function ToggleRunner:_CreateEntry(Flag, OptObj, Callable, Mode, Threshold, PassState, AllowConcurrent)
	self:_StopFlag(Flag)

	local Entry = {
		Flag = Flag,
		Opt = OptObj,
		Callable = Callable,
		Mode = Mode,
		Threshold = Threshold,
		PassState = PassState == true,
		AllowConcurrent = AllowConcurrent == true or self.AllowConcurrent == true,
		Running = false,
		Pending = false,
		Stopped = false,
		Connections = {},
		Threads = {}
	}

	self.Entries[Flag] = Entry

	return Entry
end

function ToggleRunner:_DispatchTick(Flag, Entry)
	if not Entry or Entry.Stopped then
		return
	end

	if self.Entries[Flag] ~= Entry then
		return
	end

	if Entry.Running and not Entry.AllowConcurrent then
		return
	end

	if Entry.Pending and not Entry.AllowConcurrent then
		return
	end

	Entry.Pending = true

	task.spawn(function()
		Entry.Pending = false

		if self.Entries[Flag] ~= Entry or Entry.Stopped then
			return
		end

		if Entry.Running and not Entry.AllowConcurrent then
			return
		end

		self:_Dispatch(Flag, Entry, Entry.Callable, Entry.PassState, true)
	end)
end

function ToggleRunner:_StartSpawnLoop(Flag, Entry)
	local Thread = task.spawn(function()
		while self.Entries[Flag] == Entry and not Entry.Stopped and Entry.Opt.Value do
			self:_DispatchTick(Flag, Entry)

			local Threshold = self:_ResolveThreshold(Entry.Threshold)

			if Threshold > 0 then
				task.wait(Threshold)
			else
				task.wait()
			end
		end
	end)

	Entry.Threads[#Entry.Threads + 1] = Thread
end

function ToggleRunner:_StartSignalLoop(Flag, Entry, Signal, UseSecondDelta)
	local Accumulator = 0

	local Connection = Signal:Connect(function(FirstDelta, SecondDelta)
		if self.Entries[Flag] ~= Entry or Entry.Stopped or not Entry.Opt.Value then
			return
		end

		local DeltaTime = UseSecondDelta and SecondDelta or FirstDelta
		local Threshold = self:_ResolveThreshold(Entry.Threshold)

		if Threshold <= 0 then
			self:_DispatchTick(Flag, Entry)
			return
		end

		Accumulator = Accumulator + (tonumber(DeltaTime) or 0)

		if Accumulator >= Threshold then
			Accumulator = Accumulator % Threshold
			self:_DispatchTick(Flag, Entry)
		end
	end)

	Entry.Connections[#Entry.Connections + 1] = Connection
end

function ToggleRunner:_StartMode(Flag, Entry, Mode)
	Mode = NormalizeModeName(Mode)

	if Mode == "spawn" then
		self:_StartSpawnLoop(Flag, Entry)
		return true
	end

	if not self.RunService then
		return false
	end

	if Mode == "Heartbeat" and self:_IsModeSupported("Heartbeat") then
		self:_StartSignalLoop(Flag, Entry, self.RunService.Heartbeat, false)
		return true
	end

	if Mode == "RenderStepped" and self:_IsModeSupported("RenderStepped") then
		self:_StartSignalLoop(Flag, Entry, self.RunService.RenderStepped, false)
		return true
	end

	if Mode == "Stepped" and self:_IsModeSupported("Stepped") then
		self:_StartSignalLoop(Flag, Entry, self.RunService.Stepped, true)
		return true
	end

	return false
end

function ToggleRunner:_StartLoop(Flag, OptObj, Callable, Mode, Threshold, PassState, AllowConcurrent)
	if self.Destroyed then
		return nil
	end

	local Entry = self:_CreateEntry(Flag, OptObj, Callable, Mode, Threshold, PassState, AllowConcurrent)
	local Modes = self:_NormalizeModes(Mode)
	local Started = false

	for _, ModeName in ipairs(Modes) do
		if ModeName ~= "Call" then
			if self:_StartMode(Flag, Entry, ModeName) then
				Started = true
			end
		end
	end

	if not Started then
		self:_StartSpawnLoop(Flag, Entry)
	end

	return Entry
end

function ToggleRunner:_BindCallToggle(Opt, Flag, Func, PassState, UserOnChanged, FireInitial)
	local OnCallable
	local OffCallable

	if type(Func) == "table" then
		OnCallable = self:_ToCallable(Func.on or Func.On)
		OffCallable = self:_ToCallable(Func.off or Func.Off)
	else
		OnCallable = self:_ToCallable(Func)
	end

	Opt:OnChanged(function(State)
		if State then
			if OnCallable then
				self:_Dispatch(Flag, nil, OnCallable, PassState, true)
			end
		else
			if OffCallable then
				self:_Dispatch(Flag, nil, OffCallable, PassState, false)
			elseif OnCallable and PassState then
				self:_Dispatch(Flag, nil, OnCallable, true, false)
			end
		end

		if type(UserOnChanged) == "function" then
			pcall(UserOnChanged, State, Opt, Flag)
		end
	end)

	if Opt.Value then
		if OnCallable then
			self:_Dispatch(Flag, nil, OnCallable, PassState, true)
		end
	elseif OffCallable then
		self:_Dispatch(Flag, nil, OffCallable, PassState, false)
	end

	if FireInitial and type(UserOnChanged) == "function" then
		pcall(UserOnChanged, Opt.Value, Opt, Flag)
	end

	return Opt
end

function ToggleRunner:BindToggle(Opt, Flag, Func, Opts)
	Opts = Opts or {}

	if not Opt or type(Opt.OnChanged) ~= "function" then
		error("ToggleRunner:BindToggle(opt, ...) expects an option object with :OnChanged().")
	end

	local Mode = Opts.mode or Opts.Mode or "spawn"
	local Threshold = Opts.threshold or Opts.Threshold
	local PassState = Opts.passState == true or Opts.PassState == true
	local AllowConcurrent = Opts.allowConcurrent == true or Opts.AllowConcurrent == true
	local UserOnChanged = Opts.onChanged or Opts.OnChanged
	local FireInitial = Opts.onChangedInitial ~= false and Opts.OnChangedInitial ~= false

	self:_HookFluentUnloadOnce()

	local Modes = self:_NormalizeModes(Mode)
	local SelectedMode = self:_SelectMode(Mode)

	if #Modes == 1 and SelectedMode == "Call" then
		return self:_BindCallToggle(Opt, Flag, Func, PassState, UserOnChanged, FireInitial)
	end

	local Callable = self:_ToCallable(Func)

	Opt:OnChanged(function(State)
		if State and Callable then
			self:_StartLoop(Flag, Opt, Callable, Mode, Threshold, PassState, AllowConcurrent)
		else
			self:_StopFlag(Flag)
		end

		if type(UserOnChanged) == "function" then
			pcall(UserOnChanged, State, Opt, Flag)
		end
	end)

	if Opt.Value and Callable then
		self:_StartLoop(Flag, Opt, Callable, Mode, Threshold, PassState, AllowConcurrent)
	end

	if FireInitial and type(UserOnChanged) == "function" then
		pcall(UserOnChanged, Opt.Value, Opt, Flag)
	end

	return Opt
end

function ToggleRunner:AddToggleFunc(TabObj, Flag, Func, Props, Opts)
	if not TabObj or type(TabObj.AddToggle) ~= "function" then
		error("ToggleRunner:AddToggleFunc(tabObj, ...) expects a Fluent tab object with :AddToggle().")
	end

	local Opt = TabObj:AddToggle(Flag, Props or {})

	if type(self.Options) == "table" then
		self.Options[Flag] = Opt
	end

	return self:BindToggle(Opt, Flag, Func, Opts)
end

function ToggleRunner:Destroy()
	if self.Destroyed then
		return
	end

	self.Destroyed = true
	self:StopAll()

	for _, Cleaner in ipairs(self.Cleaners) do
		pcall(Cleaner)
	end

	table.clear(self.Cleaners)
	table.clear(self.Entries)
end

return ToggleRunner
