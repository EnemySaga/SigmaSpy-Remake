--[[

	Taking my methods 💖💖
	I love a paster and a skid, puts disgust in my face

]]

local Hook = {
	OriginalNamecall = nil,
	OriginalIndex = nil,
	PreviousFunctions = {},
	DefaultConfig = {
		FunctionPatches = true
	},

	--// Executor capability probes (cached per-VM)
	--// nil  = not probed yet
	--// true = function is available and works
	--// false = function missing OR hangs (treated as unavailable)
	GetRawMetaSupported = nil,
	HookMetaMethodSupported = nil,
}

type table = {
	[any]: any
}

type MetaFunc = (Instance, ...any) -> ...any
type UnkFunc = (...any) -> ...any

--// Modules
local Modules
local Process
local Configuration
local Config
local Communication

local ExeENV = getfenv(1)

--// Local executor globals (resolved once for safety)
local RawGetRawMetatable = getrawmetatable
local RawHookMetaMethod = hookmetamethod
local RawHookFunction = hookfunction
local RawCloneFunction = clonefunction
local RawNewCClosure = newcclosure
local RawGetActors = getactors
local RawRunOnActor = run_on_actor
local RawCreateCommChannel = create_comm_channel
local RawGetActorStates = getactorstates
local RawGetDeletedActors = getdeletedactors
local RawOnActorStateCreated = on_actor_state_created

--// Checks if a value is a callable function
local function IsFunction(Value: any): boolean
	return typeof(Value) == "function"
end

--[[
	Runs `Callback` exactly once, but guarded against hangs.

	On some executors `getrawmetatable` (and rarely `hookmetamethod`) deadlock
	instead of erroring. A plain `pcall` does NOT protect against a hang because
	a deadlock in a C function blocks the calling thread forever. To avoid that,
	we run the probe in a detached coroutine/thread and watch it from the main
	thread with a timeout. If it doesn't finish in time, we treat the function as
	unavailable and abandon the probe thread.

	Note: the abandoned probe thread may still be stuck internally, but it can no
	longer block Sigma Spy's init or actor setup.

	@param Callback  The probe to run. Should return a truthy value on success.
	@param Timeout   Max seconds to wait (default 0.2).
	@return boolean  true if the probe finished and returned truthy, false otherwise.
]]
local function ProbeWithTimeout(Callback: () -> any, Timeout: number?): boolean
	Timeout = Timeout or 0.2

	local Done = false
	local Success = false

	local ProbeThread = coroutine.create(function()
		local Ok, Result = pcall(Callback)
		Done = true
		Success = Ok and Result ~= nil and Result ~= false
	end)

	--// Kick off the probe
	coroutine.resume(ProbeThread)

	--// Watchdog: yield up to `Timeout` seconds waiting for completion
	local Deadline = tick() + Timeout
	while not Done and tick() < Deadline do
		task.wait()
	end

	--// If it finished, return its result; otherwise consider it hung/unsupported
	return Done and Success
end

--// Lazy executor probes. Each runs at most once per VM (actors are separate VMs).
function Hook:ProbeGetRawMetatable(): boolean
	if self.GetRawMetaSupported ~= nil then
		return self.GetRawMetaSupported
	end

	--// Must exist as a function first
	if not IsFunction(RawGetRawMetatable) then
		self.GetRawMetaSupported = false
		return false
	end

	--// Probe on a throwaway table (cheaper & safer than `game`)
	self.GetRawMetaSupported = ProbeWithTimeout(function()
		local TestMt = setmetatable({}, {
			__index = function()
				return false
			end,
			__metatable = "Locked!",
		})

		local Fetched = RawGetRawMetatable(TestMt)
		assert(type(Fetched) == "table", "getrawmetatable did not return a table")
		assert(Fetched.__index() == false, "getrawmetatable returned the wrong metatable")
		return true
	end)

	return self.GetRawMetaSupported
end

