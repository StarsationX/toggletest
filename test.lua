local ToggleRunner = {}
ToggleRunner.__index = ToggleRunner

local function GetEnv()
	if typeof(getgenv) == "function" then
		local ok, env = pcall(getgenv)
		if ok and type(env) == "table" then
			return env
		end
	end
	return _G
end

local function GetGameRef()
	local g = rawget(_G, "game") or game
	if typeof(cloneref) == "function" then
		local ok, cg = pcall(cloneref, g)
		if ok and cg then
			return cg
		end
	end
	return g
end

local function Traceback(err)
	if debug and type(debug.traceback) == "function" then
		return debug.traceback(tostring(err), 2)
	end
	return tostring(err)
end

local function ResolveServices(Config)
	local Env = GetEnv()

	local Services =
		(Config and Config.Services)
		or rawget(Env, "Services")
		or rawget(_G, "Services")
		or (rawget(_G, "shared") and rawget(shared, "Services"))

	if type(Services) ~= "table" then
		Services = {}
	end

	local RunService =
		Services.RunService
		or (Config and Config.RunService)
		or rawget(Env, "RunService")
		or rawget(_G, "RunService")
		or (rawget(_G, "shared") and rawget(shared, "RunService"))

	if not RunService and not (Config and Config.DisableAutoServices) then
		local g = GetGameRef()
		if g and type(g.GetService) == "function" then
			local ok, rs = pcall(g.GetService, g, "RunService")
			if ok and rs then
				RunService = rs
				Services.RunService = rs
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
		or (rawget(_G, "shared") and rawget(shared, "Fluent"))

	local Options =
		(Config and Config.Options)
		or (Fluent and Fluent.Options)
		or rawget(Env, "Options")
		or {}

	return Fluent, Options
end

function ToggleRunner.New(Config)
	Config = Config or {}

	local Self = setmetatable({}, ToggleRunner)

	Self.Services, Self.RunService = ResolveServices(Config)
	Self.Fluent, Self.Options = ResolveFluent(Config)

	Self.ErrorMode = Config.ErrorMode or "silent"
	Self.ErrorCallback = Config.ErrorCallback

	Self.RootResolver = Config.RootResolver or function(Name)
		local Env = GetEnv()
		return rawget(Env, Name) or rawget(_G, Name)
	end

	Self.Entries = {}
	Self.Hooked = false

	return Self
end

function ToggleRunner:_HandleError(Flag, Trace)
	if self.ErrorCallback then
		pcall(self.ErrorCallback, Flag, Trace)
	end

	if self.ErrorMode == "warn" then
		warn(("[ToggleRunner][%s]\n%s"):format(tostring(Flag), tostring(Trace)))
	elseif self.ErrorMode == "throw" then
		error(("[ToggleRunner][%s]\n%s"):format(tostring(Flag), tostring(Trace)), 0)
	end
end

function ToggleRunner:SetErrorMode(Mode)
	self.ErrorMode = Mode or "silent"
end

function ToggleRunner:_HookFluentUnloadOnce()
	if self.Hooked then return end

	local Fluent = self.Fluent
	if typeof(Fluent) ~= "table" then return end

	local UnloadSignal = rawget(Fluent, "Unloaded") or rawget(Fluent, "_unloaded") or rawget(Fluent, "Destroyed")
	if typeof(UnloadSignal) == "RBXScriptSignal" then
		UnloadSignal:Connect(function()
			self:StopAll()
		end)
		self.Hooked = true
	end

	for _, Method in ipairs({ "Unload", "Destroy" }) do
		local Fn = rawget(Fluent, Method)
		local WrapKey = "__ToggleRunnerWrapped_" .. Method
		if type(Fn) == "function" and not rawget(Fluent, WrapKey) then
			rawset(Fluent, WrapKey, true)
			rawset(Fluent, Method, function(...)
				self:StopAll()
				return Fn(...)
			end)
			self.Hooked = true
		end
	end
end

