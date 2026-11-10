-- T2Coop: co-op for Trepang2 on top of Unreal's built-in networking.
-- Host:   T2C.host("/Game/Maps/HordeMode/Horde_Killhouse")
-- Client: T2C.join("1.2.3.4")
local VERSION = "0.2.1"
local function log(s) print("[T2Coop] " .. tostring(s) .. "\n") end

local PLAYER_CDO = "/Game/Blueprint/Player/PlayerBP.Default__PlayerBP_C"
local IP_DRIVER = "/Script/OnlineSubsystemUtils.IpNetDriver"

local S = {
    hosting = false,
    hostMap = nil,
    known = {},        -- remote PlayerControllers we already set up (by full name)
    spawnIndex = 0,
}
_G.T2C = S

---------------------------------------------------------------------------
-- Scheduler: everything periodic runs on the GAME thread.
-- Heartbeat = a hook on PlayerControllerBP's per-frame ReceiveTick. UE4SS's own
-- queues (LoopAsync/ExecuteInGameThread, LoopInGameThreadWithDelay) stopped
-- running on the host after we called game functions from them; hooks never did.
-- S.every(ms, fn): fn(dtMs) is called about every ms; return true to stop.
---------------------------------------------------------------------------
local TICK_MS = 30
local tasks = {}
function S.every(ms, fn) table.insert(tasks, { iv = ms, acc = ms, fn = fn }) end
local running = false
S.graceMs = 0       -- no tasks while a map loads (old world torn down) and briefly after
local function runTasks(dtMs)
    if running then return end   -- never re-enter (game calls made by a task can tick hooks)
    if S.loading then return end
    if S.graceMs > 0 then S.graceMs = S.graceMs - dtMs; return end
    running = true
    for i = #tasks, 1, -1 do
        local t = tasks[i]
        if t then
            t.acc = t.acc + dtMs
            if t.acc >= t.iv then
                local dt = t.acc
                t.acc = 0
                local ok, res = pcall(t.fn, dt)
                if not ok then
                    log("task error: " .. tostring(res))
                elseif res == true then
                    table.remove(tasks, i)
                end
            end
        end
    end
    running = false
end

local hb = { hooked = false, acc = 0, lastWall = 0 }
local function heartbeat(dtMs)
    hb.acc = hb.acc + dtMs
    hb.lastWall = os.time()
    if hb.acc >= TICK_MS then
        local d = hb.acc
        hb.acc = 0
        runTasks(d)
    end
end
local function hookHeartbeat()
    if hb.hooked then return end
    hb.hooked = pcall(function()
        RegisterHook("/Game/Blueprint/Player/PlayerControllerBP.PlayerControllerBP_C:ReceiveTick", function(self, dt)
            local pc = self:get()
            if pc:IsLocalController() then heartbeat(dt:get() * 1000) end
        end)
    end)
    if hb.hooked then log("heartbeat hooked") end