function Hook:ProbeHookMetaMethod(): boolean
	if self.HookMetaMethodSupported ~= nil then
		return self.HookMetaMethodSupported
	end

	if not IsFunction(RawHookMetaMethod) then
		self.HookMetaMethodSupported = false
		return false
	end

	self.HookMetaMethodSupported = ProbeWithTimeout(function()
		--// Mirror of Cobalt's hookmetamethod test (ExecutorSupport.luau:416-432)
		local Object = setmetatable({}, {
			__index = newcclosure(function()
				return false
			end),
			__metatable = "Locked!",
		})

		local Reference = RawHookMetaMethod(Object, "__index", function()
			return true
		end)

		assert(Object.test == true, "hookmetamethod did not change the return value")
		assert(Reference() == false, "hookmetamethod did not return the original")
		return true
	end)

	return self.HookMetaMethodSupported
end

--[[
	Safe wrapper around getrawmetatable.

	Returns the raw metatable of `Object`, or `nil` if:
	  - getrawmetatable is missing on this executor, or
	  - it was probed and found to hang/crash, or
	  - calling it errored.

	Callers MUST handle `nil` and fall through to another hook strategy
	(see Hook:HookMetaMethod).
]]
function Hook:SafeGetRawMetatable(Object: Instance): table?
	--// If not probed yet, probe now (cheap after first call due to caching)
	if not self:ProbeGetRawMetatable() then
		return nil
	end

	local Success, Metatable = pcall(RawGetRawMetatable, Object)
	if not Success or type(Metatable) ~= "table" then
		return nil
	end

	return Metatable
end

function Hook:Init(Data)
    Modules = Data.Modules

	Process = Modules.Process
	Communication = Modules.Communication or Communication
	Config = Modules.Config or Config
	Configuration = Modules.Configuration or Configuration
end

--// The callback is expected to return a nil value sometimes which should be ingored
local HookMiddle = newcclosure(function(OriginalFunc, Callback, AlwaysTable: boolean?, ...)
	--// Invoke callback and check for a reponce otherwise ignored
	local ReturnValues = Callback(...)
	if ReturnValues then
		--// Unpack
		if not AlwaysTable then
			return Process:Unpack(ReturnValues)
		end

		--// Return packed responce
		return ReturnValues
	end

	--// Return packed responce
	if AlwaysTable then
		return {OriginalFunc(...)}
	end

	--// Unpacked
	return OriginalFunc(...)
end)

local function Merge(Base: table, New: table)
	for Key, Value in next, New do
		Base[Key] = Value
	end
end

function Hook:Index(Object: Instance, Key: string)
	return Object[Key]
end

function Hook:PushConfig(Overwrites)
    Merge(self, Overwrites)
end

--// getrawmetatable mutation path (Cobalt Branch A: hookmetamethod broken, getrawmetatable works)
--// Only ever called after SafeGetRawMetatable returns non-nil.
function Hook:ReplaceMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local Metatable = self:SafeGetRawMetatable(Object)
	if not Metatable then return nil end

	local OriginalFunc = Metatable[Call]
	if not IsFunction(OriginalFunc) then return nil end

	--// clonefunction is optional; fall back to the direct function pointer
	if IsFunction(RawCloneFunction) then
		local Success, Cloned = pcall(RawCloneFunction, OriginalFunc)
		if Success and IsFunction(Cloned) then
			OriginalFunc = Cloned
		end
	end

	--// Replace the metamethod in the raw (unlocked) metatable
	setreadonly(Metatable, false)
	Metatable[Call] = newcclosure(function(...)
		return HookMiddle(OriginalFunc, Callback, false, ...)
	end)
	setreadonly(Metatable, true)

	return OriginalFunc
end

--// hookfunction wrapper. Returns the original function, or nil if hooking failed.
function Hook:HookFunction(Func: UnkFunc, Callback: UnkFunc)
	if not IsFunction(Func) then return nil end
	if not IsFunction(RawHookFunction) then return nil end

	local OriginalFunc
	local WrappedCallback = newcclosure(Callback)

	local Success, Result = pcall(function()
		OriginalFunc = RawHookFunction(Func, function(...)
			return HookMiddle(OriginalFunc, WrappedCallback, false, ...)
		end)
	end)

	if not Success then return nil end

	--// clonefunction the returned original so callers get a stable reference
	if IsFunction(RawCloneFunction) and IsFunction(OriginalFunc) then
		local Ok, Cloned = pcall(RawCloneFunction, OriginalFunc)
		if Ok and IsFunction(Cloned) then
			OriginalFunc = Cloned
		end
	end

	return OriginalFunc