function ToggleRunner:StopAll()
	for Flag, Entry in pairs(self.Entries) do
		if Entry.Conn then
			pcall(function() Entry.Conn:Disconnect() end)
		end
		if Entry.Conns then
			for _, C in ipairs(Entry.Conns) do
				pcall(function() C:Disconnect() end)
			end
		end
		if Entry.Thread then
			pcall(function() task.cancel(Entry.Thread) end)
		end
		if Entry.Threads then
			for _, T in ipairs(Entry.Threads) do
				pcall(function() task.cancel(T) end)
			end
		end
		self.Entries[Flag] = nil
	end
end

function ToggleRunner:_StopFlag(Flag)
	local Entry = self.Entries[Flag]
	if not Entry then return end

	if Entry.Conn then
		pcall(function() Entry.Conn:Disconnect() end)
	end
	if Entry.Conns then
		for _, C in ipairs(Entry.Conns) do
			pcall(function() C:Disconnect() end)
		end
	end
	if Entry.Thread then
		pcall(function() task.cancel(Entry.Thread) end)
	end
	if Entry.Threads then
		for _, T in ipairs(Entry.Threads) do
			pcall(function() task.cancel(T) end)
		end
	end

	self.Entries[Flag] = nil
end

function ToggleRunner:_WrapPath(Path)
	local TableName, Sep, FuncName = Path:match("^([%w_]+)([:%.])([%w_]+)$")
	if not TableName then return nil end

	local Root = self.RootResolver(TableName)
	if type(Root) ~= "table" then return nil end

	local Fn = Root[FuncName]
	if type(Fn) ~= "function" then return nil end

	if Sep == ":" then
		return function(...)
			return Fn(Root, ...)
		end
	end

	return function(...)
		return Fn(...)
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

function ToggleRunner:_Dispatch(Flag, Callable, PassState, StateValue)
	local ok, res = xpcall(function()
		if PassState then
			return Callable(StateValue)
		else
			return Callable()
		end
	end, Traceback)

	if not ok then
		self:_HandleError(Flag, res)
	end
end