end
hookHeartbeat()
-- Fallback while there is no heartbeat (hook not placed yet, or the game is paused,
-- e.g. on the title screen, so the controller doesn't tick).
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(TICK_MS, function()
        if not hb.hooked then hookHeartbeat() end
        if os.time() - hb.lastWall >= 1 then runTasks(TICK_MS) end
    end)
end

local function valid(o) return o ~= nil and o:IsValid() end
local function engine() return FindFirstOf("GameEngine") end
local function world()
    local e = engine()
    if valid(e) and valid(e.GameViewport) then return e.GameViewport.World end
end

local function netDriver()
    local w = world()
    if valid(w) and valid(w.NetDriver) then return w.NetDriver end
end

local function isServer()
    return netDriver() ~= nil and S.hosting
end

local function forceIpDriver()
    local e = engine()
    if not valid(e) then return end
    e.NetDriverDefinitions:ForEach(function(_, el)
        local d = el:get()
        if d.DefName:ToString() == "GameNetDriver" then
            d.DriverClassName = FName(IP_DRIVER, EFindName.FNAME_Add)
            d.DriverClassNameFallback = FName(IP_DRIVER, EFindName.FNAME_Add)
        end
    end)
end

-- Spawned player pawns inherit AutoPossessPlayer=Player0 from the class default, so a pawn the
-- server spawns for a client grabs the HOST's controller. Placed level pawns read the same default
-- while the level loads, so we only switch it off after the level is up, and back on before the next load.
local function setAutoPossess(on)
    local cdo = StaticFindObject(PLAYER_CDO)
    if valid(cdo) then cdo.AutoPossessPlayer = on and 1 or 0 end
end

local function stopLoadingScreen()
    local gi = FindFirstOf("GameInstanceBP_C")
    if valid(gi) then
        pcall(function() gi:SetBootFlowFinished() end)
        pcall(function() gi:ForceStopLoadingScreen() end)
    end
end

-- The "press any key" loading screen blocks travel until dismissed; after we start a travel,
-- keep dismissing it for a few seconds (both the old and the new map show it).
local function keepClearingLoadingScreen(ms)
    local left = ms or 15000
    S.every(1000, function(dt)
        left = left - dt
        stopLoadingScreen()
        return left <= 0
    end)
end

local GS
local function openLevel(map, opts)
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    forceIpDriver()
    stopLoadingScreen()
    GS:OpenLevel(world(), FName(map, EFindName.FNAME_Add), true, opts or "")
    keepClearingLoadingScreen()
end

function S.host(map)
    S.hosting = true
    S.awaitHostLoad = true
    S.joined = false
    S.hostMap = map or "/Game/Maps/HordeMode/Horde_Killhouse"
    S.known = {}
    log("hosting " .. S.hostMap)
    openLevel(S.hostMap, "listen")
end

function S.join(ip)
    S.hosting = false
    S.joined = true
    forceIpDriver()
    stopLoadingScreen()
    local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pc = FindFirstOf("PlayerController")
    S.lastIP = ip or "127.0.0.1"
    S.rejoin = nil
    log("joining " .. S.lastIP)
    KSL:ExecuteConsoleCommand(world(), "open " .. S.lastIP, pc)
    keepClearingLoadingScreen(30000)
end

function S.leave()
    S.hosting = false
    S.joined = false
    openLevel("/Game/Maps/Menu/FrontEndMenuMap", "")
end

local function localPC()
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and pc:IsLocalController() then return pc end
    end
end

-- Server: give every remote player a pawn next to the host.
local function setupRemotePlayers()
    local host = localPC()
    if not valid(host) or not valid(host.Pawn) then return end
    local gm = FindFirstOf("GameModeBase")
    if not valid(gm) then return end
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() then
            local key = pc:GetFullName()
            if not valid(pc.Pawn) then
                gm:RestartPlayer(pc)
            end
            local pawn = pc.Pawn
            if valid(pawn) and not S.known[key] then
                S.known[key] = true
                S.spawnIndex = S.spawnIndex + 1
                local hl = host.Pawn:K2_GetActorLocation()
                local hr = host.Pawn:K2_GetActorRotation()
                local off = 120 * S.spawnIndex
                pawn:K2_SetActorLocation({ X = hl.X + off, Y = hl.Y, Z = hl.Z + 20 }, false, {}, true)
                pcall(function() pc:ClientSetRotation(hr, false) end)
                S.toClient(pc, "S", string.format("%.1f|%.1f|%.1f", hl.X + off, hl.Y, hl.Z + 20), string.format("%.1f", hr.Yaw))
                log("placed " .. pawn:GetFName():ToString() .. " for " .. pc:GetFName():ToString())
            end
        end
    end
end

-- ABasePlayer's native tick does Cast<APlayerController>(Controller)->PlayerCameraManager without
-- a null check. On a client the other player's pawn never has a controller, and our own pawn gets
-- one a moment after it spawns, so the tick crashes. Keep player pawn tick off until it's safe.
local BasePlayerClass
local parked = {}   -- pawn full name -> pawn with tick disabled

local function controllerReady(pawn)
    local c = pawn.Controller
    if not valid(c) then return false end
    local ok, cam = pcall(function() return c.PlayerCameraManager end)
    return ok and valid(cam)
end

local function isNetClient()
    local nd = netDriver()
    return nd ~= nil and not S.hosting
end

local function guardPlayerPawn(actor)
    BasePlayerClass = BasePlayerClass or StaticFindObject("/Script/CPPFPS.BasePlayer")
    if not valid(BasePlayerClass) or not actor:IsA(BasePlayerClass) then return end
    if not S.joined then return end
    if controllerReady(actor) then return end
    actor:SetActorTickEnabled(false)
    parked[actor:GetFullName()] = actor
    log("parked tick of " .. actor:GetFName():ToString())
end

pcall(function()
    RegisterBeginPlayPostHook(function(ActorParam)
        local ok, err = pcall(function()
            local a = ActorParam.get and ActorParam:get() or ActorParam
            if valid(a) then guardPlayerPawn(a) end
        end)
        if not ok then log("beginplay hook error: " .. tostring(err)) end
    end)
end)

local function unparkReady()
    for k, pawn in pairs(parked) do
        if not valid(pawn) then
            parked[k] = nil
        elseif controllerReady(pawn) then
            pawn:SetActorTickEnabled(true)
            parked[k] = nil
            log("unparked " .. pawn:GetFName():ToString())
        end
    end
end

---------------------------------------------------------------------------
-- Actor helpers
---------------------------------------------------------------------------
local classCache = {}
local function classOf(path)
    local c = classCache[path]
    if not valid(c) then
        c = StaticFindObject(path)
        classCache[path] = c
    end
    return c
end

-- All live actors of a class, including subclasses.
function S.allOf(path)
    local cls = classOf(path)
    local w = world()
    if not valid(cls) or not valid(w) then return {} end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local out = {}
    GS:GetAllActorsOfClass(w, cls, out)
    local res = {}
    for _, a in ipairs(out) do
        local o = a.get and a:get() or a
        if valid(o) then table.insert(res, o) end
    end
    return res
end

local function dist2(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

-- Nearest non-player character to a point (actors have different names on host and client,
-- so we match them by position).
local function nearestNPC(pos, maxDist)
    local best, bestD = nil, (maxDist or 300) ^ 2
    local playerCls = classOf("/Script/CPPFPS.BasePlayer")
    for _, c in ipairs(S.allOf("/Script/CPPFPS.BaseCharacter")) do
        -- living ones only: corpses lie all over the arena and are often closer
        if not c:IsA(playerCls) and not c.bIsDead then
            local d = dist2(c:K2_GetActorLocation(), pos)
            if d < bestD then best, bestD = c, d end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Messaging over built-in engine RPCs.
--   client -> server: PlayerController:ServerChangeName("T2C|...")
--   server -> client: PlayerController:ClientMessage("T2C|...", "T2C", 0)
---------------------------------------------------------------------------
local PREFIX = "T2C|"
local handlers = { server = {}, client = {} }

local function split(s)
    local t = {}
    for part in (s .. "|"):gmatch("([^|]*)|") do table.insert(t, part) end
    return t
end

-- Hooks never send or handle messages directly (calling into the engine from inside a hook
-- crashed/hung the host); they only queue. pumpMessages() runs in the game thread.
local outbox = {}   -- { to = "server" | "clients", msg = string }
local inbox = {}    -- { side = "server" | "client", pc = PlayerController, text = string }

local function pack(kind, ...)
    local parts = { kind }
    for _, v in ipairs({ ... }) do table.insert(parts, tostring(v)) end
    return PREFIX .. table.concat(parts, "|")
end

function S.toServer(kind, ...) table.insert(outbox, { to = "server", msg = pack(kind, ...) }) end
function S.toClients(kind, ...) table.insert(outbox, { to = "clients", msg = pack(kind, ...) }) end
function S.toClient(pc, kind, ...) table.insert(outbox, { to = "pc", pc = pc, msg = pack(kind, ...) }) end

local function dispatch(side, pc, text)
    if type(text) ~= "string" or text:sub(1, #PREFIX) ~= PREFIX then return end
    local parts = split(text:sub(#PREFIX + 1))
    local kind = table.remove(parts, 1)
    local h = handlers[side][kind]
    if h then
        local ok, err = pcall(h, pc, parts)
        if not ok then log(side .. " handler " .. kind .. " error: " .. tostring(err)) end
    end
end

local T2CName
local function pumpMessages()
    if #inbox > 0 then
        local batch = inbox; inbox = {}
        for _, m in ipairs(batch) do dispatch(m.side, m.pc, m.text) end
    end
    if #outbox > 0 then
        local batch = outbox; outbox = {}
        local me = localPC()
        T2CName = T2CName or FName("T2C", EFindName.FNAME_Add)
        local remotes = {}
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() then table.insert(remotes, pc) end
        end
        for _, m in ipairs(batch) do
            if m.to == "server" then
                if valid(me) then pcall(function() me:ServerChangeName(m.msg) end) end
            elseif m.to == "pc" then
                if valid(m.pc) then pcall(function() m.pc:ClientMessage(m.msg, T2CName, 0.0) end) end
            else
                for _, pc in ipairs(remotes) do pcall(function() pc:ClientMessage(m.msg, T2CName, 0.0) end) end
            end
        end
    end
end

local function strParam(p)
    local v = p.get and p:get() or p
    if type(v) == "userdata" and v.ToString then v = v:ToString() end
    return v
end

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ServerChangeName", function(self, name)
        if not S.hosting then return end
        table.insert(inbox, { side = "server", pc = self:get(), text = strParam(name) })
    end)
    RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(self, msg)
        if S.hosting then return end
        table.insert(inbox, { side = "client", pc = self:get(), text = strParam(msg) })
    end)
end)

local function vec(p, i) return { X = tonumber(p[i]), Y = tonumber(p[i + 1]), Z = tonumber(p[i + 2]) } end
local function fmtVec(v) return string.format("%.1f|%.1f|%.1f", v.X, v.Y, v.Z) end

---------------------------------------------------------------------------
-- Damage: the client's projectiles hit the client's copies of enemies;
-- we forward each hit to the host, which applies it to the real enemy.
---------------------------------------------------------------------------
local DamageTypeCls
pcall(function()
    RegisterHook("/Script/CPPFPS.BaseWeapon:OnSpawnedProjectileDamagedOther",
        function(self, Damage, DamagedActor, bHeadshot, bKilled)
            if S.hosting or not S.joined then return end
            table.insert(S.pendingHits, { target = DamagedActor:get(), dmg = Damage:get(), head = bHeadshot:get() })
        end)
end)

handlers.server["D"] = function(pc, p)
    local pos, dmg, head = vec(p, 1), tonumber(p[4]), p[5] == "1"
    local npc = nearestNPC(pos, 400)
    if not valid(npc) then log("hit: no npc near " .. table.concat(p, ",")) return end
    if npc.bIsDead then return end
    DamageTypeCls = DamageTypeCls or classOf("/Script/Engine.DamageType")
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local causer = valid(pc.Pawn) and pc.Pawn or nil
    GS:ApplyDamage(npc, dmg, pc, causer, DamageTypeCls)
    S.stats.hits = S.stats.hits + 1
end

S.stats = { hits = 0, deaths = 0 }
S.pendingDeaths = {}
S.pendingHits = {}

local function flushDeaths()
    if #S.pendingDeaths == 0 then return end
    local batch = S.pendingDeaths; S.pendingDeaths = {}
    local playerCls = classOf("/Script/CPPFPS.BasePlayer")
    for _, c in ipairs(batch) do
        if valid(c) and not c:IsA(playerCls) then
            S.stats.deaths = S.stats.deaths + 1
            S.toClients("K", fmtVec(c:K2_GetActorLocation()))
        end
    end
end

local function flushHits()
    if #S.pendingHits == 0 then return end
    local batch = S.pendingHits; S.pendingHits = {}
    for _, h in ipairs(batch) do
        if valid(h.target) then
            S.toServer("D", fmtVec(h.target:K2_GetActorLocation()), string.format("%.2f", h.dmg), h.head and 1 or 0)
        end
    end
end

-- Fast game-thread pump for network messages.
S.every(30, function()
    flushHits()
    flushDeaths()
    pumpMessages()
end)

---------------------------------------------------------------------------
-- Deaths: host tells clients which enemy died so their copy ragdolls too.
---------------------------------------------------------------------------
-- No hook on BaseCharacter:Die: calling damage/Die from our own code then re-entered the hook
-- and UE4SS stopped running both mods. The host polls bIsDead instead.
local aliveNPCs = {}
S.every(250, function()
    if not isServer() then return end
    local playerCls = classOf("/Script/CPPFPS.BasePlayer")
    local seen = {}
    for _, c in ipairs(S.allOf("/Script/CPPFPS.BaseCharacter")) do
        if not c:IsA(playerCls) then
            local key = c:GetFullName()
            seen[key] = true
            if c.bIsDead then
                if aliveNPCs[key] then
                    aliveNPCs[key] = nil
                    table.insert(S.pendingDeaths, c)
                end
            else
                aliveNPCs[key] = true
            end
        end
    end
    for k in pairs(aliveNPCs) do if not seen[k] then aliveNPCs[k] = nil end end
end)

-- Client: kill our copy of that enemy (visually).
S.killQueue = {}
handlers.client["K"] = function(_, p)
    table.insert(S.killQueue, vec(p, 1))
end
S.every(60, function()
    if #S.killQueue == 0 then return end
    local batch = S.killQueue; S.killQueue = {}
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    DamageTypeCls = DamageTypeCls or classOf("/Script/Engine.DamageType")
    for _, pos in ipairs(batch) do
        local npc = nearestNPC(pos, 400)
        if valid(npc) and not npc.bIsDead then
            -- Never call Die() from Lua on a client copy: it stopped UE4SS (both mods) every time.
            -- Damage alone doesn't kill a network copy, so: drain health, mark dead, ragdoll.
            pcall(function() GS:ApplyDamage(npc, 100000, nil, nil, DamageTypeCls) end)
            npc.bIsDead = true
            pcall(function() npc:StartLiveRagdoll(1.0, FName("pelvis", EFindName.FNAME_Add), { X = 0, Y = 0, Z = 0 }, false, true) end)
        end
    end
end)

-- Map load bookkeeping.
RegisterLoadMapPreHook(function()
    S.loading = true
    setAutoPossess(true)
    S.known = {}
    S.spawnIndex = 0
    if S.client then S.client = { pawn = nil, puppet = nil } end
    if S.me then S.me.down, S.me.max = false, nil end
    S.downed = {}
end)

local loadedAt = 0
RegisterLoadMapPostHook(function()
    S.loading = false
    S.graceMs = 1500
    loadedAt = os.time()
    S.awaitHostLoad = false
    hookHeartbeat()
end)

-- Client: PlayerControllerBP keeps its pawn in MyPlayer, which is set in ReceivePossess.
-- Possess only runs on the server, so on a client movement input went nowhere.
---------------------------------------------------------------------------
-- CLIENT: play with our OWN local pawn.
-- The pawn the server gives us (and its weapon) arrive as network copies, and the game's
-- single-player C++ refuses to fire weapons that aren't local (Role=Authority). So the client
-- spawns its own PlayerBP, hides the server copy ("puppet"), and switches the controller to
-- the local pawn with ClientRestart (what the engine itself does on possession).
-- The host moves the puppet from our pose messages, so the host sees us.
---------------------------------------------------------------------------
local PLAYER_CLASS = "/Game/Blueprint/Player/PlayerBP.PlayerBP_C"
S.client = { pawn = nil, puppet = nil }

local function same(a, b) return valid(a) and valid(b) and a:GetFullName() == b:GetFullName() end

local function fixClientController()
    if not netDriver() then return end
    local pc = localPC()
    if not valid(pc) or pc.Role ~= 2 then return end
    local c = S.client
    pcall(function()
        if not valid(pc.MyGameInstance) then pc.MyGameInstance = FindFirstOf("GameInstanceBP_C") end
    end)

    if valid(c.pawn) then
        -- replication may point the controller back at the puppet; take it back
        if not same(pc.Pawn, c.pawn) then
            if valid(pc.Pawn) and not same(pc.Pawn, c.puppet) then
                c.puppet = pc.Pawn
                c.puppet:SetActorHiddenInGame(true)
                c.puppet:SetActorEnableCollision(false)
            end
            pcall(function() pc:ClientRestart(c.pawn) end)
            log("client: re-took local pawn")
        end
        if not same(pc.MyPlayer, c.pawn) then pc.MyPlayer = c.pawn end
        return
    end

    local puppet = pc.Pawn
    if not valid(puppet) or not c.spawn then return end   -- wait for the host's spawn point
    local l, yaw = c.spawn.loc, c.spawn.yaw
    puppet:SetActorHiddenInGame(true)
    puppet:SetActorEnableCollision(false)
    -- Deferred spawn: give the pawn its controller AND PlayerState before BeginPlay.
    -- APawn::IsPlayerControlled() is "has a PlayerState"; without it PlayerBP sets itself and its
    -- weapon up as a third-person NPC body (gun not attached to the first-person arms).
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = l, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local a = GS:BeginDeferredActorSpawnFromClass(world(), classOf(PLAYER_CLASS), xf, 1, nil)
    if not valid(a) then log("client: local pawn spawn failed") return end
    a.Controller = pc
    a.PlayerState = pc.PlayerState
    pc.MyPlayer = a
    GS:FinishSpawningActor(a, xf)
    a:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, true)
    c.pawn, c.puppet = a, puppet
    pc:ClientRestart(a)
    pc.MyPlayer = a
    -- Our pawn made its own HUD in BeginPlay; the one made for the server's pawn would stay on
    -- screen with stale prompts ("GRAB HOSTAGE") and ammo, so drop every other player HUD.
    local mine = valid(a.PlayerHud) and a.PlayerHud or nil
    for _, h in ipairs(FindAllOf("PlayerHUD2_C") or {}) do
        if valid(h) then
            if mine and h:GetFullName() ~= mine:GetFullName() then
                pcall(function() h:RemoveFromParent() end)
            elseif not mine then
                h.Player = a; a.PlayerHud = h; mine = h
            end
        end
    end
    log("client: playing with local pawn " .. a:GetFName():ToString() .. ", puppet " .. puppet:GetFName():ToString())
end

handlers.client["S"] = function(_, p)
    local c = S.client
    c.spawn = { loc = vec(p, 1), yaw = tonumber(p[4]) }
    log(string.format("client: spawn point %.0f %.0f %.0f", c.spawn.loc.X, c.spawn.loc.Y, c.spawn.loc.Z))
    if valid(c.pawn) then
        c.pawn:K2_SetActorLocationAndRotation(c.spawn.loc, { Pitch = 0, Yaw = c.spawn.yaw, Roll = 0 }, false, {}, true)
    end
end

-- Other players' pawns carry PlayerBP post-process components (death, low health, slow-mo...)
-- that nobody updates on this machine; one of them turned the whole screen grey.
local PPCls
S.every(1000, function()
    if not netDriver() then return end
    PPCls = PPCls or classOf("/Script/Engine.PostProcessComponent")
    local pc = localPC()
    local mine = valid(pc) and valid(pc.Pawn) and pc.Pawn:GetFullName() or ""
    for _, p in ipairs(S.allOf("/Script/CPPFPS.BasePlayer")) do
        -- players must never be offered as hostages (the hidden puppet walks right behind us)
        if p.bCanBeTakenHostage then p.bCanBeTakenHostage = false end
        if p:GetFullName() ~= mine then
            for _, comp in ipairs(p:K2_GetComponentsByClass(PPCls)) do
                local o = comp.get and comp:get() or comp
                if valid(o) and o.bEnabled then o.bEnabled = false end
            end

        end
    end
end)

---------------------------------------------------------------------------
-- Horde HUD (wave / enemies left / money / timer) lives in SideMissionStatusUI, which only the
-- host's game mode fills. Host mirrors its texts to clients; client shows its own copy.
---------------------------------------------------------------------------
local HUD_CLASS = "/Game/Maps/HordeMode/SideMissionStatusUI.SideMissionStatusUI_C"
local hudState = { last = "", since = 0 }
local function txt(tb)
    local ok, v = pcall(function() return tb:GetText():ToString() end)
    return ok and v or ""
end
S.every(500, function(dt)
    if not isServer() then return end
    local ui = FindFirstOf("SideMissionStatusUI_C")
    if not valid(ui) then return end
    local msg = table.concat({ txt(ui.WaveNum), txt(ui.WaveNumText), txt(ui.EnemiesTextBox), txt(ui.MoneyText), txt(ui.ElapsedTimer) }, "~")
    msg = msg:gsub("|", "/")
    hudState.since = hudState.since + dt
    if msg ~= hudState.last or hudState.since >= 3000 then
        hudState.last, hudState.since = msg, 0
        S.toClients("U", msg)
    end
end)

handlers.client["U"] = function(_, p)
    local parts = {}
    for x in ((p[1] or "") .. "~"):gmatch("([^~]*)~") do table.insert(parts, x) end
    local c = S.client
    if not valid(c.hud) then
        local cls = classOf(HUD_CLASS)
        if not valid(cls) and LoadAsset then pcall(function() cls = LoadAsset(HUD_CLASS) end) end
        if not valid(cls) then return end
        local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        c.hud = WBL:Create(world(), cls, localPC())
        if not valid(c.hud) then return end
        c.hud:AddToViewport(0)
        log("client: horde HUD created")
    end
    c.hudParts = parts
end

-- The widget's own Tick keeps rewriting some fields from this machine's (empty) game state,
-- so re-apply the host's values often.
S.every(100, function()
    local c = S.client
    if not S.joined or not c or not valid(c.hud) or not c.hudParts then return end
    local ui, parts = c.hud, c.hudParts
    pcall(function() ui.WaveNum:SetText(FText(parts[1] or "")) end)
    pcall(function() ui.WaveNumText:SetText(FText(parts[2] or "")) end)
    pcall(function() ui.EnemiesTextBox:SetText(FText(parts[3] or "")) end)
    pcall(function() ui.MoneyText:SetText(FText(parts[4] or "")) end)
    pcall(function() ui.ElapsedTimer:SetText(FText(parts[5] or "")) end)
end)

---------------------------------------------------------------------------
-- Client shots, shown on the host: the client notices its clip going down and tells the host,
-- which plays the fire animation on the puppet's gun. (Damage still comes from the client's hits.)
---------------------------------------------------------------------------
local shot = { weap = nil, ammo = nil }
S.every(30, function()
    if not S.joined then return end
    local pawn = S.client.pawn
    if not valid(pawn) then return end
    local w = pawn.CurrentWeapon
    if not valid(w) then shot.weap, shot.ammo = nil, nil return end
    local name, ammo = w:GetFullName(), w.CurrentAmmoInClip
    if shot.weap == name and shot.ammo and ammo < shot.ammo then
        S.toServer("F", shot.ammo - ammo)
    end
    shot.weap, shot.ammo = name, ammo
end)