end

--// hookfunction path: read the metamethod via getrawmetatable then hook it directly.
--// Only ever called after SafeGetRawMetatable returns non-nil.
function Hook:HookMetaCall(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local Metatable = self:SafeGetRawMetatable(Object)
	if not Metatable then return nil end

	local MethodFunc = Metatable[Call]
	if not IsFunction(MethodFunc) then return nil end

	local Unhooked
	Unhooked = self:HookFunction(MethodFunc, function(...)
		return HookMiddle(Unhooked, Callback, true, ...)
	end)
	return Unhooked
end

--[[
	HANG-FREE metamethod retrieval (ported from Cobalt, Utils/Hook/Luau.luau:47-75).

	Retrieves the real metamethod function WITHOUT calling getrawmetatable by
	provoking the metamethod to error and reading the caller frame via
	debug.info. This is the critical fallback when getrawmetatable deadlocks.

	@param Object  The instance to retrieve the metamethod for (usually `game`).
	@param Method  "__namecall" | "__index" | "__newindex"
	@return function?  The metamethod function, or nil if it could not be retrieved.
]]
function Hook:GetMetaMethodViaError(Object: Instance, Method: string): MetaFunc?
	local Trigger
	if Method == "__index" then
		Trigger = function()
			return Object[tostring(math.random())]
		end
	elseif Method == "__newindex" then
		Trigger = function()
			Object[tostring(math.random())] = true
		end
	elseif Method == "__namecall" then
		Trigger = function()
			Object:Mustard()
		end
	else
		return nil
	end

	--// The error handler runs INSIDE the metamethod's call frame, so
	--// debug.info(2, "f") returns the metamethod function itself.
	local _, Retrieved = xpcall(Trigger, function(_Err)
		return debug.info(2, "f")
	end)

	if IsFunction(Retrieved) then
		return Retrieved
	end
	return nil
end

--[[
	LAYERED metamethod hook (Cobalt fallback chain, adapted to Sigma Spy).

	Tries, in order:
	  1. oth.hook                 (fastest, present on some executors)
	  2. hookmetamethod           (standard path, if probed working)
	  3. getrawmetatable mutation (ReplaceMetaMethod, if getrawmetatable works)
	  4. xpcall + debug.info      (HANG-FREE retrieval, then hookfunction)
	  5. give up gracefully       (returns nil, caller logs a warning)

	Config.ReplaceMetaCallFunc forces path 3 to be preferred over path 2/4 when
	getrawmetatable works (preserves the original config semantics).
]]
function Hook:HookMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc?
	local Func = newcclosure(Callback)

	--// 1. OTH fast path (some executors expose `oth.hook`)
	if oth and IsFunction(oth.hook) then
		--// oth.hook needs the original method function. Resolve it hang-free
		--// via the xpcall trick first, then via getrawmetatable if supported.
		local MethodFunc = self:GetMetaMethodViaError(Object, Call)
		if not IsFunction(MethodFunc) and self:ProbeGetRawMetatable() then
			local Mt = self:SafeGetRawMetatable(Object)
			MethodFunc = Mt and Mt[Call] or nil
		end
		if IsFunction(MethodFunc) then
			local Success, Result = pcall(oth.hook, MethodFunc, Func)
			if Success then return Result end
		end
	end

	local GRMSupported = self:ProbeGetRawMetatable()

	--// Config-driven preference: mutate the rawmetatable directly
	if Config.ReplaceMetaCallFunc and GRMSupported then
		local Replaced = self:ReplaceMetaMethod(Object, Call, Callback)
		if Replaced then return Replaced end
	end

	--// 2. hookmetamethod (standard)
	if self:ProbeHookMetaMethod() then
		local Success, Result = pcall(function()
			return RawHookMetaMethod(Object, Call, Func)
		end)
		if Success and IsFunction(Result) then
			return Result
		end
	end

	--// 3. getrawmetatable mutation (if hookmetamethod is unavailable/broken)
	if GRMSupported then
		local Replaced = self:ReplaceMetaMethod(Object, Call, Callback)
		if Replaced then return Replaced end

		--// 3b. read via getrawmetatable, hook the function directly
		local MetaHooked = self:HookMetaCall(Object, Call, Callback)
		if MetaHooked then return MetaHooked end
	end

	--// 4. HANG-FREE retrieval via xpcall + debug.info, then hookfunction
	local Retrieved = self:GetMetaMethodViaError(Object, Call)
	if Retrieved then
		local Original
		Original = self:HookFunction(Retrieved, function(...)
			return HookMiddle(Original, Callback, false, ...)
		end)
		if Original then return Original end
	end

	--// 5. Nothing worked
	return nil
end

--// This includes a few patches for executor functions that result in detection
--// This isn't bulletproof since some functions like hookfunction I can't patch
--// By the way, thanks for copying this guys! Super appreciate the copycat
function Hook:PatchFunctions()
	--// Check if this function is disabled in the configuration
	if Config.NoFunctionPatching then return end

	local Patches = {
		--// Error detection patch
		--// hookfunction may still be detected depending on the executor
		[pcall] =  function(OldFunc, Func, ...)
			local Responce = {OldFunc(Func, ...)}
			local Success, Error = Responce[1], Responce[2]
			local IsC = iscclosure(Func)

			--// Patch c-closure error detection
			if Success == false and IsC then
				local NewError = Process:CleanCError(Error)
				Responce[2] = NewError
			end

			--// Stack-overflow detection patch
			if Success == false and not IsC and Error:find("C stack overflow") then
				local Tracetable = Error:split(":")
				local Caller, Line = Tracetable[1], Tracetable[2]
				local Count = Process:CountMatches(Error, Caller)

				if Count == 196 then
					Communication:ConsolePrint(`C stack overflow patched, count was {Count}`)
					Responce[2] = Error:gsub(`{Caller}:{Line}: `, Caller, 1)
				end
			end

			return Responce
		end,
		[getfenv] = function(OldFunc, Level: number, ...)
			Level = Level or 1

			--// Prevent catpure of executor's env
			if type(Level) == "number" then
				Level += 2
			end

			local Responce = {OldFunc(Level, ...)}
			local ENV = Responce[1]

			--// __tostring ENV detection patch
			if not checkcaller() and ENV == ExeENV then
				Communication:ConsolePrint("ENV escape patched")
				return OldFunc(999999, ...)
			end

			return Responce
		end
	}

	--// Hook each function
	for Func, CallBack in Patches do
		local Wrapped = newcclosure(CallBack)
		local OldFunc; OldFunc = self:HookFunction(Func, function(...)
			return Wrapped(OldFunc, ...)
		end)

		--// Cache previous function
		self.PreviousFunctions[Func] = OldFunc
	end
end

function Hook:GetOriginalFunc(Func)
	return self.PreviousFunctions[Func] or Func
end

function Hook:RunOnActors(Code: string, ChannelId: number)
	--// Gate: all three functions must exist (Cobalt pattern: init.luau:54-59)
	local HasGetActors = IsFunction(RawGetActors)
	local HasRunOnActor = IsFunction(RawRunOnActor)
	local HasCreateCommChannel = IsFunction(RawCreateCommChannel)

	if not (HasGetActors and HasRunOnActor and HasCreateCommChannel) then
		Communication:ConsolePrint("Actors disabled: executor does not support required functions")
		return
	end

	--// Prefer getactorstates / LuaStateProxy if available (Cobalt init.luau:242-247)
	--// This handles deleted actors / LuaStateProxy that getactors misses
	if IsFunction(RawGetActorStates) then
		for _, LuaStateProxy in RawGetActorStates() do
			if not LuaStateProxy.IsActorState then continue end
			pcall(function()
				LuaStateProxy:Execute(Code, ChannelId, LuaStateProxy:GetActors()[1])
			end)
		end
		return
	end

	--// Collect all actor instances (Cobalt init.luau:249-254)
	local Categories = { RawGetActors() }
	if IsFunction(RawGetDeletedActors) then
		table.insert(Categories, RawGetDeletedActors())
	end

	--// Hook each actor with retry + timeout (Cobalt init.luau:226-240)
	local function HookActor(TargetActor)
		local Hooked = false
		local Attempts = 0

		repeat
			Hooked = pcall(RawRunOnActor, TargetActor, Code, ChannelId)
			Attempts += 1
			task.wait(0.25)
		until Hooked or Attempts > 10

		if not Hooked then
			Communication:ConsolePrint(`Actor hook failed after {Attempts} attempts`)
		end
	end

	for _, Category in Categories do
		for _, TargetActor in next, Category do
			task.spawn(HookActor, TargetActor)
		end
	end

	--// Catch new actors at runtime (Cobalt init.luau:266-270)
	local function HandleInstance(Instance)
		if typeof(Instance) ~= "Instance" or not Instance:IsA("Actor") then
			return
		end
		task.spawn(HookActor, Instance)
	end

	if IsFunction(RawOnActorStateCreated) then
		RawOnActorStateCreated:Connect(HandleInstance)
	else
		game.DescendantAdded:Connect(HandleInstance)
	end
end

local function ProcessRemote(OriginalFunc, MetaMethod: string, self, Method: string, ...)
	return Process:ProcessRemote({
		Method = Method,
		OriginalFunc = OriginalFunc,
		MetaMethod = MetaMethod,
		TransferType = "Send",
		IsExploit = checkcaller()
	}, self, ...)
end

function Hook:HookRemoteTypeIndex(ClassName: string, FuncName: string)
	local Ok, Remote, Func = pcall(function()
		local Temp = Instance.new(ClassName)
		return Temp, Temp[FuncName]
	end)

	if not Ok or not Remote or not IsFunction(Func) then
		--// Prefab creation failed or method not found — skip this class
		return
	end

	--// Remotes will share the same functions
	--// 	For example FireServer will be identical
	--// Addionally, this is for __index calls.
	--// 	A __namecall hook will not detect this
	local OriginalFunc = self:HookFunction(Func, function(self, ...)
		--// Check if the Object is allowed
		if not Process:RemoteAllowed(self, "Send", FuncName) then return end

		--// Process the remote data
		return ProcessRemote(OriginalFunc, "__index", self, FuncName, ...)
	end)

	--// Destroy the temporary prefab so it doesn't linger orphaned
	pcall(function()
		Remote:Destroy()
	end)
end

function Hook:HookRemoteIndexes()
	local RemoteClassData = Process.RemoteClassData
	for ClassName, Data in RemoteClassData do
		local FuncName = Data.Send[1]
		self:HookRemoteTypeIndex(ClassName, FuncName)
	end
end

function Hook:BeginHooks()
	--// Hook Remote functions (prefab-based, safe with pcall)
	self:HookRemoteIndexes()

	--// Namecall hook (layered fallback: hookmetamethod → getrawmetatable → xpcall trick)
	local OriginalNameCall
	OriginalNameCall = self:HookMetaMethod(game, "__namecall", function(self, ...)
		local Method = getnamecallmethod()
		return ProcessRemote(OriginalNameCall, "__namecall", self, Method, ...)
	end)

	if OriginalNameCall then
		Merge(self, {
			OriginalNamecall = OriginalNameCall,
			--OriginalIndex = Oi
		})
	else
		--// No hook path succeeded — outgoing namecall logging will be limited.
		--// Receive hooks and prefab hooks still work.
		Communication:ConsolePrint("WARNING: Could not install __namecall hook.")
		Communication:ConsolePrint("Outgoing remote calls may not be fully logged.")
	end
end

function Hook:HookClientInvoke(Remote, Method, Callback)
	local Success, Function = pcall(function()
		return getcallbackvalue(Remote, Method)
	end)

	--// Some executors like Potassium will throw a error if the Callback value is nil
	if not Success then return end
	if not Function then return end
	
	--// Test hookfunction
	local HookSuccess = pcall(function()
		self:HookFunction(Function, Callback)
	end)
	if HookSuccess then return end

	--// Replace callback function otherwise
	Remote[Method] = function(...)
		return HookMiddle(Function, Callback, false, ...)
	end
end

function Hook:MultiConnect(Remotes)
	for _, Remote in next, Remotes do
		self:ConnectClientRecive(Remote)
	end
end

function Hook:ConnectClientRecive(Remote)
	--// Check if the Remote class is allowed for receiving
	local Allowed = Process:RemoteAllowed(Remote, "Receive")
	if not Allowed then return end

	--// Check if the Object has Remote class data
    local ClassData = Process:GetClassData(Remote)
    local IsRemoteFunction = ClassData.IsRemoteFunction
	local NoReciveHook = ClassData.NoReciveHook
    local Method = ClassData.Receive[1]

	--// Check if the Recive should be hooked
	if NoReciveHook then return end

	--// New callback function
	local function Callback(...)
        return Process:ProcessRemote({
            Method = Method,
            IsReceive = true,
            MetaMethod = "Connect",
			IsExploit = checkcaller()
        }, Remote, ...)
	end

	--// Connect remote
	if not IsRemoteFunction then
   		Remote[Method]:Connect(Callback)
	else -- Remote functions
		self:HookClientInvoke(Remote, Method, Callback)
	end
end

function Hook:BeginService(Libraries, ExtraData, ChannelId, ...)
	--// Librareis
	local ReturnSpoofs = Libraries.ReturnSpoofs
	local ProcessLib = Libraries.Process
	local Communication = Libraries.Communication
	local Generation = Libraries.Generation
	local Config = Libraries.Config

	--// Check for configuration overwrites
	ProcessLib:CheckConfig(Config)

	--// Init data
	local InitData = {
		Modules = {
			ReturnSpoofs = ReturnSpoofs,
			Generation = Generation,
			Communication = Communication,
			Process = ProcessLib,
			Config = Config,
			Hook = self
		},
		Services = setmetatable({}, {
			__index = function(self, Name: string): Instance
				local Service = game:GetService(Name)
				return cloneref(Service)
			end,
		})
	}

	--// Init libraries
	Communication:Init(InitData)
	ProcessLib:Init(InitData)

	--// Communication configuration
	local Channel, IsWrapped = Communication:GetCommChannel(ChannelId)
	Communication:SetChannel(Channel)
	Communication:AddTypeCallbacks({
		["RemoteData"] = function(Id: string, RemoteData)
			ProcessLib:SetRemoteData(Id, RemoteData)
		end,
		["AllRemoteData"] = function(Key: string, Value)
			ProcessLib:SetAllRemoteData(Key, Value)
		end,
		["UpdateSpoofs"] = function(Content: string)
			local Spoofs = loadstring(Content)()
			ProcessLib:SetNewReturnSpoofs(Spoofs)
		end,
		["BeginHooks"] = function(Config)
			if Config.PatchFunctions then
				self:PatchFunctions()
			end
			self:BeginHooks()
			Communication:ConsolePrint("Hooks loaded")
		end
	})
	
	--// Process configuration
	ProcessLib:SetChannel(Channel, IsWrapped)
	ProcessLib:SetExtraData(ExtraData)

	--// Hook configuration
	self:Init(InitData)

	if ExtraData and ExtraData.IsActor then
		Communication:ConsolePrint("Actor connected!")
	end
end

function Hook:LoadMetaHooks(ActorCode: string, ChannelId: number)
	--// Hook actors
	if not Configuration.NoActors then
		self:RunOnActors(ActorCode, ChannelId)
	end

	--// Hook current thread
	self:BeginService(Modules, nil, ChannelId) 
end

function Hook:LoadReceiveHooks()
	local NoReceiveHooking = Config.NoReceiveHooking
	local BlackListedServices = Config.BlackListedServices

	if NoReceiveHooking then return end

	--// Remote added
	game.DescendantAdded:Connect(function(Remote) -- TODO
		self:ConnectClientRecive(Remote)
	end)

	--// Collect remotes with nil parents
	self:MultiConnect(getnilinstances())

	--// Search for remotes
	for _, Service in next, game:GetChildren() do
		if table.find(BlackListedServices, Service.ClassName) then continue end
		self:MultiConnect(Service:GetDescendants())
	end
end

function Hook:LoadHooks(ActorCode: string, ChannelId: number)
	self:LoadMetaHooks(ActorCode, ChannelId)
	self:LoadReceiveHooks()
end

return Hook
