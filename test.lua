local ToggleRunner = {}
ToggleRunner.__index = ToggleRunner

function ToggleRunner.New(Config)
	Config = Config or {}

	local Self = setmetatable({}, ToggleRunner)

	Self.Services = Config.Services or rawget(_G, "Services")
	Self.RunService = (Self.Services and Self.Services.RunService) or nil

	Self.Fluent = Config.Fluent or rawget(_G, "Fluent")
	Self.Options = Config.Options or (Self.Fluent and Self.Fluent.Options) or {}

	Self.RootResolver = Config.RootResolver or function(Name)
		return rawget(_G, Name)
	end

	Self.Entries = {} -- Flag -> {Thread, Conn, Opt, Callable, Mode, Threshold, PassState}
	Self.Hooked = false

	return Self
end

function ToggleRunner:StopAll()
	for Flag, Entry in pairs(self.Entries) do
		if Entry.Conn then
			pcall(function() Entry.Conn:Disconnect() end)
		end
		if Entry.Thread then
			pcall(function() task.cancel(Entry.Thread) end)
		end
		self.Entries[Flag] = nil
	end
end

function ToggleRunner:_HookFluentUnloadOnce()
	if self.Hooked then return end

	local Fluent = self.Fluent or rawget(_G, "Fluent")
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

function ToggleRunner:_StopFlag(Flag)
	local Entry = self.Entries[Flag]
	if not Entry then return end

	if Entry.Conn then
		pcall(function() Entry.Conn:Disconnect() end)
	end
	if Entry.Thread then
		pcall(function() task.cancel(Entry.Thread) end)
	end

	self.Entries[Flag] = nil
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

	local function Dispatch()
		task.spawn(function()
			if PassState then
				pcall(Entry.Callable, true)
			else
				pcall(Entry.Callable)
			end
		end)
	end

	if Mode == "spawn" then
		Entry.Thread = task.spawn(function()
			while self.Entries[Flag] and Entry.Opt.Value do
				Dispatch()
				if Threshold > 0 then
					task.wait(Threshold)
				else
					task.wait()
				end
			end
		end)
		return
	end

	if not self.RunService then
		warn("[ToggleRunner] Services.RunService is missing; falling back to 'spawn' mode.")
		return self:_StartLoop(Flag, OptObj, Callable, "spawn", Threshold, PassState)
	end

	if Mode == "Heartbeat" then
		local Acc = 0
		Entry.Conn = self.RunService.Heartbeat:Connect(function(Dt)
			if not self.Entries[Flag] or not Entry.Opt.Value then return end
			Acc = Acc + Dt
			if Acc >= Threshold then
				Acc = (Threshold > 0) and (Acc - Threshold) or 0
				Dispatch()
			end
		end)
		return
	end

	if Mode == "RenderStepped" then
		local Acc = 0
		Entry.Conn = self.RunService.RenderStepped:Connect(function(Dt)
			if not self.Entries[Flag] or not Entry.Opt.Value then return end
			Acc = Acc + Dt
			if Acc >= Threshold then
				Acc = (Threshold > 0) and (Acc - Threshold) or 0
				Dispatch()
			end
		end)
		return
	end
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

function ToggleRunner:BindToggle(Opt, Flag, Func, Opts)
	Opts = Opts or {}
	local Mode = Opts.mode or "spawn"
	local Threshold = tonumber(Opts.threshold) or 0
	local PassState = Opts.passState == true

	self:_HookFluentUnloadOnce()

	if Mode == "Call" then
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
					if PassState then pcall(OnCallable, true) else pcall(OnCallable) end
				end
			else
				if OffCallable then
					if PassState then pcall(OffCallable, false) else pcall(OffCallable) end
				elseif OnCallable and PassState then
					pcall(OnCallable, false)
				end
			end
		end)

		if Opt.Value and OnCallable then
			if PassState then pcall(OnCallable, true) else pcall(OnCallable) end
		elseif (not Opt.Value) and OffCallable then
			if PassState then pcall(OffCallable, false) else pcall(OffCallable) end
		end

		return Opt
	end

	local Callable = self:_ToCallable(Func)
	if not Callable then return Opt end

	Opt:OnChanged(function(State)
		if State then
			self:_StartLoop(Flag, Opt, Callable, Mode, Threshold, PassState)
		else
			self:_StopFlag(Flag)
		end
	end)

	if Opt.Value then
		self:_StartLoop(Flag, Opt, Callable, Mode, Threshold, PassState)
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