handlers.server["F"] = function(pc, p)
    local pawn = pc.Pawn
    if not valid(pawn) then return end
    local w = pawn.CurrentWeapon
    if not valid(w) then return end
    for _ = 1, math.min(tonumber(p[1]) or 1, 3) do
        pcall(function() w:FireAnimation(false) end)
    end
end

---------------------------------------------------------------------------
-- Down / revive instead of dying.
-- A dead player makes the game restart the level (which ends the co-op session), so a player
-- whose health falls under DOWN_AT becomes "downed": invulnerable and unable to move. A partner
-- standing next to them for REVIVE_TIME brings them back with half health. If everyone is down,
-- the host restarts the arena and clients reconnect by themselves.
-- Each machine watches its own pawn; the host keeps track of everyone (messages "DN").
---------------------------------------------------------------------------
local DOWN_AT, HIT_CAP, REVIVE_TIME, REVIVE_DIST = 0.3, 45, 3000, 260
local me = { down = false, max = nil }
S.me = me

local function myPawn()
    if S.joined then return S.client.pawn end
    local pc = localPC()
    return valid(pc) and pc.Pawn or nil
end

local function setDown(p, down)
    me.down = down
    pcall(function() p:SetEnableMovement(not down) end)
    if down then
        pcall(function() p:SetInvulnerableState(true) end)
    else
        if not S.devGod then pcall(function() p:SetInvulnerableState(false) end) end
        p.Health = math.max(p.Health, (me.max or 200) * 0.5)
    end
    log(down and "you are DOWN - your partner revives you by standing next to you" or "revived")
    if S.joined then S.toServer("DN", down and 1 or 0) else S.setDowned("host", down) end