function ToggleRunner:_NormalizeModes(Mode)
	if type(Mode) == "table" then
		local Out = {}
		for _, M in ipairs(Mode) do
			if type(M) == "string" then
				Out[#Out+1] = M
			end
		end
		if #Out == 0 then
			return { "spawn" }
		end
		return Out
	end
	if type(Mode) == "string" then
		return { Mode }
	end
	return { "spawn" }
end

function ToggleRunner:_IsModeSupported(M)
	if M == "spawn" then
		return true
	end
	if M == "Call" then
		return true
	end
	if not self.RunService then
		return false
	end
	if M == "Heartbeat" then
		return typeof(self.RunService.Heartbeat) == "RBXScriptSignal"
	end
	if M == "RenderStepped" then
		return typeof(self.RunService.RenderStepped) == "RBXScriptSignal"
	end
	return false
end

function ToggleRunner:_SelectMode(Mode)
	local Modes = self:_NormalizeModes(Mode)

	for _, M in ipairs(Modes) do
		if M == "spawn" or M == "Call" then
			return M
		end

		if self:_IsModeSupported(M) then
			return M
		end
	end

	return "spawn"
end

function ToggleRunner:_StartLoop(Flag, OptObj, Callable, Mode, Threshold, PassState)
	self:_StopFlag(Flag)

	local Entry = {
		Opt = OptObj,
		Callable = Callable,
		Mode = Mode,
		Threshold = Threshold,
		PassState = PassState,
	}
	self.Entries[Flag] = Entry

	local function DispatchTick()
		task.spawn(function()
			self:_Dispatch(Flag, Callable, PassState, true)
		end)
	end

	local function StartSpawn()
		if Entry.Thread then return end
		Entry.Thread = task.spawn(function()
			while self.Entries[Flag] and Entry.Opt.Value do
				DispatchTick()
				if Threshold > 0 then
					task.wait(Threshold)
				else
					task.wait()
				end
			end
		end)
	end

	local function StartHeartbeat()
		if not self.RunService then return end
		local Acc = 0
		local Conn = self.RunService.Heartbeat:Connect(function(Dt)
			if not self.Entries[Flag] or not Entry.Opt.Value then return end
			Acc = Acc + Dt
			if Acc >= Threshold then
				Acc = (Threshold > 0) and (Acc - Threshold) or 0
				DispatchTick()
			end
		end)
		Entry.Conns = Entry.Conns or {}
		table.insert(Entry.Conns, Conn)
	end

	local function StartRenderStepped()
		if not self.RunService then return end
		local Acc = 0
		local Conn = self.RunService.RenderStepped:Connect(function(Dt)
			if not self.Entries[Flag] or not Entry.Opt.Value then return end
			Acc = Acc + Dt
			if Acc >= Threshold then
				Acc = (Threshold > 0) and (Acc - Threshold) or 0
				DispatchTick()
			end
		end)
		Entry.Conns = Entry.Conns or {}
		table.insert(Entry.Conns, Conn)
	end

	local Modes = self:_NormalizeModes(Mode)

	if #Modes > 1 then
		local Started = false

		for _, M in ipairs(Modes) do
			if M == "Call" then
				continue
			end

			if M == "spawn" then
				StartSpawn()
				Started = true
			elseif M == "Heartbeat" then
				if self:_IsModeSupported("Heartbeat") then
					StartHeartbeat()
					Started = true
				end
			elseif M == "RenderStepped" then
				if self:_IsModeSupported("RenderStepped") then
					StartRenderStepped()
					Started = true
				end
			end
		end

		if not Started then
			StartSpawn()
		end

		return
	end

	local SelectedMode = self:_SelectMode(Mode)
	Entry.Mode = SelectedMode

	if SelectedMode == "spawn" then
		StartSpawn()
		return
	end

	if not self.RunService then
		warn("[ToggleRunner] RunService missing; falling back to 'spawn' mode.")
		StartSpawn()
		return
	end

	if SelectedMode == "Heartbeat" then
		StartHeartbeat()
		return
	end

	if SelectedMode == "RenderStepped" then
		StartRenderStepped()
		return
	end
end

function ToggleRunner:BindToggle(Opt, Flag, Func, Opts)
	Opts = Opts or {}

	local Mode = Opts.mode or "spawn"
	local Threshold = tonumber(Opts.threshold) or 0
	local PassState = Opts.passState == true

	local UserOnChanged = Opts.onChanged
	local FireInitial = Opts.onChangedInitial ~= false

	local function CallUser(State)
		if type(UserOnChanged) == "function" then
			pcall(UserOnChanged, State, Opt, Flag)
		end
	end

	self:_HookFluentUnloadOnce()

	local Modes = self:_NormalizeModes(Mode)
	local SelectedMode = self:_SelectMode(Mode)

	if #Modes == 1 and SelectedMode == "Call" then
		local OnCallable, OffCallable
		if type(Func) == "table" then
			OnCallable = self:_ToCallable(Func.on)
			OffCallable = self:_ToCallable(Func.off)
		else
			OnCallable = self:_ToCallable(Func)
		end

		Opt:OnChanged(function(State)
			if State then
				if OnCallable then
					self:_Dispatch(Flag, OnCallable, PassState, true)
				end
			else
				if OffCallable then
					self:_Dispatch(Flag, OffCallable, PassState, false)
				elseif OnCallable and PassState then
					self:_Dispatch(Flag, OnCallable, true, false)
				end
			end
			CallUser(State)
		end)

		if Opt.Value and OnCallable then
			self:_Dispatch(Flag, OnCallable, PassState, true)
		elseif (not Opt.Value) and OffCallable then
			self:_Dispatch(Flag, OffCallable, PassState, false)
		end

		if FireInitial then
			CallUser(Opt.Value)
		end

		return Opt
	end

	local Callable = self:_ToCallable(Func)
	if not Callable then
		if FireInitial then
			CallUser(Opt.Value)
		end
		return Opt
	end

	Opt:OnChanged(function(State)
		if State then
			self:_StartLoop(Flag, Opt, Callable, Mode, Threshold, PassState)
		else
			self:_StopFlag(Flag)
		end
		CallUser(State)
	end)

	if Opt.Value then
		self:_StartLoop(Flag, Opt, Callable, Mode, Threshold, PassState)
	end

	if FireInitial then
		CallUser(Opt.Value)
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

return ToggleRunner