end

S.every(0, function()
    if not (S.hosting or S.joined) or not netDriver() then return end
    local p = myPawn()
    if not valid(p) or p.bIsDead then return end
    if not me.max then
        local ok, m = pcall(function() return p:GetMaxHealth() end)
        me.max = (ok and type(m) == "number" and m > 0) and m or 200
    end
    if p.DamageLimit ~= HIT_CAP then pcall(function() p:SetDamageLimit(HIT_CAP) end) end
    if not me.down and p.Health <= me.max * DOWN_AT then setDown(p, true) end
end)

-- Host side bookkeeping: who is down, revive progress, wipe.
S.downed = {}       -- key ("host" or controller name) -> { down = bool, progress = ms }
function S.setDowned(key, down)
    S.downed[key] = { down = down, progress = 0 }
end
handlers.server["DN"] = function(pc, p) S.setDowned(pc:GetFName():ToString(), p[1] == "1") end
handlers.client["RV"] = function() local p = myPawn(); if valid(p) and me.down then setDown(p, false) end end

local function playerPositions()
    local list = {}
    local host = localPC()
    if valid(host) and valid(host.Pawn) then list["host"] = { pc = host, pos = host.Pawn:K2_GetActorLocation() } end
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() and valid(pc.Pawn) then
            list[pc:GetFName():ToString()] = { pc = pc, pos = pc.Pawn:K2_GetActorLocation() }
        end
    end
    return list
end

S.wipeAt = nil
S.every(250, function(dt)
    if not isServer() then return end
    local players = playerPositions()
    local alive, total = 0, 0
    for key, info in pairs(players) do
        total = total + 1
        local d = S.downed[key]
        if d and d.down then
            local helper = false
            for other, oinfo in pairs(players) do
                local od = S.downed[other]
                if other ~= key and not (od and od.down) and dist2(oinfo.pos, info.pos) <= REVIVE_DIST ^ 2 then helper = true end
            end
            d.progress = helper and (d.progress + dt) or 0
            if d.progress >= REVIVE_TIME then
                d.down, d.progress = false, 0
                if key == "host" then
                    local p = myPawn(); if valid(p) then setDown(p, false) end
                else
                    S.toClient(info.pc, "RV")
                end
            end
        else
            alive = alive + 1
        end
    end
    if total > 1 and alive == 0 then
        S.wipeAt = S.wipeAt or (os.time() + 3)
        if os.time() >= S.wipeAt then
            log("everyone is down - restarting the arena")
            S.wipeAt, S.downed = nil, {}
            S.toClients("RJ")
            S.host(S.hostMap)
        end
    else
        S.wipeAt = nil
    end
end)

-- Client: if we lose the host (arena restart, network hiccup), keep trying to get back in.
handlers.client["RJ"] = function() S.rejoin = { at = os.time() + 15, tries = 0 } end
S.every(1000, function()
    if not S.joined or not S.lastIP then return end
    if netDriver() then S.rejoin = nil; return end
    S.rejoin = S.rejoin or { at = os.time() + 8, tries = 0 }
    if os.time() >= S.rejoin.at and S.rejoin.tries < 12 then
        local tries = S.rejoin.tries + 1
        log("reconnecting to " .. S.lastIP .. " (try " .. tries .. ")")
        S.join(S.lastIP)            -- resets S.rejoin
        S.rejoin = { at = os.time() + 15, tries = tries }
    end
end)

---------------------------------------------------------------------------
-- No pause in co-op: the host's pause menu would freeze the whole session for everyone.
-- While somebody is connected, the menu still opens but the world keeps running.
---------------------------------------------------------------------------
S.every(200, function()
    if not isServer() then return end
    local remote = false
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() then remote = true break end
    end
    if not remote then return end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local w = world()
    if valid(w) and GS:IsGamePaused(w) then
        GS:SetGamePaused(w, false)
    end
end)

---------------------------------------------------------------------------
-- Host: enemies shoot the client's PUPPET here; the client's real pawn lives on the client.
-- Every frame: whatever health the puppet lost is sent to its client, and the puppet is healed
-- back (hit damage is capped, so it can't die between two frames). The client applies the damage
-- to its own pawn (and goes down / gets revived by our normal rules).
---------------------------------------------------------------------------
local PUPPET_HP = 1000
S.puppetDamage = 0
S.every(0, function()
    if not isServer() then return end
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() then
            local p = pc.Pawn
            if valid(p) and not p.bIsDead then
                if p.bInvulnerable then pcall(function() p:SetInvulnerableState(false) end) end
                if p.DamageLimit ~= HIT_CAP then pcall(function() p:SetDamageLimit(HIT_CAP) end) end
                local key = p:GetFullName()
                S.puppetSeen = S.puppetSeen or {}
                local lost = S.puppetSeen[key] and (PUPPET_HP - p.Health) or 0   -- first sight: just top up
                S.puppetSeen[key] = true
                if lost > 0.5 and lost < PUPPET_HP then
                    S.toClient(pc, "H", string.format("%.1f", lost))
                    S.puppetDamage = S.puppetDamage + lost
                end
                if p.Health ~= PUPPET_HP then p.Health = PUPPET_HP end
            end
        end
    end
end)

handlers.client["H"] = function(_, p)
    local pawn = S.client.pawn
    local dmg = tonumber(p[1]) or 0
    if not valid(pawn) or dmg <= 0 or pawn.bInvulnerable then return end
    pawn.Health = pawn.Health - dmg
end

-- Client -> host: our pose 20 times a second.
S.every(50, function()
    if not S.joined then return end
    local c = S.client
    if not valid(c.pawn) then return end
    local pc = localPC()
    if not valid(pc) then return end
    local l = c.pawn:K2_GetActorLocation()
    local v = c.pawn:GetVelocity()
    local r = pc:GetControlRotation()
    S.toServer("P", fmtVec(l), string.format("%.1f|%.1f", r.Yaw, r.Pitch), fmtVec(v))
end)

-- Host: move the client's puppet.
handlers.server["P"] = function(pc, p)
    local pawn = pc.Pawn
    if not valid(pawn) then return end
    local l, yaw, pitch, v = vec(p, 1), tonumber(p[4]), tonumber(p[5]), vec(p, 6)
    pawn:K2_SetActorLocationAndRotation(l, { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
    pcall(function() pawn.CharacterMovement.Velocity = v end)
    pcall(function() pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 }) end)
end

-- Host: the game's own "restart level" reloads the map WITHOUT ?listen, which silently ends the
-- session. If we're hosting and end up on a map without a server, re-host it (clients reconnect
-- on their own). Leaving to the menu/safehouse ends hosting.
local function currentLevelName()
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, name = pcall(function() return GS:GetCurrentLevelName(world(), true):ToString() end)
    return ok and name or nil
end
S.every(1000, function()
    if not S.hosting or S.awaitHostLoad or loadedAt == 0 or os.time() - loadedAt < 4 then return end
    local name = currentLevelName()
    if not name or name == "" then return end
    local hostShort = (S.hostMap or ""):match("([^/]+)$")
    if name ~= hostShort then
        log("left the arena (" .. name .. ") - co-op hosting stopped")
        S.hosting = false
        return
    end
    if not netDriver() then
        log("level restarted without a server - hosting it again")
        S.host(S.hostMap)
    end
end)

S.every(500, function()
    if loadedAt > 0 and os.time() - loadedAt >= 2 then
        -- the level's own player pawn has been possessed by now
        if S.hosting and netDriver() then setAutoPossess(false) end
    end
    if isServer() then setupRemotePlayers() end
    if S.joined then fixClientController() end
    if next(parked) then unparkReady() end
    if S.devGod and isServer() then   -- dev only: the host can't be hurt (puppets are handled separately)
        local hp = localPC()
        if valid(hp) and valid(hp.Pawn) and not hp.Pawn.bInvulnerable then
            pcall(function() hp.Pawn:SetInvulnerableState(true) end)
        end
    end
end)

-- Dev: walk the local pawn forward for N seconds (movement test without window focus).
function S.walk(seconds)
    local pc = localPC()
    if not valid(pc) or not valid(pc.Pawn) then return "no pawn" end
    local pawn = pc.Pawn
    local left = (seconds or 2) * 1000
    local fwd = pawn:GetActorForwardVector()
    S.every(0, function(dt)
        left = left - dt
        if not valid(pawn) or left <= 0 then return true end
        pawn:AddMovementInput(fwd, 1.0, true)
    end)
    local l = pawn:K2_GetActorLocation()
    return string.format("walking from %.0f %.0f %.0f", l.X, l.Y, l.Z)
end

-- Dev: aim at the nearest living enemy and fire the local player's weapon (no input needed).
function S.shootNearest(shots)
    local pc = localPC()
    if not valid(pc) or not valid(pc.Pawn) then return "no pawn" end
    local pawn = pc.Pawn
    local eye = pawn:K2_GetActorLocation()
    eye.Z = eye.Z + 60
    local playerCls = classOf("/Script/CPPFPS.BasePlayer")
    local best, bestD
    for _, c in ipairs(S.allOf("/Script/CPPFPS.BaseCharacter")) do
        if not c:IsA(playerCls) and not c.bIsDead then
            local d = dist2(c:K2_GetActorLocation(), eye)
            if not bestD or d < bestD then best, bestD = c, d end
        end
    end
    if not best then return "no enemy" end
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local target = best:K2_GetActorLocation()
    local rot = KML:FindLookAtRotation(eye, target)
    pc:SetControlRotation(rot)
    local n = shots or 3
    local fired = 0
    S.every(250, function()
        if fired >= n then return true end
        if valid(pawn) then pcall(function() pawn:NPCFireWeapon(1.0, true, rot) end) end
        fired = fired + 1
    end)
    return string.format("aiming at %s dist %.0f hp %.0f", best:GetFName():ToString(), math.sqrt(bestD), best.Health)
end

-- Dev: record which UFunctions run (ProcessEvent) for a short window, to compare host vs client.
local trace = { on = false, seen = {}, order = {} }
local traceRegistered = false
function S.traceStart(ms, filter)
    trace.on, trace.seen, trace.order, trace.filter = true, {}, {}, filter
    if not traceRegistered and RegisterProcessEventPreCallback then
        traceRegistered = true
        RegisterProcessEventPreCallback(function(ctx, fn)
            if not trace.on then return end
            local ok, name = pcall(function()
                local f = fn.get and fn:get() or fn
                local c = ctx.get and ctx:get() or ctx
                return c:GetClass():GetFName():ToString() .. ":" .. f:GetFName():ToString()
            end)
            if ok and not trace.seen[name] then
                if not trace.filter or name:find(trace.filter) then
                    trace.seen[name] = true
                    if #trace.order < 400 then table.insert(trace.order, name) end
                end
            end
        end)
    end
    S.every(ms or 1500, function() trace.on = false; return true end)
    return "tracing (registered=" .. tostring(traceRegistered) .. ")"
end
function S.traceDump()
    local f = io.open("ue4ss/Mods/T2Coop/trace.txt", "w")
    if f then f:write(table.concat(trace.order, "\n")); f:close() end
    return "trace entries: " .. #trace.order
end

function S.where()
    local s = ""
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local p = pc.Pawn
        if valid(p) then
            local l = p:K2_GetActorLocation()
            s = s .. string.format(" | %s%s %.0f %.0f %.0f", pc:IsLocalController() and "*" or "", p:GetFName():ToString(), l.X, l.Y, l.Z)
        end
    end
    return s
end

-- Dev command file (Mods/T2Coop/cmd.txt): each line is Lua run inside this mod.
S.every(500, function()
    local path = "ue4ss/Mods/T2Coop/cmd.txt"
    local f = io.open(path, "r")
    if not f then return end
    local data = f:read("*a"); f:close()
    if not data or data == "" then return end
    local w = io.open(path, "w"); if w then w:close() end
    for line in data:gmatch("[^\r\n]+") do
        local fn, cerr = load(line)
        if not fn then log("cmd compile error: " .. tostring(cerr))
        else
            local ok, res = pcall(fn)
            log((ok and "cmd ok: " or "cmd error: ") .. tostring(res))
        end
    end
end)

---------------------------------------------------------------------------
-- Engine.ini: hosting needs [OnlineSubsystem] DefaultPlatformService=Null (with the shipped
-- Steam/GOG services a listen server can't start). It's read at startup, so if it's missing we
-- add it now and it works from the next launch.
---------------------------------------------------------------------------
local function ensureEngineIni()
    local base = os.getenv("LOCALAPPDATA")
    if not base then return end
    local path = base .. "/CPPFPS/Saved/Config/WindowsNoEditor/Engine.ini"
    local f = io.open(path, "r")
    local text = f and f:read("*a") or ""
    if f then f:close() end
    if text:find("DefaultPlatformService%s*=%s*Null") then S.iniOk = true return end
    local w = io.open(path, "a")
    if not w then log("could not update Engine.ini") return end
    w:write("\n[OnlineSubsystem]\nDefaultPlatformService=Null\n")
    w:close()
    S.iniOk = false
    log("Engine.ini updated - RESTART THE GAME once for co-op hosting to work")
end
pcall(ensureEngineIni)

---------------------------------------------------------------------------
-- Player-facing controls.
--   F5  host co-op on the selected arena      F6  join the host from config.txt
--   F7  leave co-op (back to the main menu)   F8  pick the next arena (for hosting)
-- config.txt (next to this mod's folder): join_ip=, map=
---------------------------------------------------------------------------
local CONFIG_PATH = "ue4ss/Mods/T2Coop/config.txt"
local cfg = { join_ip = "127.0.0.1", map = "/Game/Maps/HordeMode/Horde_Killhouse" }
local function loadConfig()
    local f = io.open(CONFIG_PATH, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v and v ~= "" and not line:match("^%s*#") then cfg[k] = v end
    end
    f:close()
end
local function saveConfig()
    local f = io.open(CONFIG_PATH, "w")
    if not f then return end
    f:write("# Trepang2 Co-op settings\n")
    f:write("# IP of the host (theirs: whatismyip.com; port 7777 UDP must be open, or use Porthole / Radmin VPN)\n")
    f:write("join_ip=" .. cfg.join_ip .. "\n")
    f:write("# arena to host (F8 cycles through all arenas in game)\n")
    f:write("map=" .. cfg.map .. "\n")
    f:close()
end
loadConfig()
saveConfig()
S.cfg = cfg

-- On-screen notice: reuse the horde "now playing" popup (text + fade out).
local POPUP_CLASS = "/Game/Maps/HordeMode/UI_HordeMusicPopup.UI_HordeMusicPopup_C"
local popup
function S.notify(text)
    log("notice: " .. text)
    pcall(function()
        if not valid(popup) then
            local cls = classOf(POPUP_CLASS)
            if not valid(cls) and LoadAsset then cls = LoadAsset(POPUP_CLASS) end
            if not valid(cls) then return end
            local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            popup = WBL:Create(world(), cls, localPC())
            if valid(popup) then popup:AddToViewport(50) end
        end
        if valid(popup) then popup["Fade in Music"](popup, FText(text)) end
    end)
end

local arenas
local function listArenas()
    if arenas then return arenas end
    arenas = {}
    local AR = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers"):GetAssetRegistry()
    for _, d in ipairs({ "/Game/Maps/HordeMode", "/Game/Maps/HordeMode/HordeB", "/Game/Maps/HordeMode/HordeC", "/Game/Maps/HordeMode/Patch01" }) do
        local arr = {}
        pcall(function() AR:GetAssetsByPath(FName(d, EFindName.FNAME_Add), arr, false, false) end)
        for _, a in ipairs(arr) do
            pcall(function()
                local x = a:get()
                local name = x.PackageName:ToString()
                if x.AssetClass:ToString() == "World" and name:find("/Horde") and not name:find("Sublevel") then
                    table.insert(arenas, name)
                end
            end)
        end
    end
    table.sort(arenas)
    return arenas
end

local function shortName(map) return (map:match("([^/]+)$") or map):gsub("^Horde_", "") end

local pending = nil
local function onKey(action) pending = action end
pcall(function()
    RegisterKeyBind(Key.F5, function() onKey("host") end)
    RegisterKeyBind(Key.F6, function() onKey("join") end)
    RegisterKeyBind(Key.F7, function() onKey("leave") end)
    RegisterKeyBind(Key.F8, function() onKey("nextmap") end)
end)

-- Also read the keys through the game's own input (works whenever the game gets the key).
local keyState = {}
local KEYS = { F5 = "host", F6 = "join", F7 = "leave", F8 = "nextmap" }
local keyStructs = {}
S.every(50, function()
    local pc = localPC()
    if not valid(pc) then return end
    for name, action in pairs(KEYS) do
        keyStructs[name] = keyStructs[name] or { KeyName = FName(name, EFindName.FNAME_Add) }
        local ok, down = pcall(function() return pc:IsInputKeyDown(keyStructs[name]) end)
        down = ok and down or false
        if down and not keyState[name] then onKey(action) end
        keyState[name] = down
    end
end)

S.every(100, function()
    if not pending then return end
    local action = pending
    pending = nil
    if action == "host" then
        if S.iniOk == false then S.notify("CO-OP: restart the game once (settings were just installed)") return end
        S.notify("CO-OP: hosting " .. shortName(cfg.map) .. " (UDP 7777)")
        S.host(cfg.map)
    elseif action == "join" then
        loadConfig()
        S.notify("CO-OP: joining " .. cfg.join_ip)
        S.join(cfg.join_ip)
    elseif action == "leave" then
        S.notify("CO-OP: leaving")
        S.leave()
    elseif action == "nextmap" then
        local list = listArenas()
        if #list == 0 then S.notify("CO-OP: no arenas found") return end
        local idx = 1
        for i, m in ipairs(list) do if m == cfg.map then idx = i + 1 end end
        if idx > #list then idx = 1 end
        cfg.map = list[idx]
        saveConfig()
        S.notify("CO-OP arena: " .. shortName(cfg.map) .. "  (" .. idx .. "/" .. #list .. ")  F5 = host")
    end
end)

log("v" .. VERSION .. " loaded")
