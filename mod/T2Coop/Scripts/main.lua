-- T2Coop: co-op for Trepang2 on top of Unreal's built-in networking.
-- Host:   T2C.host("/Game/Maps/HordeMode/Horde_Killhouse")
-- Client: T2C.join("1.2.3.4")
local VERSION = "0.7.6"
local function log(s) print("[T2Coop] " .. tostring(s) .. "\n") end

local PLAYER_CDO = "/Game/Blueprint/Player/PlayerBP.Default__PlayerBP_C"
local IP_DRIVER = "/Script/OnlineSubsystemUtils.IpNetDriver"
local STEAM_DRIVER = "/Script/OnlineSubsystemSteam.SteamNetDriver"

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
    if S.gcStopped then S.gcStopped = false; collectgarbage("restart") end
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
            d.DriverClassName = FName(S.driverClass or IP_DRIVER, EFindName.FNAME_Add)
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
    if not valid(gi) then return end
    pcall(function() gi:SetBootFlowFinished() end)
    -- Not once we're in the host's world (spawn point received): calling it while a client was
    -- setting up its pawn crashed the game (blueprint code writing into a widget already gone).
    if S.joined and S.client and S.client.spawn then return end
    local up = false
    pcall(function() up = valid(gi.CurrentLoadingWidget) end)
    if up then pcall(function() gi:ForceStopLoadingScreen() end) end
end

S.stopLoadingScreen = stopLoadingScreen

-- The "press any key" loading screen blocks travel until dismissed; after we start a travel,
-- keep dismissing it for a few seconds (both the old and the new map show it).
local function keepClearingLoadingScreen(ms)
    local left = ms or 15000
    S.every(1000, function(dt)
        left = left - dt
        if S.client and valid(S.client.pawn) then return true end   -- we're in: nothing to clear
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
    if S.hookClientBeginPlay then S.hookClientBeginPlay() end
    forceIpDriver()
    stopLoadingScreen()
    local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pc = FindFirstOf("PlayerController")
    S.lastIP = ip or "127.0.0.1"
    S.rejoin = nil
    local addr = S.lastIP
    -- a SteamID64 (17 digits) means a Steam P2P address
    if addr:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then addr = "steam." .. addr end
    log("joining " .. addr)
    KSL:ExecuteConsoleCommand(world(), "open " .. addr, pc)
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
                if S.sendCampaignState then pcall(S.sendCampaignState, pc) end
                if S.sendDoors then pcall(S.sendDoors, pc) end
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

-- The BeginPlay hook runs Lua for EVERY actor that starts (thousands on a campaign map); the host
-- crashed inside it now and then, and the host doesn't need it. So it is placed only when this
-- game first joins someone, and does nothing unless we are a client. (A hook on just
-- PlayerBP_C:ReceiveBeginPlay doesn't work: UE4SS drops it when the class is reloaded with a map.)
function S.hookClientBeginPlay()
    if S.bpHooked then return end
    S.bpHooked = pcall(function()
        RegisterBeginPlayPostHook(function(ActorParam)
            if not S.joined then return end
            local ok, err = pcall(function()
                local a = ActorParam.get and ActorParam:get() or ActorParam
                if valid(a) then guardPlayerPawn(a) end
            end)
            if not ok then log("beginplay hook error: " .. tostring(err)) end
        end)
    end)
end

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

local function classPath(obj) return obj:GetClass():GetFullName():match("%s(.+)$") end

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

S.lastSeen = {}   -- host: remote controller FName -> os.time() of its last message
local function dispatch(side, pc, text)
    if type(text) ~= "string" or text:sub(1, #PREFIX) ~= PREFIX then return end
    if side == "server" and valid(pc) then S.lastSeen[pc:GetFName():ToString()] = os.time() end
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
S.rawHits = {}

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
    -- Horde money is earned through the HOST player's kill event only; credit the partner's kills.
    if npc.bIsDead then
        local horde = FindFirstOf("HordeModeActor_C")
        if valid(horde) then pcall(function() horde:OnPlayerKilledOther(dmg, dmg, npc, true, false, nil) end) end
        S.stats.partnerKills = (S.stats.partnerKills or 0) + 1
    end
end

S.stats = { hits = 0, deaths = 0 }
S.pendingDeaths = {}
S.pendingHits = {}

local function flushDeaths()
    if #S.pendingDeaths == 0 then return end
    local batch = S.pendingDeaths; S.pendingDeaths = {}
    local playerCls = classOf("/Script/CPPFPS.BasePlayer")
    for _, d in ipairs(batch) do
        S.stats.deaths = S.stats.deaths + 1
        S.toClients("K", fmtVec(d.pos))   -- where it stood alive: the ragdoll may have flown off
    end
end

local function flushHits()
    if #S.rawHits > 0 then
        local batch = S.rawHits; S.rawHits = {}
        local me = localPC()
        local myPawn = S.client and S.client.pawn
        local playerCls = classOf("/Script/CPPFPS.BasePlayer")
        for _, h in ipairs(batch) do
            local ours = false
            if valid(me) and valid(h.inst) and h.inst:GetFullName() == me:GetFullName() then ours = true end
            if not ours and valid(h.causer) and valid(myPawn) then
                local c = h.causer
                if c:GetFullName() == myPawn:GetFullName() then ours = true
                else
                    local o = c:GetOwner()
                    if valid(o) and o:GetFullName() == myPawn:GetFullName() then ours = true end
                end
            end
            if ours and valid(h.target) and not h.target:IsA(playerCls) and h.dmg > 0 then
                table.insert(S.pendingHits, { target = h.target, dmg = h.dmg, head = false })
            end
        end
    end
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
                    table.insert(S.pendingDeaths, { actor = c, pos = aliveNPCs[key] })
                    aliveNPCs[key] = nil
                end
            else
                aliveNPCs[key] = c:K2_GetActorLocation()   -- last position while alive
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
    S.icons = {}
    S.wdup = {}
    S.myGrenades = {}
    S.trigSeen = {}
    S.trQueue, S.trReadyAt = {}, nil
    if S.cut then S.cut = { active = false } end
    S.gate, S.gateDone, S.lastTrig = nil, {}, nil
    S.expectPlayers, S.expectUntil = S.lastCount or 1, os.clock() + 120
    S.dlgSeen = {}
    S.doorSeen = {}
    S.costumes, S.costumeSet = {}, {}
    if S.me then S.me.down, S.me.max = false, nil end
    S.downed = {}
    -- UE4SS crashed inside Lua right after some map loads (host side, ~1 in 4): most likely the Lua
    -- GC finalizing wrappers of objects from the world that was just torn down. Collect now, while
    -- the old world still exists, and keep the GC off until the new map has settled.
    collectgarbage("collect")
    collectgarbage("stop")
    S.gcStopped = true
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
    -- Give the new map a moment: spawning our pawn right away sometimes crashed inside its
    -- animation blueprint's setup (it reads things from the controller that weren't ready yet).
    if os.clock() < (c.spawnAfter or 0) or not valid(pc.PlayerCameraManager) then return end
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
    c.spawnAfter = c.spawnAfter or (os.clock() + 1.5)
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

-- The widget's own Tick rewrites "enemies left" from this machine's (empty) game state every frame,
-- so put the host's value back right after its Tick (post-hook; only a SetText).
S.hudTickHooked = false
local function hookHudTick()
    if S.hudTickHooked then return end
    S.hudTickHooked = pcall(function()
        RegisterHook("/Game/Maps/HordeMode/SideMissionStatusUI.SideMissionStatusUI_C:Tick", function() end, function(self)
            local c = S.client
            if not S.joined or not c or not c.hudParts or not valid(c.hud) then return end
            local ui = self:get()
            if ui:GetFullName() ~= c.hud:GetFullName() then return end
            pcall(function() ui.EnemiesTextBox:SetText(FText(c.hudParts[3] or "")) end)
        end)
    end)
end
S.every(1000, function() if S.joined and not S.hudTickHooked then hookHudTick() end end)

-- Other fields: re-apply the host's values often.
S.every(100, function()
    local c = S.client
    if not S.joined or not c or not valid(c.hud) or not c.hudParts then return end
    local ui, parts = c.hud, c.hudParts
    -- the widget's Tick writes "enemies left: 0" (this machine's empty game state) into
    -- EnemiesTextBox every frame: point that variable at a spare text block nobody sees and
    -- keep the visible one for the host's value
    if c.enemiesFor ~= ui:GetFullName() then
        pcall(function()
            local real = ui.EnemiesTextBox
            local spare = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), ui, FName("T2CSpareEnemies", EFindName.FNAME_Add))
            if valid(real) and valid(spare) then
                ui.EnemiesTextBox = spare
                c.enemiesReal, c.enemiesFor = real, ui:GetFullName()
            end
        end)
    end
    pcall(function() ui.WaveNum:SetText(FText(parts[1] or "")) end)
    pcall(function() ui.WaveNumText:SetText(FText(parts[2] or "")) end)
    pcall(function() (valid(c.enemiesReal) and c.enemiesReal or ui.EnemiesTextBox):SetText(FText(parts[3] or "")) end)
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
        -- Enemy copies on a client can't take damage (UE only damages pawns on the server), so the
        -- host re-traces each shot from our camera in its own world and applies the damage there.
        local pc = localPC()
        local cam = pc.PlayerCameraManager:GetCameraLocation()
        local rot = pc.PlayerCameraManager:GetCameraRotation()
        S.stats.shotsSent = (S.stats.shotsSent or 0) + 1
        S.toServer("SH", fmtVec(cam), string.format("%.2f|%.2f", rot.Yaw, rot.Pitch), shot.ammo - ammo, classPath(w))
    end
    shot.weap, shot.ammo = name, ammo
end)

-- A shot by another player, shown here: gun animation, 3rd-person sound and muzzle flash (that
-- copy of the gun never really fires on this machine).
function S.shotFx(pawn, n)
    if not valid(pawn) then return end
    local w = pawn.CurrentWeapon
    if not valid(w) then return end
    for _ = 1, math.min(n or 1, 3) do
        pcall(function() w:FireAnimation(false) end)
    end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local rot = pawn:K2_GetActorRotation()
    local yaw = math.rad(rot.Yaw)
    local muzzle
    pcall(function()   -- the gun sits in the body's hand: flash a bit in front of it
        local g = w.Mesh3P:K2_GetComponentLocation()
        muzzle = { X = g.X + math.cos(yaw) * 35, Y = g.Y + math.sin(yaw) * 35, Z = g.Z + 5 }
    end)
    if not muzzle then
        local loc = pawn:K2_GetActorLocation()
        muzzle = { X = loc.X + math.cos(yaw) * 70, Y = loc.Y + math.sin(yaw) * 70, Z = loc.Z + 50 }
    end
    pcall(function()
        local snd = w.FireSound3P
        if not valid(snd) then snd = w.FireSound1P end
        if valid(snd) then GS:PlaySoundAtLocation(world(), snd, muzzle, rot, 1.0, 1.0, 0.0, nil, nil, pawn) end
    end)
    pcall(function()
        local fx = w.MuzzleFlash3P[1].MuzzleFlashParticle
        if valid(fx) then GS:SpawnEmitterAtLocation(world(), fx, muzzle, rot, { X = 1, Y = 1, Z = 1 }, true, 0, true) end
    end)
    S.stats.shotFx = (S.stats.shotFx or 0) + 1
end

local function pidOf(pawn)
    local ok, id = pcall(function() return pawn.PlayerState.PlayerId end)
    if ok then return id end
end
S.pidOf = pidOf

handlers.server["F"] = function(pc, p)
    local n = tonumber(p[1]) or 1
    S.shotFx(pc.Pawn, n)
    -- the other clients hear and see it too
    local pid = pidOf(pc.Pawn)
    if pid then
        for _, other in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(other) and not other:IsLocalController() and other:GetFullName() ~= pc:GetFullName() then
                S.toClient(other, "HF", pid, n)
            end
        end
    end
end

-- Host's own shots -> clients (host's pawn on a client is a network copy: its gun never fires there).
local hostShot = { weap = nil, ammo = nil }
S.every(30, function()
    if not S.hosting or not netDriver() then return end
    local pc = localPC()
    local pawn = valid(pc) and pc.Pawn or nil
    if not valid(pawn) then return end
    local w = pawn.CurrentWeapon
    if not valid(w) then hostShot.weap, hostShot.ammo = nil, nil return end
    local name, ammo = w:GetFullName(), w.CurrentAmmoInClip
    if hostShot.weap == name and hostShot.ammo and ammo < hostShot.ammo then
        S.toClients("HF", pidOf(pawn) or -1, hostShot.ammo - ammo)
    end
    hostShot.weap, hostShot.ammo = name, ammo
end)

-- the pawn of player <pid> on this machine (not our own)
function S.bodyOf(pid)
    for _, e in pairs(S.bodies or {}) do
        if valid(e.pawn) and pidOf(e.pawn) == pid then return e.pawn end
    end
end
handlers.client["HF"] = function(_, p)
    local pawn = S.bodyOf(tonumber(p[1]))
    if pawn then S.shotFx(pawn, tonumber(p[2]) or 1) end
end

---------------------------------------------------------------------------
-- Body actions: reload, weapon melee strike (also on bodies lying on the ground), grenade throw,
-- weapon switch. The game plays them only on the first-person arms; each weapon's WeaponAnimSet
-- has the matching third-person body montage (Reload[i].FPP_Character / .TPP_Character). Every
-- machine watches the arms montage of its own pawn; a new one is looked up in the weapon's set and
-- sent as "BA|set|index" (client -> host, the host plays it on that partner's body and passes
-- "BA|pid|set|index" on; the host's own go to every client). The receiver plays the TPP montage of
-- the same weapon on that player's body (and the weapon's own part, e.g. the magazine).
---------------------------------------------------------------------------
do
local ANIM_SETS = { "Reload", "Reload_Empty", "Reload_Cyclic", "Reload_Hostage", "Reload_Hostage_Empty",
    "Melee", "Melee_Impact", "Throw_Grenade", "Throw_Hostage", "Equip", "Equip_Hostage", "Unequip", "Inspect" }
local function ownPawn()
    if S.joined then return S.client and S.client.pawn end
    local pc = localPC()
    return valid(pc) and pc.Pawn or nil
end
-- arms montage -> (set, index) in the weapon's anim set
local function findAction(w, montage)
    local name = montage:GetFName():ToString()
    local set = w.WeaponAnimSet
    for _, k in ipairs(ANIM_SETS) do
        local arr = set[k]
        for i = 1, arr:GetArrayNum() do
            local f = arr[i].FPP_Character
            if valid(f) and f:GetFName():ToString() == name then return k, i end
        end
    end
end
function S.playBodyAction(pawn, setName, idx)
    if not valid(pawn) then return false end
    local w = pawn.CurrentWeapon
    if not valid(w) then return false end
    local ok, played = pcall(function()
        local e = w.WeaponAnimSet[setName][idx]
        local m = e.TPP_Character
        if not valid(m) then return false end
        local ai = pawn.Mesh:GetAnimInstance()
        ai:Montage_Play(m, 1.0, 0, 0.0, true)
        pcall(function()
            local wm = e.TPP_Weapon
            if valid(wm) then w.Mesh3P:GetAnimInstance():Montage_Play(wm, 1.0, 0, 0.0, true) end
        end)
        return true
    end)
    S.stats.bodyActions = (S.stats.bodyActions or 0) + 1
    return ok and played
end

local ba = { last = nil }
S.every(0, function()
    if not (S.hosting or S.joined) or not netDriver() then return end
    local pawn = ownPawn()
    if not valid(pawn) then return end
    local cur
    pcall(function()
        local m = pawn.Mesh1P:GetAnimInstance():GetCurrentActiveMontage()
        if valid(m) then cur = m end
    end)
    local key = cur and cur:GetAddress() or nil
    if key == ba.last then return end
    ba.last = key
    if not cur then return end
    local w = pawn.CurrentWeapon
    if not valid(w) then return end
    local ok, setName, idx = pcall(findAction, w, cur)
    if not ok or not setName then return end
    if S.joined then
        S.toServer("BA", setName, idx)
    elseif #(FindAllOf("PlayerController") or {}) > 1 then
        S.toClients("BA", pidOf(pawn) or -1, setName, idx)
    end
end)

handlers.server["BA"] = function(pc, p)
    local setName, idx = p[1], tonumber(p[2]) or 1
    S.playBodyAction(pc.Pawn, setName, idx)
    local pid = pidOf(pc.Pawn)
    if not pid then return end
    for _, other in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(other) and not other:IsLocalController() and other:GetFullName() ~= pc:GetFullName() then
            S.toClient(other, "BA", pid, setName, idx)
        end
    end
end
handlers.client["BA"] = function(_, p)
    local pawn = S.bodyOf(tonumber(p[1]))
    if pawn then S.playBodyAction(pawn, p[2], tonumber(p[3]) or 1) end
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

-- Enemy copies on a client come with movement mode None: their animation thinks they are in the
-- air (stuck in a falling pose). Give the living ones Walking, like on the host.
S.every(500, function()
    if not S.joined then return end
    for _, n in ipairs(S.allOf("/Game/Blueprint/AI/BaseNPC.BaseNPC_C")) do
        pcall(function()
            if n.bIsDead or (tonumber(n.Health) or 1) <= 0 or S.costumeSet[n:GetFullName()] then return end
            local cm = n.CharacterMovement
            if cm.MovementMode == 0 then cm:SetMovementMode(1, 0) end
        end)
    end
end)

-- Grenade warning circles: every player body has the component and each one draws on OUR screen,
-- so partners' bodies showed their grenades to us and one grenade gave one circle per player.
-- Only our own body keeps it.
S.every(1000, function()
    if not (S.hosting or S.joined) then return end
    local mine = myPawn()
    if not valid(mine) then return end
    for _, p in ipairs(S.allOf("/Game/Blueprint/Player/PlayerBP.PlayerBP_C")) do
        local ok, gi = pcall(function() return p.BP_CircleGrenadeIndicator end)
        if ok and valid(gi) then
            local own = same(p, mine)
            local okT, on = pcall(function() return gi:IsComponentTickEnabled() end)
            if okT and on ~= own then
                pcall(function() gi:SetComponentTickEnabled(own) end)
                if not own then
                    pcall(function()
                        for _, w in ipairs(gi.PointDamageIndicators) do
                            w = w.get and w:get() or w
                            pcall(function() w:RemoveFromParent() end)
                        end
                        gi.PointDamageIndicators:Empty()
                    end)
                end
            end
        end
    end
end)

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
    S.notify(down and "CO-OP: you are DOWN - a partner must stand next to you" or "CO-OP: you are back on your feet")
    if S.joined then S.toServer("DN", down and 1 or 0) else
        S.setDowned("host", down)
        if down then S.toClients("NT", "CO-OP: the host is DOWN - stand next to them to revive") end
    end
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
handlers.server["DN"] = function(pc, p)
    local down = p[1] == "1"
    S.setDowned(pc:GetFName():ToString(), down)
    if down then
        local text = "CO-OP: your partner is DOWN - stand next to them to revive"
        S.notify(text)
        for _, other in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(other) and not other:IsLocalController() and other:GetFullName() ~= pc:GetFullName() then
                S.toClient(other, "NT", text)
            end
        end
    end
end
-- A notice for everybody (host shows it locally, clients get "NT").
function S.say(text)
    S.notify(text)
    S.toClients("NT", (text:gsub("|", "/")))
end
handlers.client["NT"] = function(_, p) S.notify(p[1] or "") end
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
            local before = d.progress
            d.progress = helper and (d.progress + dt) or 0
            -- progress notice about once a second while someone is reviving
            if d.progress > 0 and math.floor(d.progress / 1000) ~= math.floor(before / 1000) then
                S.say(string.format("CO-OP: reviving... %d%%", math.min(99, math.floor(d.progress * 100 / REVIVE_TIME))))
            end
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
            S.wipeAt, S.downed = nil, {}
            S.toClients("RJ")
            if S.isHordeMap(S.hostMap) then
                log("everyone is down - restarting the arena")
                S.host(S.hostMap)
            else
                -- campaign: back to the last checkpoint (the game's own load; we keep the server on)
                log("everyone is down - loading the last checkpoint")
                S.say("CO-OP: everyone is down - back to the last checkpoint")
                S.loadLastSave()
            end
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

---------------------------------------------------------------------------
-- Weapon the client holds, shown on its puppet at the host.
-- Client sends the weapon class when it changes; the host spawns that weapon for the puppet,
-- equips it and removes the old one. (Visual only: damage still comes from the client's hits.)
---------------------------------------------------------------------------
local wsync = { sent = nil, since = 0 }
S.every(250, function(dt)
    if not S.joined then return end
    local pawn = S.client.pawn
    if not valid(pawn) or not valid(pawn.CurrentWeapon) then return end
    local cls = pawn.CurrentWeapon:GetClass():GetFullName():match("%s(.+)$")
    wsync.since = wsync.since + dt
    if cls and (cls ~= wsync.sent or wsync.since >= 5000) then   -- resend now and then (host may have restarted)
        wsync.sent, wsync.since = cls, 0
        S.toServer("WP", cls)
    end
end)

handlers.server["WP"] = function(pc, p)
    local puppet = pc.Pawn
    local path = p[1]
    if not valid(puppet) or not path or path == "" then return end
    local cur = puppet.CurrentWeapon
    if valid(cur) and cur:GetClass():GetFullName():match("%s(.+)$") == path then return end
    local cls = StaticFindObject(path)
    if not valid(cls) and LoadAsset then pcall(function() cls = LoadAsset(path) end) end
    if not valid(cls) then log("weapon sync: unknown class " .. path) return end
    local w = world():SpawnActor(cls, puppet:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(w) then return end
    pcall(function() puppet:ForceEquipWeapon(w) end)
    if valid(cur) then pcall(function() cur:K2_DestroyActor() end) end
    log("puppet of " .. pc:GetFName():ToString() .. " now holds " .. (path:match("([^%.]+)$") or path))
end

---------------------------------------------------------------------------
-- Weapons lying around (level weapons, guns dropped by dead enemies) exist on a client only as
-- network copies, and the game can't fire a network copy. So the client places its OWN local
-- weapon of the same type on top of each loose copy and hides the copy. The player picks up the
-- local one the normal way; we then tell the host to remove the original so nobody else gets it.
-- When the original is taken by someone else (it gets an owner or disappears), our double goes too.
---------------------------------------------------------------------------
S.wdup = {}
local SETTLE_MS = 1500

S.every(500, function(dt)
    if not S.joined or not netDriver() then return end
    local mine = S.client.pawn
    local seen = {}
    for _, w in ipairs(S.allOf("/Script/CPPFPS.BaseWeapon")) do
        if w.Role == 1 and not valid(w:GetOwner()) then          -- loose network copy
            local key = w:GetFullName()
            seen[key] = true
            local e = S.wdup[key]
            if not e then e = { proxy = w, age = 0 }; S.wdup[key] = e end
            e.age = e.age + dt
            if not e.dup and e.age >= SETTLE_MS then            -- let a dropped gun land first
                local ok, dup = pcall(function()
                    return world():SpawnActor(w:GetClass(), w:K2_GetActorLocation(), w:K2_GetActorRotation())
                end)
                if ok and valid(dup) then
                    e.dup, e.cls = dup, classPath(w)
                    w:SetActorHiddenInGame(true)
                    w:SetActorEnableCollision(false)
                end
            end
        end
    end
    for key, e in pairs(S.wdup) do
        local dupOwner = valid(e.dup) and e.dup:GetOwner() or nil
        local weTookIt = valid(dupOwner) and valid(mine) and dupOwner:GetFullName() == mine:GetFullName()
        if weTookIt and not e.reported then
            e.reported = true
            local l = valid(e.proxy) and e.proxy:K2_GetActorLocation() or e.dup:K2_GetActorLocation()
            S.toServer("WT", fmtVec(l), e.cls or "")
        end
        if not seen[key] then
            -- the original is gone or someone holds it: drop our double unless it's in our hands
            if valid(e.dup) and not weTookIt and not valid(dupOwner) then pcall(function() e.dup:K2_DestroyActor() end) end
            S.wdup[key] = nil
        end
    end
end)

-- Host: a client picked up its copy of a loose weapon; remove the original.
handlers.server["WT"] = function(pc, p)
    local pos, cls = vec(p, 1), p[4]
    local best, bd
    for _, w in ipairs(S.allOf("/Script/CPPFPS.BaseWeapon")) do
        if not valid(w:GetOwner()) and (cls == "" or classPath(w) == cls) then
            local d = dist2(w:K2_GetActorLocation(), pos)
            if d < 400 * 400 and (not bd or d < bd) then best, bd = w, d end
        end
    end
    if valid(best) then pcall(function() best:K2_DestroyActor() end) end
end

---------------------------------------------------------------------------
-- Player names. Every client tells the host its name (NM). Our client->host messages travel
-- through ServerChangeName, which overwrites the PlayerState name, so the host keeps putting the
-- real names back and everyone ignores names that look like our messages. The host announces
-- who joined and who left.
---------------------------------------------------------------------------
S.names = {}       -- host: remote controller FName -> player name
local goodNames = {}   -- PlayerState full name -> last real name seen
local function cleanName(n)
    n = tostring(n or "")
    if n:sub(1, #PREFIX) == PREFIX then return nil end
    n = n:gsub("[|~]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if n == "" then return nil end
    return n:sub(1, 24)
end

-- Steam's own list of accounts on this PC; the most recent one is the one playing.
-- (With the Null subsystem used for IP play, the engine only knows the computer name.)
local function steamPersonaName()
    local paths = { "../../../../../../config/loginusers.vdf",
                    "C:/Program Files (x86)/Steam/config/loginusers.vdf",
                    "C:/Program Files/Steam/config/loginusers.vdf" }
    for _, path in ipairs(paths) do
        local f = io.open(path, "r")
        if f then
            local text = f:read("*a")
            f:close()
            local first, recent
            for id, body in text:gmatch('"(%d+)"%s*(%b{})') do
                local name = body:match('"PersonaName"%s*"([^"]*)"')
                local id64 = id
                if name then
                    first = first or { name = name, id = id64 }
                    if body:match('"MostRecent"%s*"1"') then recent = { name = name, id = id64 } end
                end
            end
            local pick = recent or first
            if pick then return pick.name, pick.id end
        end
    end
end

function S.getMyName()
    if S.myName then return S.myName end
    local n = S.cfg and cleanName(S.cfg.name) or nil
    local ok, name, id = pcall(steamPersonaName)
    if ok and id then S.mySteamId = id end
    if not n and ok and name then n = cleanName(name) end
    if not n then
        local pc = localPC()
        if valid(pc) and valid(pc.PlayerState) then
            local ok, v = pcall(function() return pc.PlayerState:GetPlayerName():ToString() end)
            if ok then n = cleanName(v) end
        end
    end
    if n then S.myName = n end
    return n or "Player"
end

-- the name a player goes by (nil if not known yet)
function S.stateName(ps)
    if not valid(ps) then return nil end
    local key = ps:GetFullName()
    local me = localPC()
    if valid(me) and valid(me.PlayerState) and me.PlayerState:GetFullName() == key then return S.getMyName() end
    if S.hosting then
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not pc:IsLocalController() and valid(pc.PlayerState)
                and pc.PlayerState:GetFullName() == key then
                local n = S.names[pc:GetFName():ToString()]
                if n then return n end
            end
        end
    end
    local ok2, v = pcall(function() return ps:GetPlayerName():ToString() end)
    local n = ok2 and cleanName(v) or nil
    if n then goodNames[key] = n end
    return goodNames[key]
end
function S.playerName(p)
    local ok, ps = pcall(function() return p.PlayerState end)
    if not ok then return nil end
    return S.stateName(ps)
end

local function announce(text, except)
    S.notify("CO-OP: " .. text)
    local skip = valid(except) and except:GetFullName() or nil
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() and pc:GetFullName() ~= skip then
            S.toClient(pc, "NT", "CO-OP: " .. text)
        end
    end
end

-- remember our own name while we're not in a network game yet
S.every(2000, function()
    if not S.myName and not netDriver() then S.getMyName() end
end)

-- client: tell the host who we are (repeated; cheap, and survives reconnects)
S.every(3000, function()
    if S.joined and not S.hosting and netDriver() then S.toServer("NM", S.getMyName()) end
end)

handlers.server["NM"] = function(pc, p)
    local key = pc:GetFName():ToString()
    local n = cleanName(p[1]) or "Player"
    local old = S.names[key]
    S.names[key] = n
    if not old then
        announce(n .. " joined", pc)
        S.toClient(pc, "NT", "CO-OP: connected to " .. S.getMyName())
    end
end

-- host: put real names back into the PlayerStates; announce players who left
S.every(250, function()
    if not isServer() then return end
    local present = {}
    -- our own name too (with the Null subsystem the engine only knows the computer name)
    local me = localPC()
    if valid(me) and valid(me.PlayerState) then
        local my = S.getMyName()
        local ok, cur = pcall(function() return me.PlayerState:GetPlayerName():ToString() end)
        if ok and cur ~= my then pcall(function() me.PlayerState.PlayerNamePrivate = my end) end
    end
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() then
            local key = pc:GetFName():ToString()
            -- a client that went back to its menu stays connected here until the engine's
            -- timeout (about a minute); clients send every frame, so 5 s of silence = gone
            local seen = S.lastSeen[key]
            present[key] = not (seen and os.time() - seen > 5)
            local n = S.names[key]
            local ps = pc.PlayerState
            if n and valid(ps) then
                local ok, cur = pcall(function() return ps:GetPlayerName():ToString() end)
                if ok and cur ~= n then
                    if not pcall(function() ps.PlayerNamePrivate = n end) then
                        pcall(function() FindFirstOf("GameModeBase"):ChangeName(pc, n, false) end)
                    end
                end
            end
        end
    end
    for key, n in pairs(S.names) do
        if not present[key] then
            S.names[key] = nil
            S.lastSeen[key] = nil
            announce(n .. " left")
        end
    end
end)

-- The HUD's "friendly under the crosshair" box shows "NONE" for players: show the partner's name.
-- The widget writes "NONE" again every frame, so the text can't be replaced: the box is made
-- see-through while it says NONE (only players get that); the partner's marker shows the name.
S.partnerName = nil
local hudList, hudListAt = {}, 0
S.every(0, function()
    if not (S.hosting or S.joined) then return end
    if os.clock() - hudListAt > 1 then hudList, hudListAt = FindAllOf("PlayerHUD2_C") or {}, os.clock() end
    for _, hud in ipairs(hudList) do
        if valid(hud) then
            local ok, t = pcall(function() return hud.FriendlyCharacterName:GetText():ToString() end)
            if ok then
                -- (render scale, not opacity: the HUD's own fade animation drives the opacity)
                local want = (t == "NONE") and 0.0 or 1.0
                pcall(function()
                    local box = hud.MouseOverFriendlyBox
                    if box.RenderTransform.Scale.X ~= want then box:SetRenderScale({ X = want, Y = want }) end
                end)
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Partner markers: the game's objective icon (shows distance, visible through walls) attached
-- to every other player. On the host the label also says when that player is down.
---------------------------------------------------------------------------
local ICON_CLASS = "/Game/UI/Objective/BP_ObjectiveIcon.BP_ObjectiveIcon_C"
S.modIcons = {}   -- full names of icons this mod spawned (never synced as story objectives)
S.icons = {}   -- target full name -> { icon = actor, label = string }
local function otherPlayers()
    local list = {}
    local me = localPC()
    local mine = valid(me) and valid(me.Pawn) and me.Pawn:GetFullName() or ""
    for _, p in ipairs(S.allOf("/Script/CPPFPS.BasePlayer")) do
        if p:GetFullName() ~= mine and not p.bHidden and not p.bIsDead then table.insert(list, p) end
    end
    return list
end
local function labelFor(p)
    local name = S.playerName(p) or "PARTNER"
    if not S.hosting then return name end
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() and valid(pc.Pawn) and pc.Pawn:GetFullName() == p:GetFullName() then
            local d = S.downed[pc:GetFName():ToString()]
            return (d and d.down) and (name .. " - DOWN") or name
        end
    end
    return name
end
S.every(1000, function()
    if not netDriver() or not (S.hosting or S.joined) then return end
    local me = localPC()
    local alive = {}
    for _, p in ipairs(otherPlayers()) do
        local key = p:GetFullName()
        alive[key] = true
        local e = S.icons[key]
        if not e or not valid(e.icon) then
            local cls = classOf(ICON_CLASS)
            if not valid(cls) and LoadAsset then pcall(function() cls = LoadAsset(ICON_CLASS) end) end
            if valid(cls) then
                local l = p:K2_GetActorLocation()
                local ok, icon = pcall(function() return world():SpawnActor(cls, { X = l.X, Y = l.Y, Z = l.Z + 110 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
                if ok and valid(icon) then
                    icon.OwningPlayer = me
                    S.modIcons[icon:GetFullName()] = true
                    pcall(function() icon:K2_AttachToActor(p, FName("None"), 1, 1, 1, false) end)
                    pcall(function() icon:Sickle_ShowIcon() end)
                    e = { icon = icon, label = nil }
                    S.icons[key] = e
                end
            end
        end
        if e and valid(e.icon) then
            local label = labelFor(p)
            S.partnerName = (label:gsub(" %- DOWN$", ""))
            if label ~= e.label then
                e.label = label
                pcall(function() e.icon:HackOverrideSubtitle(FText(label)) end)
            end
        end
    end
    for key, e in pairs(S.icons) do
        if not alive[key] then
            if valid(e.icon) then pcall(function() e.icon:K2_DestroyActor() end) end
            S.icons[key] = nil
        end
    end
end)

---------------------------------------------------------------------------
-- Host: a partner's shot. Trace from their camera, damage what the bullet hits.
---------------------------------------------------------------------------
local weaponCDO = {}
local function weaponStats(path)
    local st = weaponCDO[path]
    if st then return st end
    st = { dmg = 20, pellets = 1, head = 2.0 }
    local cdoPath = path:gsub("%.([^%.]+)$", ".Default__%1")
    local cdo = StaticFindObject(cdoPath)
    if valid(cdo) then
        pcall(function() local d = cdo:GetDamage(); if type(d) == "number" and d > 0 then st.dmg = d end end)
        pcall(function() local n = cdo:GetBulletCount(); if type(n) == "number" and n > 0 then st.pellets = math.min(n, 12) end end)
        pcall(function() local h = cdo.HeadshotDamageMultiplier; if type(h) == "number" and h >= 1 then st.head = h end end)
    end
    weaponCDO[path] = st
    return st
end

local function creditPartnerKill(npc, dmg)
    local horde = FindFirstOf("HordeModeActor_C")
    if valid(horde) then pcall(function() horde:OnPlayerKilledOther(dmg, dmg, npc, true, false, nil) end) end
    S.stats.partnerKills = (S.stats.partnerKills or 0) + 1
end
S.creditPartnerKill = creditPartnerKill

handlers.server["SH"] = function(pc, p)
    local cam, yaw, pitch = vec(p, 1), tonumber(p[4]), tonumber(p[5])
    local shots, wpath = math.min(tonumber(p[6]) or 1, 3), p[7] or ""
    local puppet = pc.Pawn
    S.stats.shots = (S.stats.shots or 0) + 1
    if not yaw or not pitch then return end
    local st = weaponStats(wpath)
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    DamageTypeCls = DamageTypeCls or classOf("/Script/Engine.DamageType")
    local playerCls = classOf("/Script/CPPFPS.BasePlayer")
    local charCls = classOf("/Script/CPPFPS.BaseCharacter")
    local fwd = KML:GetForwardVector({ Pitch = pitch, Yaw = yaw, Roll = 0 })
    local ignore = valid(puppet) and { puppet } or {}
    for _ = 1, shots do
        for _ = 1, st.pellets do
            local dir = st.pellets > 1 and KML:RandomUnitVectorInConeInDegrees(fwd, 4.0) or fwd
            local from = { X = cam.X + dir.X * 20, Y = cam.Y + dir.Y * 20, Z = cam.Z + dir.Z * 20 }
            local to = { X = cam.X + dir.X * 15000, Y = cam.Y + dir.Y * 15000, Z = cam.Z + dir.Z * 15000 }
            local hit = {}
            local ok, blocked = pcall(function()
                return KSL:LineTraceSingle(world(), from, to, 0, false, ignore, 0, hit, true,
                    { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
            end)
            S.stats.lastTrace = tostring(ok) .. "/" .. tostring(blocked)
            if ok and blocked then
                local actor
                pcall(function() local a = hit.Actor; actor = (type(a) == "userdata" and a.Get) and a:Get() or a end)
                pcall(function() S.stats.lastTrace = S.stats.lastTrace .. " " .. actor:GetFName():ToString() end)
                if valid(actor) and actor:IsA(charCls) and not actor:IsA(playerCls) and not actor.bIsDead then
                    -- the trace hits the capsule; call it a headshot when it lands near the top of it
                    local al = actor:K2_GetActorLocation()
                    local headshot = false
                    pcall(function() headshot = hit.ImpactPoint.Z > al.Z + 55 end)
                    pcall(function() hit.BoneName = FName(headshot and "head" or "spine_03", EFindName.FNAME_Add) end)
                    local dmg = st.dmg
                    -- the game reads headshots from the real mesh bone, which a capsule trace doesn't give
                    if headshot and not actor.bImmuneToHeadshots then dmg = dmg * st.head end
                    GS:ApplyPointDamage(actor, dmg, dir, hit, pc, valid(puppet) and puppet or nil, DamageTypeCls)
                    S.stats.hits = S.stats.hits + 1
                    if actor.bIsDead then creditPartnerKill(actor, dmg) end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Partner grenades. A client's grenade explodes only on that client and can't hurt enemy copies
-- (a grenade spawned on the host from Lua doesn't arm either). So the client watches its own
-- grenades and, when one is gone (exploded), tells the host where; the host applies the same
-- radial damage there on the partner's behalf (players are not hurt).
---------------------------------------------------------------------------
S.myGrenades = {}
S.every(0, function()
    if not S.joined or not netDriver() then return end
    local mine = S.client.pawn
    if not valid(mine) then return end
    local myName = mine:GetFullName()
    for _, pj in ipairs(S.allOf("/Script/CPPFPS.BaseProjectile")) do
        if pj.Role == 3 then
            local key = pj:GetFullName()
            local g = S.myGrenades[key]
            if not g then
                local inst = pj.Instigator
                local ok, radius = pcall(function() return pj.GrenadeDamageRadius end)
                if valid(inst) and inst:GetFullName() == myName and ok and type(radius) == "number" and radius > 0 then
                    g = { actor = pj, radius = radius, base = pj.GrenadeBaseDamage, min = pj.GrenadeMinDamage, dmgCls = "" }
                    pcall(function() g.dmgCls = pj.DamageClass:GetFullName():match("%s(.+)$") or "" end)
                    S.myGrenades[key] = g
                end
            end
            if g then g.pos = pj:K2_GetActorLocation() end
        end
    end
    for key, g in pairs(S.myGrenades) do
        if not valid(g.actor) or (g.actor.IsActorBeingDestroyed and g.actor:IsActorBeingDestroyed()) then
            if g.pos then
                S.toServer("EX", fmtVec(g.pos), string.format("%.1f|%.1f|%.1f", g.base or 100, g.min or 0, g.radius), g.dmgCls or "")
                S.stats.exSent = (S.stats.exSent or 0) + 1
            end
            S.myGrenades[key] = nil
        end
    end
end)

handlers.server["EX"] = function(pc, p)
    local pos, base, minD, radius, dcls = vec(p, 1), tonumber(p[4]) or 100, tonumber(p[5]) or 0, tonumber(p[6]) or 500, p[7]
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local dt = (dcls and dcls ~= "") and StaticFindObject(dcls) or nil
    if not valid(dt) then dt = classOf("/Script/Engine.DamageType") end
    -- Not ApplyRadialDamage*: calling it from Lua stopped UE4SS on the host. Plain ApplyDamage per
    -- enemy in range, linear falloff from base (inner 30%) to min at the edge.
    local playerCls = classOf("/Script/CPPFPS.BasePlayer")
    local puppet = pc.Pawn
    for _, c in ipairs(S.allOf("/Script/CPPFPS.BaseCharacter")) do
        if not c:IsA(playerCls) and not c.bIsDead then
            local d = math.sqrt(dist2(c:K2_GetActorLocation(), pos))
            if d <= radius then
                local k = d <= radius * 0.3 and 1 or (1 - (d - radius * 0.3) / (radius * 0.7))
                local dmg = minD + (base - minD) * k
                GS:ApplyDamage(c, dmg, pc, valid(puppet) and puppet or nil, dt)
                if c.bIsDead then S.creditPartnerKill(c, dmg) end
            end
        end
    end
    S.stats.explosions = (S.stats.explosions or 0) + 1
end

---------------------------------------------------------------------------
-- Partner melee: kick (Melee = right mouse by default) and sword swings (fire with a sword).
-- Like shots, the host re-traces the hit from the partner's camera (short range) and applies it.
---------------------------------------------------------------------------
local melee = { kick = false, fire = false }
local MELEE_KEY = { KeyName = nil }
local FIRE_KEY = { KeyName = nil }
S.every(0, function()
    if not S.joined then return end
    local pawn = S.client.pawn
    local pc = localPC()
    if not valid(pawn) or not valid(pc) then return end
    MELEE_KEY.KeyName = MELEE_KEY.KeyName or FName("RightMouseButton", EFindName.FNAME_Add)
    FIRE_KEY.KeyName = FIRE_KEY.KeyName or FName("LeftMouseButton", EFindName.FNAME_Add)
    local kick = pc:IsInputKeyDown(MELEE_KEY)
    local fire = pc:IsInputKeyDown(FIRE_KEY)
    local function send(dmg, head, range)
        local cam = pc.PlayerCameraManager:GetCameraLocation()
        local rot = pc.PlayerCameraManager:GetCameraRotation()
        S.toServer("MK", fmtVec(cam), string.format("%.2f|%.2f|%.1f|%.2f|%.0f", rot.Yaw, rot.Pitch, dmg, head, range or 250))
    end
    if kick and not melee.kick then
        -- Melee key: a kick while in the air, a strike with the weapon (butt / grip / fist) on the ground.
        local falling = false
        pcall(function() falling = pawn.CharacterMovement:IsFalling() end)
        local dmg, head, range = 50, 2, 250
        if falling then
            pcall(function() dmg = pawn.KickMeleeDamage; head = pawn.KickMeleeHeadshotDamageMultiplier; range = pawn.MeleeKickRange end)
            -- sprint + jump + melee is a two-leg dropkick, handled below; give it a moment to start
            local wait = 150
            S.every(30, function(dt)
                wait = wait - dt
                if valid(pawn) and pawn.IsDropkicking then return true end
                if wait <= 0 then send(dmg, head, range); return true end
            end)
            melee.kick, melee.fire = kick, fire
            return
        else
            local w = pawn.CurrentWeapon
            if valid(w) then
                pcall(function() dmg = w.MeleeDamage; head = w.MeleeHeadshotDamageMultiplier; range = w.MeleeRange end)
            end
        end
        send(dmg, head, range)
    end
    if fire and not melee.fire then
        local w = pawn.CurrentWeapon
        if valid(w) and w:GetClass():GetFName():ToString():find("Sword") then
            local dmg = 100
            pcall(function() local d = w:GetDamage(); if type(d) == "number" and d > 0 then dmg = d end end)
            send(dmg, 2, 300)
        end
    end
    melee.kick, melee.fire = kick, fire
end)

handlers.server["MK"] = function(pc, p)
    local cam, yaw, pitch = vec(p, 1), tonumber(p[4]), tonumber(p[5])
    local dmg, headMul = tonumber(p[6]) or 50, tonumber(p[7]) or 2
    local reach = math.min(math.max((tonumber(p[8]) or 250) + 60, 150), 450)
    if not yaw then return end
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    DamageTypeCls = DamageTypeCls or classOf("/Script/Engine.DamageType")
    local dir = KML:GetForwardVector({ Pitch = pitch, Yaw = yaw, Roll = 0 })
    local puppet = pc.Pawn
    local hit = {}
    local ok, blocked = pcall(function()
        return KSL:LineTraceSingle(world(), cam, { X = cam.X + dir.X * reach, Y = cam.Y + dir.Y * reach, Z = cam.Z + dir.Z * reach },
            0, false, valid(puppet) and { puppet } or {}, 0, hit, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
    end)
    if not (ok and blocked) then return end
    local actor
    pcall(function() local a = hit.Actor; actor = (type(a) == "userdata" and a.Get) and a:Get() or a end)
    if not valid(actor) or not actor:IsA(classOf("/Script/CPPFPS.BaseCharacter")) or actor:IsA(classOf("/Script/CPPFPS.BasePlayer")) or actor.bIsDead then return end
    local al = actor:K2_GetActorLocation()
    local headshot = false
    pcall(function() headshot = hit.ImpactPoint.Z > al.Z + 55 end)
    if headshot then dmg = dmg * headMul end
    GS:ApplyPointDamage(actor, dmg, dir, hit, pc, valid(puppet) and puppet or nil, DamageTypeCls)
    S.stats.melee = (S.stats.melee or 0) + 1
    if actor.bIsDead then S.creditPartnerKill(actor, dmg) end
end

-- Two-leg dropkick (sprint + jump + melee): it hurts whoever the flying player crashes into.
-- While it lasts, every enemy copy that comes within reach is reported once; the host applies it.
local dk = { active = false, hit = {} }
S.every(0, function()
    if not S.joined then return end
    local pawn = S.client.pawn
    if not valid(pawn) then return end
    local on = false
    pcall(function() on = pawn.IsDropkicking end)
    if on and not dk.active then dk.hit = {} end
    dk.active = on
    if not on then return end
    local me = pawn:K2_GetActorLocation()
    local playerCls = classOf("/Script/CPPFPS.BasePlayer")
    for _, c in ipairs(S.allOf("/Script/CPPFPS.BaseCharacter")) do
        if not c:IsA(playerCls) and not c.bIsDead then
            local key = c:GetFullName()
            if not dk.hit[key] and dist2(c:K2_GetActorLocation(), me) <= 160 * 160 then
                dk.hit[key] = true
                local dmg = 120
                pcall(function() dmg = pawn.KickMeleeDamage * 1.5 end)
                S.toServer("DK", fmtVec(c:K2_GetActorLocation()), string.format("%.1f", dmg))
            end
        end
    end
end)

handlers.server["DK"] = function(pc, p)
    local npc = nearestNPC(vec(p, 1), 300)
    if not valid(npc) then return end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    DamageTypeCls = DamageTypeCls or classOf("/Script/Engine.DamageType")
    local dmg = tonumber(p[4]) or 120
    GS:ApplyDamage(npc, dmg, pc, valid(pc.Pawn) and pc.Pawn or nil, DamageTypeCls)
    S.stats.dropkicks = (S.stats.dropkicks or 0) + 1
    if npc.bIsDead then S.creditPartnerKill(npc, dmg) end
end

---------------------------------------------------------------------------
-- Other players' bodies. A player's pawn is built for first person: its full body (Mesh) is
-- hidden on its own machine, the legs-only body (MeshLegs), arms (Mesh1P) and first-person gun
-- are shown instead. On the other machines the same pawn came out as a half body with a gun
-- floating in the air. For every OTHER player's pawn we show the full body with the gun in its
-- right hand and hide the first-person pieces.
-- Animation: on the host a client's puppet is an "autonomous" pawn whose body pose the engine
-- only ticks on movement packets (which our client never sends for it) - frozen in one pose. And
-- the body's anim blueprint doesn't work out walking for players at all. So the host lets the
-- pose tick, and everyone feeds each such body its speed and direction (from how it moves).
---------------------------------------------------------------------------
S.bodies = {}   -- pawn full name -> { pawn, last, t, vx, vy }

local function otherBodies()
    local list = {}
    local mine = myPawn and myPawn() or nil
    local myPuppet = S.joined and S.client and S.client.puppet or nil
    for _, p in ipairs(S.allOf("/Script/CPPFPS.BasePlayer")) do
        if valid(p.PlayerState) and not same(p, mine) and not same(p, myPuppet) and not p.bHidden then
            table.insert(list, p)
        end
    end
    return list
end

-- How a player looks: exactly what they picked in their own game (safehouse outfit + clothes
-- colours). Every machine sends its player's outfit (PlayerBP.CurrentOutfit) and the four clothes
-- classes of the saved customization; the host passes them on to everyone. On the receiving side
-- the game's own functions dress that player's pawn (SetPlayerOutfit, "Apply Player Customization
-- Mats"); the game builds the full-body look in the pawn's ShadowMesh (used for its shadow), and
-- we put that mesh + materials on the visible body.
-- config.txt look=106 forces the Light 106 suit for everyone instead.
local MODEL_106 = "/Game/Character/NPC/Special/Light106/rig_Light106.rig_Light106"
local CUSTOM_KEYS = { "Arms_2_6E5167D6464C9E7A2C79509A707C6BB1", "Gloves_6_F9D6F0E04D1A5EB26E6660B1F83B1FF7",
                      "Pants_9_2E8B2CE7414E648840B7159876B65CFC", "Shoes_12_3AEBAAB5450DA86CA964D3BFB03767BB" }
S.looks = {}   -- player id -> { key = "outfit|a|g|p|s", outfit, classes = {4 paths} }

-- Our clothes colours exactly as the game worked them out here: the legs body's material (for the
-- customizable outfits it is a dynamic instance of the clothes material with the chosen tints and
-- camo). Sent as "parentPath;V,name,r,g,b,a;S,name,v;T,name,path" - the receiver rebuilds it.
local function objPath(o) return o:GetFullName():match("%s(.+)$") end
local function clothesMaterial(pawn)
    local out = ""
    pcall(function()
        local mt = pawn.MeshLegs:GetMaterial(0)
        if not valid(mt) or not mt:GetClass():GetFName():ToString():find("Dynamic") then return end
        local parent = mt.Parent
        if not valid(parent) or not parent:GetFName():ToString():find("CustomBase") then return end
        local list = { objPath(parent) }
        mt.VectorParameterValues:ForEach(function(_, el)
            local v = el:get(); local c = v.ParameterValue
            table.insert(list, string.format("V,%s,%.3f,%.3f,%.3f,%.3f", v.ParameterInfo.Name:ToString(), c.R, c.G, c.B, c.A))
        end)
        mt.ScalarParameterValues:ForEach(function(_, el)
            local v = el:get()
            table.insert(list, string.format("S,%s,%.3f", v.ParameterInfo.Name:ToString(), v.ParameterValue))
        end)
        mt.TextureParameterValues:ForEach(function(_, el)
            local v = el:get()
            if valid(v.ParameterValue) then table.insert(list, "T," .. v.ParameterInfo.Name:ToString() .. "," .. objPath(v.ParameterValue)) end
        end)
        -- The body never shows the jacket and gloves in single player (nobody sees it), so the game
        -- only colours them on the first-person arms. Carry those colours over to the body's zones:
        -- sleeves (camo layer 1) <- jacket colour + camo, arm patch (tint 01) <- jacket accent,
        -- torso (camo layer 3) <- inner shirt, gloves (tint 02) <- gloves colour.
        for i = 0, pawn.Mesh1P:GetNumMaterials() - 1 do
            local am = pawn.Mesh1P:GetMaterial(i)
            local pname = ""
            pcall(function() pname = am.Parent:GetFName():ToString() end)
            local vals, tex = {}, {}
            pcall(function()
                am.VectorParameterValues:ForEach(function(_, el)
                    local v = el:get(); vals[v.ParameterInfo.Name:ToString()] = v.ParameterValue
                end)
                am.TextureParameterValues:ForEach(function(_, el)
                    local v = el:get(); if valid(v.ParameterValue) then tex[v.ParameterInfo.Name:ToString()] = objPath(v.ParameterValue) end
                end)
            end)
            local function put(target, c)
                if c then table.insert(list, string.format("V,%s,%.3f,%.3f,%.3f,%.3f", target, c.R, c.G, c.B, c.A)) end
            end
            if pname:find("Arms_CustomBase") then
                put("Camo_01_Tint", vals["Color_Tint_01"])
                put("Color_Tint_01", vals["Color_Tint_02"])
                put("Camo_03_Tint", vals["Color_Tint_03"])
                put("Camo_01_UV", vals["Camo_01_UV"])
                if tex["Camo_01_Tex"] then table.insert(list, "T,Camo_01_Tex," .. tex["Camo_01_Tex"]) end
            elseif pname:find("Gloves_CustomBase") then
                put("Color_Tint_02", vals["Color_Tint_01"])
            end
        end
        out = table.concat(list, ";")
    end)
    return out
end

local function loadObj(path)
    local o = StaticFindObject(path)
    if not valid(o) and LoadAsset then pcall(function() o = LoadAsset(path) end) end
    return valid(o) and o or nil
end

-- rebuild a sent clothes material on the body
local function wearClothes(p, data)
    local parts = {}
    for part in data:gmatch("[^;]+") do table.insert(parts, part) end
    local parent = loadObj(parts[1] or "")
    if not parent then return false end
    local mid = p.Mesh:CreateDynamicMaterialInstance(0, parent, FName("T2CoopClothes", EFindName.FNAME_Add))
    if not valid(mid) then return false end
    for i = 2, #parts do
        local f = {}
        for x in parts[i]:gmatch("[^,]+") do table.insert(f, x) end
        local name = FName(f[2] or "", EFindName.FNAME_Add)
        if f[1] == "V" then
            mid:SetVectorParameterValue(name, { R = tonumber(f[3]) or 0, G = tonumber(f[4]) or 0, B = tonumber(f[5]) or 0, A = tonumber(f[6]) or 1 })
        elseif f[1] == "S" then
            mid:SetScalarParameterValue(name, tonumber(f[3]) or 0)
        elseif f[1] == "T" then
            local tex = loadObj(f[3] or "")
            if tex then mid:SetTextureParameterValue(name, tex) end
        end
    end
    return true
end

local function myLook(pawn)
    local outfit = 0
    pcall(function() outfit = pawn.CurrentOutfit end)
    local parts = {}
    pcall(function()
        local c = {}
        FindFirstOf("GameInstanceBP_C"):GetSavedPlayerCustomization(c)
        for i, k in ipairs(CUSTOM_KEYS) do
            local v = c[k]
            parts[i] = (valid(v) and v:GetFullName():match("%s(.+)$")) or ""   -- v is the class itself
        end
    end)
    for i = 1, 4 do parts[i] = parts[i] or "" end
    return tostring(outfit) .. "|" .. table.concat(parts, "|") .. "|" .. clothesMaterial(pawn) .. "|" .. (S.mySkin or "")
end
S.myLook = myLook

-- the visible body takes the full-body look the game built: the shadow body for special outfits,
-- the coloured clothes (on the legs body, see wearLook) for the customizable ones
local function copyShadowLook(p, src)
    local sh, mesh = src or p.ShadowMesh, p.Mesh
    local m = sh.SkeletalMesh
    if not valid(m) then return end
    if not same(mesh.SkeletalMesh, m) then mesh:SetSkeletalMesh(m, false) end
    for i = 0, sh:GetNumMaterials() - 1 do
        local mat = sh:GetMaterial(i)
        if valid(mat) and not same(mesh:GetMaterial(i), mat) then mesh:SetMaterial(i, mat) end
    end
end

local function wearForced106(p)
    local m = StaticFindObject(MODEL_106)
    if not valid(m) and LoadAsset then pcall(function() m = LoadAsset(MODEL_106) end) end
    if not valid(m) or same(p.Mesh.SkeletalMesh, m) then return end
    p.Mesh:SetSkeletalMesh(m, false)
    for i = 1, #m.Materials do pcall(function() p.Mesh:SetMaterial(i - 1, m.Materials[i].MaterialInterface) end) end
end

-- dress body pawn p in the look sent for its player (once per change); then mirror the shadow body
-- Enemy outfits: a player can look like one of the game's enemy factions (F4 menu, config skin=).
-- Each machine spawns, for such a player, a real NPC of that faction as a "costume": no AI (not
-- possessed), no collision, no tick, not replicated, marked dead so nothing counts or targets it.
-- The game dresses it like any enemy of its kind (body, materials, helmet, armour). Its body is
-- put on the player's body and copies its pose bone for bone (master pose); the player's own body
-- is hidden. The costume's own gun is removed (the player's gun stays in the hand).
S.SKINS = {
    { id = "mallcop",   name = "Mall Cop",         cls = "/Game/Character/NPC/Human/Type/Blue/NPC_MallCop_Pistol.NPC_MallCop_Pistol_C" },
    { id = "cultist",   name = "Cultist",          cls = "/Game/Character/NPC/Human/Type/Cultist/NPC_CultistSMG.NPC_CultistSMG_C" },
    { id = "captain",   name = "Cultist Captain",  cls = "/Game/Character/NPC/Human/Type/Cultist/Captain/NPC_CultistCaptain_NonBoss.NPC_CultistCaptain_NonBoss_C" },
    { id = "guard",     name = "Horizon Guard",    cls = "/Game/Character/NPC/Human/Type/Blue/NPC_Guard_Rifle.NPC_Guard_Rifle_C" },
    { id = "elite",     name = "Horizon Elite",    cls = "/Game/Character/NPC/Human/Type/Blue/NPC_GuardElite.NPC_GuardElite_C" },
    { id = "ttmf",      name = "TTMF (NVG)",       cls = "/Game/Character/NPC/Human/Type/Blue/NPC_GuardElite_NVG.NPC_GuardElite_NVG_C" },
    { id = "ttmf2",     name = "TTMF Guard (NVG)", cls = "/Game/Character/NPC/Human/Type/Blue/NPC_Guard_NVG_SMG.NPC_Guard_NVG_SMG_C" },
    { id = "blackops",  name = "Black Ops",        cls = "/Game/Character/NPC/Human/Type/Blue/NPC_Guard_BlackOps.NPC_Guard_BlackOps_C" },
    { id = "bulldozer", name = "Bulldozer",        cls = "/Game/Character/NPC/Human/Type/Blue/NPC_Bulldozer_Rifle.NPC_Bulldozer_Rifle_C" },
    { id = "hazmat",    name = "Hazmat",           cls = "/Game/Character/NPC/Human/Type/Blue/Site83_Mothman/NPC_Site83_Hazmat_SL8.NPC_Site83_Hazmat_SL8_C" },
    { id = "biologist", name = "Biologist",        cls = "/Game/Character/NPC/Human/Type/Blue/Creepers/NPC_Biologist_SMG.NPC_Biologist_SMG_C" },
    { id = "hecu",      name = "HECU",             cls = "/Game/Character/NPC/Human/Type/Blue/HECU/NPC_HECU_AR1.NPC_HECU_AR1_C" },
    { id = "lawyer",    name = "Lawyer Thug",      cls = "/Game/Character/NPC/Human/Type/Blue/LawyerThugs/NPC_LawyerThugRifle.NPC_LawyerThugRifle_C" },
    { id = "bodyguard", name = "Bodyguard",        cls = "/Game/Character/NPC/Human/Type/Bodyguard/NPC_Bodyguard_Rifle.NPC_Bodyguard_Rifle_C" },
    { id = "corsair",   name = "Corsair",          cls = "/Game/Character/NPC/Human/Type/Blue/Corsair/NPC_Corsair_AR1.NPC_Corsair_AR1_C" },
    { id = "bandit",    name = "Bandit",           cls = "/Game/Character/NPC/Human/Type/Blue/BadOil/Bandit/NPC_Bandit_AR1.NPC_Bandit_AR1_C" },
    { id = "outlaw",    name = "Outlaw",           cls = "/Game/Character/NPC/Human/Type/Blue/BadOil/Outlaw/NPC_Outlaw_AR1.NPC_Outlaw_AR1_C" },
    { id = "rigworker", name = "Rig Worker",       cls = "/Game/Character/NPC/Human/Type/Blue/HECU/NPC_RigWorker_SMG.NPC_RigWorker_SMG_C" },
}
-- Every enemy kind in the game, found in its files (NPC_* classes), grouped by faction. Civilians,
-- test/scripted/cutscene copies and creatures with another skeleton are left out. An entry's id is
-- its class path (that's what is saved in config.txt and sent to the others).
local CAT_SKIP = { "Base$", "Base_", "_Base", "VHS", "CSS_", "TMOD", "Bullseye", "Cutscene", "Scripted", "Tut",
    "Test", "Civilian", "Nurse", "Hostage", "Dummy", "Zoo", "Mothman", "Golem", "Peeker", "Zombie", "Whisperer",
    "Drone", "Turret", "Heli", "Betrayal", "Decoy", "Ragdoll", "Corpse", "Template", "Rat" }
local FACTION_NAMES = { Green = "Mercs", Red = "Replicas", Mall = "Mall Cops", Dark106 = "107", CheapAI = "Guard",
    Guard = "Horizon", HVT = "HVT & bosses", BadOil = "Bad Oil",
    Site83_Mothman = "Site 83", Amnesty = "Amnesty", Creepers = "Creepers", LawyerThugs = "Lawyer Thugs",
    MonolithSlave = "Monolith", Moth = "Moth cult", Jiggly = "Jigglyboi", British = "British" }
function S.catalog()
    if S.cat then return S.cat end
    local AR = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers"):GetAssetRegistry()
    local found = {}
    for _, dir in ipairs({ "/Game/Character/NPC", "/Game/Blueprint/HVT", "/Game/AssetPack" }) do
        local arr = {}
        pcall(function() AR:GetAssetsByPath(FName(dir, EFindName.FNAME_Add), arr, true, false) end)
        for _, a in ipairs(arr) do
            pcall(function()
                local x = a:get()
                local n = x.AssetName:ToString()
                if x.AssetClass:ToString() == "BlueprintGeneratedClass" and n:match("^NPC_") then
                    local skip = false
                    for _, pat in ipairs(CAT_SKIP) do if n:find(pat) then skip = true break end end
                    if not skip then found[x.ObjectPath:ToString()] = n end
                end
            end)
        end
    end
    local groups = {}
    for path, n in pairs(found) do
        local name = n:gsub("^NPC_", ""):gsub("_C$", "")
        local fac
        if path:find("/HVT/") then fac = "HVT"
        else
            local after = path:match("/Type/(.+)/[^/]+$")
            if after then
                after = after:gsub("^Blue/?", "")
                fac = after:match("^([^/]+)")
            end
            fac = fac or name:match("^([A-Z][a-z]+)") or "Other"
        end
        fac = FACTION_NAMES[fac] or fac
        groups[fac] = groups[fac] or {}
        table.insert(groups[fac], { id = path, name = name:gsub("_", " ") })
    end
    local cat = {}
    for fac, list in pairs(groups) do
        table.sort(list, function(a, b) return a.name < b.name end)
        table.insert(cat, { name = fac, list = list })
    end
    table.sort(cat, function(a, b) return a.name < b.name end)
    S.cat = cat
    local n = 0
    for _, g in ipairs(cat) do n = n + #g.list end
    log("enemy looks: " .. n .. " in " .. #cat .. " factions")
    return cat
end
-- faction / variant index of a skin id (0, 0 = safehouse outfit)
function S.lookIndex(id)
    if not id or id == "" then return 0, 0 end
    for fi, g in ipairs(S.catalog()) do
        for vi, e in ipairs(g.list) do if e.id == id then return fi, vi end end
    end
    return 0, 0
end
S.badSkin = {}
local function skinById(id)
    if not id or id == "" or S.badSkin[id] then return nil end
    for _, k in ipairs(S.SKINS) do if k.id == id then return k end end
    if id:find("/") then
        for _, g in ipairs(S.catalog()) do
            for _, e in ipairs(g.list) do if e.id == id then return { id = e.id, name = e.name, cls = e.id } end end
        end
        return { id = id, name = (id:match("NPC_([^%.]+)%.") or id), cls = id }
    end
end
S.skinById = skinById
S.costumes = {}       -- body full name -> { actor, id }
S.costumeSet = {}     -- costume actor full name -> true

local function removeCostume(p)
    local key = p:GetFullName()
    local c = S.costumes[key]
    if not c then return end
    S.costumes[key] = nil
    if valid(c.actor) then
        S.costumeSet[c.actor:GetFullName()] = nil
        pcall(function() c.actor:K2_DestroyActor() end)
    end
    pcall(function() p.Mesh:SetHiddenInGame(false, false) end)
end
S.removeCostume = removeCostume

local function wearCostume(p, id)
    local key = p:GetFullName()
    local c = S.costumes[key]
    if c and c.id == id and valid(c.actor) then
        pcall(function() if not p.Mesh.bHiddenInGame then p.Mesh:SetHiddenInGame(true, false) end end)
        return true
    end
    removeCostume(p)
    local skin = skinById(id)
    if not skin then return false end
    local cls = loadObj(skin.cls)
    if not cls then log("enemy outfit " .. id .. ": class not found") return false end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local l = p:K2_GetActorLocation()
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = l.X, Y = l.Y, Z = l.Z - 5000 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local a = GS:BeginDeferredActorSpawnFromClass(world(), cls, xf, 1, nil)
    if not valid(a) then return false end
    pcall(function() a.AutoPossessAI = 0 end)          -- no AI controller
    pcall(function() a.bReplicates = false end)
    pcall(function() a.bOnlyRelevantToOwner = true end)   -- no owner: never sent to anyone
    S.costumeSet[a:GetFullName()] = true
    GS:FinishSpawningActor(a, xf)
    pcall(function() a:SetActorEnableCollision(false) end)
    pcall(function() a:SetActorTickEnabled(false) end)
    pcall(function() a.bIsDead = true end)
    pcall(function() a.CharacterMovement:SetComponentTickEnabled(false) end)
    -- its own guns go
    for _, w in ipairs(S.allOf("/Script/CPPFPS.BaseWeapon")) do
        local ok, own = pcall(function() return same(w.Owner, a) end)
        if ok and own then pcall(function() w:K2_DestroyActor() end) end
    end
    local okSk, sameSk = pcall(function() return same(a.Mesh.SkeletalMesh.Skeleton, p.Mesh.SkeletalMesh.Skeleton) end)
    if okSk and not sameSk then
        log("enemy outfit " .. id .. ": other skeleton - not usable")
        S.badSkin[id] = true
        pcall(function() a:K2_DestroyActor() end)
        return false
    end
    -- its body onto the player's, following the player's pose
    pcall(function()
        a.Mesh:K2_AttachToComponent(p.Mesh, FName("None", EFindName.FNAME_Add), 2, 2, 2, false)
        a.Mesh:SetMasterPoseComponent(p.Mesh, true)
    end)
    pcall(function() p.Mesh:SetHiddenInGame(true, false) end)
    S.costumes[key] = { actor = a, id = id }
    log("dressed " .. p:GetFName():ToString() .. " as " .. skin.name)
    return true
end

-- Look preview for the F4 menu: the chosen look on a slowly turning figure next to the panel.
-- The figure stands where we stand but is visible ONLY to a scene-capture camera (not in the
-- world); the camera renders just that figure into a texture shown by an Image in the menu.
-- Enemy outfits: a tame NPC of that faction (like a costume). Safehouse look: our own full body
-- (the shadow body's mesh with the clothes material the game made for us).
S.preview = {}
-- preview lights: offset from the figure (X towards the camera) and brightness; exposure bias of the camera
S.pvTune = { lights = { { 380, 160, 110, 170000 }, { 380, -200, 20, 110000 }, { 420, 0, -40, 70000 },
    { -260, 120, 150, 150000 }, { -260, -150, 60, 100000 } }, radius = 1500, bias = 0,
    wall = { X = 0.15, Y = 0.15, Z = 0.16 } }
local function spawnTameNPC(cls, loc)
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = loc, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local a = GS:BeginDeferredActorSpawnFromClass(world(), cls, xf, 1, nil)
    if not valid(a) then return nil end
    pcall(function() a.AutoPossessAI = 0 end)
    pcall(function() a.bReplicates = false end)
    pcall(function() a.bOnlyRelevantToOwner = true end)   -- no owner: never sent to anyone
    S.costumeSet[a:GetFullName()] = true
    GS:FinishSpawningActor(a, xf)
    pcall(function() a:SetActorEnableCollision(false) end)
    pcall(function() a.CharacterMovement:SetComponentTickEnabled(false) end)
    pcall(function() a.CharacterMovement:SetMovementMode(0, 0) end)   -- no falling
    for _, w in ipairs(S.allOf("/Script/CPPFPS.BaseWeapon")) do
        local ok, own = pcall(function() return same(w.Owner, a) end)
        if ok and own then pcall(function() w:K2_DestroyActor() end) end
    end
    return a
end

local function previewFigure(skinId, loc)
    local skin = skinById(skinId)
    if skin then
        local cls = loadObj(skin.cls)
        return cls and spawnTameNPC(cls, loc) or nil
    end
    -- safehouse look: a plain skeletal mesh actor wearing our full body
    local pc = localPC()
    local pawn = S.joined and S.client and S.client.pawn or (valid(pc) and pc.Pawn)
    if not valid(pawn) then return nil end
    local a = world():SpawnActor(StaticFindObject("/Script/Engine.SkeletalMeshActor"), loc, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(a) then return nil end
    local m = a.SkeletalMeshComponent
    local src = pawn.ShadowMesh
    pcall(function() m:SetSkeletalMesh(src.SkeletalMesh, false) end)
    -- customizable outfit: the legs body carries the clothes colours the game made for us
    local useLegs = false
    pcall(function() useLegs = pawn.MeshLegs:GetMaterial(0):GetClass():GetFName():ToString():find("Dynamic") ~= nil and same(pawn.MeshLegs.SkeletalMesh, src.SkeletalMesh) end)
    local mats = useLegs and pawn.MeshLegs or src
    for i = 0, mats:GetNumMaterials() - 1 do pcall(function() m:SetMaterial(i, mats:GetMaterial(i)) end) end
    local drvCls = loadObj("/Game/Character/NPC/Human/Type/Blue/BadOil/Bandit/NPC_Bandit_AR1.NPC_Bandit_AR1_C")
    local drv = drvCls and spawnTameNPC(drvCls, loc)
    if valid(drv) then
        for _, c in ipairs(drv:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))) do
            c = c.get and c:get() or c
            pcall(function() c:SetVisibleInSceneCaptureOnly(true) end)   -- not shown anywhere
            pcall(function() c:SetCastShadow(false) end)
        end
        pcall(function() drv.Mesh.VisibilityBasedAnimTickOption = 0 end)
        pcall(function() m:SetMasterPoseComponent(drv.Mesh, true) end)
        S.preview.driver = drv
    else
        pcall(function() m:SetAnimInstanceClass(pawn.Mesh.AnimClass) end)
    end
    S.preview.zoff = -90   -- the mesh is the actor's root: feet at the actor's origin
    return a
end

function S.previewDestroy()
    local pv = S.preview
    for _, k in ipairs({ "figure", "cam", "driver", "backdrop" }) do
        if valid(pv[k]) then pcall(function() pv[k]:K2_DestroyActor() end) end
        pv[k] = nil
    end
    for _, l in ipairs(pv.lights or {}) do
        if valid(l.actor) then pcall(function() l.actor:K2_DestroyActor() end) end
    end
    pv.lights = {}
    pv.skin = nil
    if valid(pv.image) then pcall(function() pv.image:SetRenderOpacity(0) end) end
end

-- keep the preview in step with S.mySkin; called while the menu is open
function S.previewUpdate(image)
    local pv = S.preview
    pv.image = image or pv.image
    local pc = localPC()
    if not valid(pc) or not valid(pc.Pawn) or not valid(pv.image) then return end
    local want = S.mySkin or ""
    if pv.skin ~= want or not valid(pv.figure) or not valid(pv.cam) then
        S.previewDestroy()
        pv.skin = want
        pv.zoff = 0
        local base = pc.Pawn:K2_GetActorLocation()
        local figure = previewFigure(want, base)
        if not figure then return end
        local okSk, sameSk = pcall(function() return same(figure.Mesh.SkeletalMesh.Skeleton, pc.Pawn.Mesh.SkeletalMesh.Skeleton) end)
        if want ~= "" and okSk and not sameSk then
            S.badSkin[want] = true
            pcall(function() figure:K2_DestroyActor() end)
            return
        end
        -- only the preview camera sees it
        for _, c in ipairs(figure:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))) do
            c = c.get and c:get() or c
            pcall(function() c:SetVisibleInSceneCaptureOnly(true) end)
            pcall(function() c:SetCastShadow(false) end)
            pcall(function() c:SetLightingChannels(true, true, false) end)
            pcall(function() c.VisibilityBasedAnimTickOption = 0 end)
        end
        -- its own lights (key + fill + rim) on lighting channel 1: they light the figure, not the world
        pv.lights = {}
        for _, L in ipairs(S.pvTune.lights) do
            pcall(function()
                local la = world():SpawnActor(StaticFindObject("/Script/Engine.PointLight"), base, { Pitch = 0, Yaw = 0, Roll = 0 })
                local lc = la.PointLightComponent
                lc:SetMobility(2)   -- spawned lights are stationary: they would stay inside the figure
                lc:SetLightingChannels(false, true, false)
                lc:SetIntensity(L[4])
                lc:SetAttenuationRadius(S.pvTune.radius)
                lc:SetCastShadows(false)
                table.insert(pv.lights, { actor = la, off = L })
            end)
        end
        local KRL = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
        pv.rt = pv.rt or KRL:CreateRenderTarget2D(world(), 300, 450, 2, { R = 0.02, G = 0.02, B = 0.02, A = 1 }, false)
        local cam = world():SpawnActor(StaticFindObject("/Script/Engine.SceneCapture2D"), base, { Pitch = 0, Yaw = 0, Roll = 0 })
        local cc = cam.CaptureComponent2D
        cc.TextureTarget = pv.rt
        cc.PrimitiveRenderMode = 2          -- show-only list
        cc.CaptureSource = 2                -- final colour (LDR)
        cc.bCaptureEveryFrame = true
        cc.FOVAngle = 36
        -- fixed exposure: the dark level around must not darken the picture
        pcall(function()
            local pp = cc.PostProcessSettings
            pp.bOverride_AutoExposureMethod = true
            pp.AutoExposureMethod = 0
            pp.bOverride_AutoExposureMinBrightness = true
            pp.AutoExposureMinBrightness = 1
            pp.bOverride_AutoExposureMaxBrightness = true
            pp.AutoExposureMaxBrightness = 1
            pp.bOverride_AutoExposureBias = true
            pp.AutoExposureBias = S.pvTune.bias
            pp.bOverride_VignetteIntensity = true
            pp.VignetteIntensity = 0
            cc.PostProcessBlendWeight = 1
        end)
        cc:ShowOnlyActorComponents(figure, true)
        pcall(function()
            local bd = world():SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"),
                { X = base.X - 150, Y = base.Y, Z = base.Z + 5 }, { Pitch = 0, Yaw = 0, Roll = 0 })
            local sm = bd.StaticMeshComponent
            sm:SetMobility(2)
            sm:SetStaticMesh(loadObj("/Engine/BasicShapes/Cube.Cube"))
            bd:SetActorScale3D({ X = 0.05, Y = 6, Z = 7 })
            bd:SetActorEnableCollision(false)
            sm:SetVisibleInSceneCaptureOnly(true)
            sm:SetCastShadow(false)
            -- a plain unlit engine material: an even grey, the same for every look
            local mat = loadObj("/Engine/EngineDebugMaterials/DebugMeshMaterial.DebugMeshMaterial")
            if mat then sm:SetMaterial(0, mat) end
            sm:SetVectorParameterValueOnMaterials(FName("Color", EFindName.FNAME_Add), S.pvTune.wall)
            pv.backdrop = bd
            cc:ShowOnlyActorComponents(bd, true)
        end)
        pv.figure, pv.cam, pv.base, pv.yaw = figure, cam, base, 200
        pcall(function() pv.image:SetBrushResourceObject(pv.rt) end)
        pcall(function() pv.image:SetRenderOpacity(1) end)
    end
end

-- turn the figure slowly; the camera stays in front of it
S.every(0, function(dt)
    local pv = S.preview
    if not valid(pv.figure) or not valid(pv.cam) then return end
    pv.yaw = (pv.yaw + (dt or 30) * 0.045) % 360
    local b = pv.base
    pcall(function() pv.figure:K2_SetActorLocationAndRotation({ X = b.X, Y = b.Y, Z = b.Z + (pv.zoff or 0) }, { Pitch = 0, Yaw = pv.yaw, Roll = 0 }, false, {}, true) end)
    pcall(function()
        pv.cam:K2_SetActorLocationAndRotation({ X = b.X + 260, Y = b.Y, Z = b.Z + 5 }, { Pitch = -1, Yaw = 180, Roll = 0 }, false, {}, true)
    end)
    for _, l in ipairs(pv.lights or {}) do
        pcall(function() l.actor:K2_SetActorLocation({ X = b.X + l.off[1], Y = b.Y + l.off[2], Z = b.Z + l.off[3] }, false, {}, true) end)
    end
end)

local function wearLook(p)
    local look = S.looks[S.pidOf(p) or -2]
    if look and look.skin and look.skin ~= "" and skinById(look.skin) then
        if wearCostume(p, look.skin) then return end
    elseif S.costumes[p:GetFullName()] then
        removeCostume(p)
        if S.dressed then S.dressed[p:GetFullName()] = nil end
    end
    if (S.cfgModel or "player") == "106" then return wearForced106(p) end
    local key = p:GetFullName()
    S.dressed = S.dressed or {}
    S.dressSrc = S.dressSrc or {}
    if look and S.dressed[key] ~= look.key then
        S.dressed[key] = look.key
        pcall(function() p:SetPlayerOutfit(look.outfit) end)   -- builds the full body in ShadowMesh
        local clothes = false
        if look.mat and look.mat ~= "" then
            -- customizable outfit: the shadow body's mesh, with the sender's coloured clothes material
            pcall(function()
                local m = p.ShadowMesh.SkeletalMesh
                if not same(p.Mesh.SkeletalMesh, m) then p.Mesh:SetSkeletalMesh(m, false) end
            end)
            local ok, res = pcall(wearClothes, p, look.mat)
            clothes = ok and res
        end
        S.dressSrc[key] = clothes and "clothes" or "ShadowMesh"
        log("dressed " .. p:GetFName():ToString() .. " as outfit " .. look.outfit)
    end
    if S.dressSrc[key] ~= "clothes" then copyShadowLook(p, p.ShadowMesh) end
end

handlers.server["CU"] = function(pc, p)
    local pid = S.pidOf(pc.Pawn)
    if not pid then return end
    local key = table.concat({ p[1] or "0", p[2] or "", p[3] or "", p[4] or "", p[5] or "", p[6] or "", p[7] or "" }, "|")
    S.looks[pid] = { key = key, outfit = tonumber(p[1]) or 0, classes = { p[2] or "", p[3] or "", p[4] or "", p[5] or "" }, mat = p[6] or "", skin = p[7] or "" }
end
handlers.client["CU"] = function(_, p)
    local pid = tonumber(p[1])
    if not pid then return end
    local key = table.concat({ p[2] or "0", p[3] or "", p[4] or "", p[5] or "", p[6] or "", p[7] or "", p[8] or "" }, "|")
    S.looks[pid] = { key = key, outfit = tonumber(p[2]) or 0, classes = { p[3] or "", p[4] or "", p[5] or "", p[6] or "" }, mat = p[7] or "", skin = p[8] or "" }
end
-- every 2 s: our own look (and, on the host, everybody's) - cheap, and covers late joiners
S.every(2000, function()
    if not netDriver() then return end
    if S.joined then
        local pawn = S.client and S.client.pawn
        if valid(pawn) then S.toServer("CU", myLook(pawn)) end
    elseif S.hosting then
        local pc = localPC()
        if not valid(pc) or not valid(pc.Pawn) or #(FindAllOf("PlayerController") or {}) < 2 then return end
        S.toClients("CU", S.pidOf(pc.Pawn) or -1, myLook(pc.Pawn))
        for pid, look in pairs(S.looks) do S.toClients("CU", pid, look.key) end
    end
end)

local function showAsThirdPerson(p)
    pcall(wearLook, p)
    -- the visible body casts the shadow now; the shadow-only copy would make a second one
    pcall(function() if p.ShadowMesh.bCastHiddenShadow then p.ShadowMesh:SetCastHiddenShadow(false) end end)
    if not S.costumes[p:GetFullName()] then
        pcall(function()
            if p.Mesh.bHiddenInGame then p.Mesh:SetHiddenInGame(false, false) end
            if not p.Mesh:IsVisible() then p.Mesh:SetVisibility(true, false) end
        end)
    end
    for _, k in ipairs({ "MeshLegs", "Mesh1P", "Mesh1P2" }) do
        pcall(function() local c = p[k]; if valid(c) and c:IsVisible() then c:SetVisibility(false, false) end end)
    end
    if S.hosting then
        pcall(function() if p.Mesh.bOnlyAllowAutonomousTickPose then p.Mesh.bOnlyAllowAutonomousTickPose = false end end)
    end
    local w = p.CurrentWeapon
    if not valid(w) then return end
    -- a gun in someone's hands must not offer "pick up" to the others
    pcall(function() if w:GetActorEnableCollision() then w:SetActorEnableCollision(false) end end)
    for _, k in ipairs({ "Mesh1P", "Mesh1P2" }) do
        pcall(function() local c = w[k]; if valid(c) and c:IsVisible() then c:SetVisibility(false, false) end end)
    end
    pcall(function()
        local m3 = w.Mesh3P
        if not same(m3:GetAttachParent(), p.Mesh) then
            m3:K2_AttachToComponent(p.Mesh, FName("hand_r_align", EFindName.FNAME_Add), 0, 0, 0, false)
        end
        if not m3:IsVisible() then m3:SetVisibility(true, false) end
    end)
end

S.every(250, function()
    if not (S.hosting or S.joined) or not netDriver() then S.bodies = {} return end
    local seen = {}
    for _, p in ipairs(otherBodies()) do
        showAsThirdPerson(p)
        local key = p:GetFullName()
        seen[key] = true
        S.bodies[key] = S.bodies[key] or { pawn = p, vx = 0, vy = 0 }
    end
    for k, c in pairs(S.costumes) do
        if not seen[k] then
            if valid(c.actor) then pcall(function() c.actor:K2_DestroyActor() end) end
            S.costumes[k] = nil
        end
    end
    for k, e in pairs(S.bodies) do
        if not seen[k] then
            if e.dualGun then pcall(function() e.dualGun:K2_DestroyActor() end) end
            S.bodies[k] = nil
        end
    end
    -- client: the host's pawn (placed in the level) also made itself a local gun here when the map
    -- loaded; the real one comes from the host. Hide those local extras (a second gun in the hand).
    -- Same for the guns of our own hidden puppet (they floated where the puppet stands).
    if S.joined then
        local puppet = S.client and S.client.puppet
        local pname = valid(puppet) and puppet:GetFullName() or nil
        for _, w in ipairs(S.allOf("/Script/CPPFPS.BaseWeapon")) do
            if not w.bHidden then
                local ok, owner = pcall(function() return w.Owner:GetFullName() end)
                if ok and ((w.Role == 3 and seen[owner]) or owner == pname) then
                    pcall(function() w:SetActorHiddenInGame(true) end)
                end
            end
        end
    end
end)

-- Every frame (our heartbeat): speed and direction from how the body moved. The blueprint never
-- writes these fields for players, so values set here stay. (Not a hook on the anim blueprint's
-- update: that runs thousands of times a second for all characters and crashed UE4SS.)
local function feedBody(e)
    local ai = e.pawn.Mesh.AnimScriptInstance
    if not valid(ai) then return end
    local root = e.pawn.RootComponent
    local l = root.RelativeLocation
    local now = os.clock()
    if not e.last then e.last, e.t = { X = l.X, Y = l.Y }, now return end
    local dx, dy = l.X - e.last.X, l.Y - e.last.Y
    if dx * dx + dy * dy > 0.01 then
        -- positions arrive in steps (20 per second): velocity over the time since the last step
        local span = math.max(now - e.t, 0.016)
        local vx, vy = dx / span, dy / span
        if vx * vx + vy * vy > 1200 * 1200 then vx, vy = 0, 0 end   -- a teleport, not a step
        e.vx, e.vy = e.vx * 0.5 + vx * 0.5, e.vy * 0.5 + vy * 0.5
        e.last, e.t = { X = l.X, Y = l.Y }, now
    elseif now - e.t > 0.25 then
        e.vx, e.vy = e.vx * 0.6, e.vy * 0.6
    end
    local speed = math.sqrt(e.vx * e.vx + e.vy * e.vy)
    if speed < 15 then speed = 0 end
    local yaw = math.rad(root.RelativeRotation.Yaw)
    local fwd = e.vx * math.cos(yaw) + e.vy * math.sin(yaw)
    local right = -e.vx * math.sin(yaw) + e.vy * math.cos(yaw)
    local dir = speed > 0 and math.deg(math.atan(right, fwd)) or 0
    ai.Speed = speed
    ai.PlanarVelocity = speed
    ai.Direction = dir
    ai.Moving = speed > 0
    ai.LastMoveSpeed = speed
    if speed > 0 then ai.LastMoveDirection = dir end
end
-- Full animation state. Every player's own legs-only body (MeshLegs) runs the real third-person
-- anim logic for that player on their machine: crouch, slide, sprint, jump, kick... Each machine
-- sends that state (15 per second); the host passes everyone's on to the clients; every machine
-- writes it into that player's full body. Motion-based speed above is only the fallback.
local AF = { Moving = 1, Crouching = 2, IsSliding = 4, Jumping = 8, IsOnGround = 16, IsKicking = 32,
             IsWeaponLowered = 64, bIsMeleeMode = 128 }
local SPRINT_BIT = 256
local DUAL_BIT = 512
local DROPKICK_BIT = 1024
local function readAnimState(p)
    local ai = p.MeshLegs.AnimScriptInstance
    local flags = 0
    for k, bit in pairs(AF) do if ai[k] then flags = flags | bit end end
    local ok, sprint = pcall(function() return p:GetIsSprinting() end)
    if ok and sprint then flags = flags | SPRINT_BIT end
    local okd, dual = pcall(function() return p.CurrentWeapon:GetIsDualWielding() end)
    if okd and dual then flags = flags | DUAL_BIT end
    if p.IsDropkicking then flags = flags | DROPKICK_BIT end
    local pitch = 0
    pcall(function()
        pitch = p.Controller:GetControlRotation().Pitch
        if pitch > 180 then pitch = pitch - 360 end
    end)
    return string.format("%.0f|%.0f|%d|%d|%d|%.2f|%.0f", ai.Speed, ai.Direction, flags, ai.Stance, ai.LeanStatus, ai.AirDuration, pitch)
end
local function parseAnimState(p, i)
    return { speed = tonumber(p[i]) or 0, dir = tonumber(p[i + 1]) or 0, flags = tonumber(p[i + 2]) or 16,
             stance = tonumber(p[i + 3]) or 0, lean = tonumber(p[i + 4]) or 0, air = tonumber(p[i + 5]) or 0,
             pitch = tonumber(p[i + 6]) or 0,
             raw = table.concat({ p[i], p[i + 1], p[i + 2], p[i + 3], p[i + 4], p[i + 5], p[i + 6] or "0" }, "|"), t = os.clock() }
end
local function applyAnimState(ai, st)
    for k, bit in pairs(AF) do ai[k] = (st.flags & bit) ~= 0 end
    ai.Speed = st.speed
    ai.PlanarVelocity = st.speed
    ai.Direction = st.dir
    ai.Stance = st.stance
    ai.LeanStatus = st.lean
    ai.AirDuration = st.air
    -- where they look: the body's aim pose follows the player's view pitch
    pcall(function() ai.AimPitch = st.pitch; ai.AimPitchTarget = st.pitch end)
    pcall(function() ai.IsDropkicking = (st.flags & DROPKICK_BIT) ~= 0 end)
    ai.LastMoveSpeed = st.speed
    if st.speed > 0 then ai.LastMoveDirection = st.dir end
    -- the native part of the anim instance keeps its own copy of these
    pcall(function()
        ai.Char_IsMoving = (st.flags & AF.Moving) ~= 0
        ai.Char_IsCrouching = (st.flags & AF.Crouching) ~= 0
        ai.Char_IsSliding = (st.flags & AF.IsSliding) ~= 0
        ai.Char_IsGrounded = (st.flags & AF.IsOnGround) ~= 0
        ai.Char_IsSprinting = (st.flags & SPRINT_BIT) ~= 0
    end)
end
S.animState = {}   -- player id -> state

S.every(66, function()
    if not netDriver() then return end
    if S.joined then
        local p = S.client and S.client.pawn
        if valid(p) then pcall(function() S.toServer("AS", readAnimState(p)) end) end
    elseif S.hosting then
        local pc = localPC()
        if not valid(pc) or not valid(pc.Pawn) then return end
        local list = FindAllOf("PlayerController") or {}
        if #list < 2 then return end
        pcall(function() S.toClients("AS", pidOf(pc.Pawn) or -1, readAnimState(pc.Pawn)) end)
        for pid, st in pairs(S.animState) do
            if os.clock() - st.t < 1 then S.toClients("AS", pid, st.raw) end
        end
    end
end)
handlers.server["AS"] = function(pc, p)
    local pid = pidOf(pc.Pawn)
    if pid then S.animState[pid] = parseAnimState(p, 1) end
end
handlers.client["AS"] = function(_, p)
    local pid = tonumber(p[1])
    if pid then S.animState[pid] = parseAnimState(p, 2) end
end

-- Dual wielding: the third-person body holds one gun; for a partner with two, a look-only copy of
-- the gun (no collision, not replicated) goes into the left hand.
local function updateDualGun(e, dual)
    local w = e.pawn.CurrentWeapon
    local cls = valid(w) and w:GetClass() or nil
    if e.dualGun and (not dual or not valid(e.dualGun) or not same(e.dualGun:GetClass(), cls)) then
        pcall(function() e.dualGun:K2_DestroyActor() end)
        e.dualGun = nil
    end
    if not dual or e.dualGun or not cls then return end
    local g = world():SpawnActor(cls, e.pawn:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(g) then return end
    pcall(function() g:SetReplicates(false) end)
    pcall(function() g:SetActorEnableCollision(false) end)
    for _, k in ipairs({ "Mesh1P", "Mesh1P2" }) do
        pcall(function() local c = g[k]; if valid(c) then c:SetVisibility(false, false) end end)
    end
    pcall(function()
        g.Mesh3P:K2_AttachToComponent(e.pawn.Mesh, FName("hand_l_align", EFindName.FNAME_Add), 0, 0, 0, false)
        g.Mesh3P:SetVisibility(true, false)
    end)
    e.dualGun = g
end
S.every(250, function()
    for _, e in pairs(S.bodies) do
        if valid(e.pawn) then
            local st = S.animState[pidOf(e.pawn) or -2]
            local dual = st and os.clock() - st.t < 1 and (st.flags & DUAL_BIT) ~= 0
            pcall(updateDualGun, e, dual)
        elseif e.dualGun then
            pcall(function() e.dualGun:K2_DestroyActor() end)
            e.dualGun = nil
        end
    end
end)

S.every(0, function()
    for _, e in pairs(S.bodies) do
        if valid(e.pawn) then
            local st = S.animState[pidOf(e.pawn) or -2]
            if st and os.clock() - st.t < 0.6 then
                pcall(function() applyAnimState(e.pawn.Mesh.AnimScriptInstance, st) end)
            else
                pcall(feedBody, e)
            end
        end
    end
end)

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
    if S.devNoPose then return end   -- dev: move the puppet by hand
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
-- Campaign: every level the GAME opens on the host (mission start from the safehouse, next
-- level, checkpoint reload, restart) comes without "listen", which would end the session.
-- OpenLevel only stores the travel URL for the next frame, so right after the game's call we
-- issue the same travel again with ?listen added - the later call wins. Clients lose the old
-- server and reconnect on their own.
local relisten = false
local function onGameOpenLevel(ctx, name, opts)
    if relisten then return end
    local n, o = "", ""
    pcall(function() n = name:get():ToString() end)
    pcall(function() o = opts:get():ToString() end)
    -- client: only the host moves the group. Quitting to the main menu (while still connected)
    -- ends co-op; any other level our own copy of the story asks for -> back to the host instead.
    if S.joined and not S.hosting then
        if n:find("FrontEndMenuMap") then
            if netDriver() then S.joined = false; S.rejoin = nil; log("left co-op (main menu)") end
            return
        end
        if n == "" or n == "None" or not S.lastIP then return end
        relisten = true
        pcall(function()
            local addr = S.lastIP
            if addr:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then addr = "steam." .. addr end
            StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(ctx:get(), "open " .. addr, localPC())
        end)
        relisten = false
        log("this game wanted to open " .. n .. " on its own - staying with the host")
        return
    end
    if not S.hosting then return end
    if n == "" or n == "None" or o:lower():find("listen") then return end
    if n:find("FrontEndMenuMap") then return end   -- back to the main menu: hosting ends (watchdog)
    relisten = true
    local ok, err = pcall(function()
        GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
        forceIpDriver()
        GS:OpenLevel(ctx:get(), FName(n, EFindName.FNAME_Add), true, o ~= "" and (o .. "?listen") or "listen")
    end)
    relisten = false
    S.awaitHostLoad = true
    S.hostMap = n
    S.travels = (S.travels or 0) + 1
    log("host travel to " .. n .. (o ~= "" and (" [" .. o .. "]") or "") .. ": server kept on " .. tostring(ok) .. " " .. tostring(err or ""))
end
pcall(function()
    RegisterHook("/Script/Engine.GameplayStatics:OpenLevel", function() end, function(self, ctx, name, abs, opts)
        onGameOpenLevel(ctx, name, opts)
    end)
end)

S.every(1000, function()
    if not S.hosting or S.awaitHostLoad or loadedAt == 0 or os.time() - loadedAt < 4 then return end
    local name = currentLevelName()
    if not name or name == "" then return end
    if name:find("FrontEndMenuMap") then
        log("back in the main menu - co-op hosting stopped")
        S.hosting = false
        return
    end
    local hostShort = (S.hostMap or ""):match("([^/]+)$")
    if name ~= hostShort and netDriver() then
        S.hostMap = name   -- some other travel we didn't see (still a server): follow it
        return
    end
    if not netDriver() then
        log("level " .. name .. " has no server - hosting it again")
        S.host(name ~= hostShort and name or S.hostMap)
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

---------------------------------------------------------------------------
-- Campaign scripting. Level triggers (BaseTriggerOnce_C and its children: autosaves, enemy
-- squads, doors, objective texts...) have the same names on every machine. The host's triggers
-- are the real ones (partners' puppets set them off there too). On a client, triggers that save
-- or spawn would start a private copy of the story, so a client keeps only the purely local ones
-- (sky, music, tutorials) switched on; when a host trigger fires, clients fire their copy too,
-- except saves and spawns (the host's enemies reach clients through the engine anyway).
---------------------------------------------------------------------------
-- A Horde map: by name, or (custom community maps) by the horde mode actor being in the level.
function S.isHordeMap(map)
    if (map or ""):find("Horde") then return true end
    local name = currentLevelName()
    if map and name and (map:match("([^/]+)$") == name) then return valid(FindFirstOf("HordeModeActor_C")) end
    return false
end
-- the Horde level we're standing in (short name), nil elsewhere
function S.hordeLevelHere()
    local name = currentLevelName()
    if not name or name == "" or name:find("MenuMap") then return nil end
    if name:find("Horde") or valid(FindFirstOf("HordeModeActor_C")) then return name end
end

local function missionLib()
    local L = StaticFindObject("/Game/Blueprint/Game/BP_MissionLib.Default__BP_MissionLib_C")
    if valid(L) then return L end
end
-- the game's own "load last checkpoint"; if nothing is saved yet, its "restart level"
function S.loadLastSave()
    local L, w = missionLib(), world()
    if not L or not valid(w) then return end
    local before = S.travels or 0
    pcall(function() L["Trepang Load Last Save"](L, w, false, w) end)
    S.every(6000, function()
        if (S.travels or 0) == before and not S.loading then
            log("no checkpoint to load - restarting the level")
            local L2, w2 = missionLib(), world()
            if L2 and valid(w2) then pcall(function() L2["Trepang Restart Level"](L2, w2, w2) end) end
        end
        return true
    end)
end

-- the campaign level we're in (safehouse or a mission), nil in the menu / horde / offline maps
function S.campaignLevel()
    local name = currentLevelName()
    if not name or name == "" or name:find("FrontEnd") or name:find("MenuMap") or S.hordeLevelHere() then return nil end
    return name
end
-- host the level we're in: the game reloads it (last checkpoint, or a restart) and our
-- OpenLevel hook keeps the server on
function S.hostHere(name)
    S.hosting, S.joined = true, false
    S.awaitHostLoad = true
    S.hostMap = name
    S.known = {}
    log("hosting this level: " .. name)
    if name:find("SafeHouse") then
        local L, w = missionLib(), world()
        if L and valid(w) then pcall(function() L["Trepang Restart Level"](L, w, w) end) end
    else
        S.loadLastSave()
    end
end

local TRIGGER_CLASS = "/Game/Blueprint/Tool/Triggers/BaseTriggerOnce.BaseTriggerOnce_C"
local function clientNeverRuns(cls)
    local c = cls:lower()
    return c:find("autosave") or c:find("spawn") or c:find("missionready")
end
local function clientLocal(cls)
    local c = cls:lower()
    return c:find("skytransition") or c:find("ambientmusic") or c:find("showtutorial")
end
local function trigClass(t) return t:GetClass():GetFName():ToString() end

-- host: watch every trigger; tell clients when one fires
S.trigSeen = {}
S.every(250, function()
    if not isServer() then return end
    for _, t in ipairs(S.allOf(TRIGGER_CLASS)) do
        local name = t:GetFName():ToString()
        local n = t.NumTimesTriggered
        local was = S.trigSeen[name]
        if was == nil then
            S.trigSeen[name] = n           -- first look (new level / restored checkpoint): no event
        elseif n > was then
            S.trigSeen[name] = n
            pcall(function() S.lastTrig = { loc = t:K2_GetActorLocation(), at = os.clock() } end)
            S.toClients("TR", name, n)
            S.stats.trSent = (S.stats.trSent or 0) + 1
        end
    end
end)
-- host -> a client that just arrived: the story so far, and the current mission
function S.sendCampaignState(pc)
    pcall(S.sendInteractState, pc)
    for _, t in ipairs(S.allOf(TRIGGER_CLASS)) do
        if t.NumTimesTriggered > 0 then S.toClient(pc, "TR", t:GetFName():ToString(), t.NumTimesTriggered) end
    end
    pcall(function()
        local m = FindFirstOf("GameInstanceBP_C").CurrentMissionInfoObject
        if valid(m) then S.toClient(pc, "MI", classPath(m)) end
    end)
end

-- client: keep the story triggers off (checked often: we can spawn right inside one)
S.every(100, function()
    if not S.joined or not netDriver() then return end
    for _, t in ipairs(S.allOf(TRIGGER_CLASS)) do
        if not t.TriggerDisabled and not clientLocal(trigClass(t)) then t.TriggerDisabled = true end
    end
end)

-- queued: run only once our own pawn has been in play for a few seconds (firing a trigger
-- while the client was still setting up its pawn crashed the game)
S.trQueue = {}
handlers.client["TR"] = function(_, p)
    table.insert(S.trQueue, { name = p[1], n = tonumber(p[2]) or 1 })
    log("host trigger queued: " .. tostring(p[1]))
end
S.every(200, function()
    if not S.joined or #S.trQueue == 0 then return end
    local pawn = S.client and S.client.pawn
    if not valid(pawn) or not controllerReady(pawn) then S.trReadyAt = nil return end
    S.trReadyAt = S.trReadyAt or (os.clock() + 3)
    if os.clock() < S.trReadyAt then return end
    for _ = 1, 3 do
        local e = table.remove(S.trQueue, 1)
        if not e then break end
        S.runHostTrigger(e.name, e.n, pawn)
    end
end)
function S.runHostTrigger(name, n, pawn)
    for _, t in ipairs(S.allOf(TRIGGER_CLASS)) do
        if t:GetFName():ToString() == name then
            local cls = trigClass(t)
            if clientNeverRuns(cls) or clientLocal(cls) or t.NumTimesTriggered >= n then return end
            local was = t.TriggerDisabled
            t.TriggerDisabled = false
            local ok, err = pcall(function() t:TryTrigger(pawn, {}) end)
            t.TriggerDisabled = was
            S.stats.trDone = (S.stats.trDone or 0) + 1
            log("host trigger " .. name .. " (" .. cls .. "): " .. (ok and ("ran, n=" .. t.NumTimesTriggered) or tostring(err)))
            return
        end
    end
end

handlers.client["MI"] = function(_, p)
    pcall(function()
        local gi = FindFirstOf("GameInstanceBP_C")
        local cur = gi.CurrentMissionInfoObject
        if valid(cur) and classPath(cur) == p[1] then return end
        local cls = StaticFindObject(p[1])
        if valid(cls) then gi:SetCurrentMission(cls); log("mission: " .. p[1]) end
    end)
end

-- client: enemies come from the host (network copies). One that exists only here (spawned by
-- something local) would be a ghost the host never sees - remove it.
S.every(500, function()
    if not S.joined or not netDriver() then return end
    -- cutscenes spawn their own local actors (characters too): leave everything alone meanwhile
    if S.cut and (S.cut.active or os.clock() - (S.cut.endedAt or -99) < 5) then return end
    local playerCls = classOf("/Script/CPPFPS.BasePlayer")
    for _, c in ipairs(S.allOf("/Script/CPPFPS.BaseCharacter")) do
        -- (not the helicopters' AI "bullseye" targets: their owner keeps using them, removing one
        -- crashed the game)
        if c.Role == 3 and not c:IsA(playerCls) and not c:GetFName():ToString():find("Bullseye") and not S.costumeSet[c:GetFullName()] then
            log("removing local-only " .. c:GetFName():ToString())
            pcall(function() c:K2_DestroyActor() end)
        end
    end
end)

---------------------------------------------------------------------------
-- Cutscenes. Only the host has the game mode that starts them (BaseGameMode_C: "Prepare and Play
-- Cutscene" -> CurrentCutscene). The sequences themselves are level actors (LevelSequenceActor) that
-- every machine has under the same name. The host tells clients which one is playing and where it
-- is ("CS|name|seconds", twice a second); a client plays its own copy in step with the host, with
-- every player hidden (the partner is not written into the scene), its controls and HUD off. When
-- the host's cutscene ends ("CE"), clients finish theirs and the host puts them next to itself.
---------------------------------------------------------------------------
local function seqSeconds(player, getter)
    local ok, t = pcall(function()
        local q = player[getter](player)
        return (q.Time.FrameNumber.Value + q.Time.SubFrame) * q.Rate.Denominator / q.Rate.Numerator
    end)
    return ok and t or nil
end
local function hostCutscene()
    local gm = FindFirstOf("BaseGameMode_C")
    if not valid(gm) then return nil end
    local cur = gm.CurrentCutscene
    if not valid(cur) or not cur:IsPlaying() then return nil end
    local actor = cur:GetOuter()
    if not valid(actor) then return nil end
    return actor:GetFName():ToString(), seqSeconds(cur, "GetCurrentTime") or 0
end

-- every other player's body hidden (host: partners' puppets; client: everyone incl. our own pawn)
local function hidePlayersForCutscene(hide)
    for _, p in ipairs(S.allOf("/Script/CPPFPS.BasePlayer")) do
        local mine = S.hosting and same(p, localPC() and localPC().Pawn)
        local puppet = S.joined and S.client and same(p, S.client.puppet)
        if not mine and not puppet and valid(p.PlayerState) then
            pcall(function() p:SetActorHiddenInGame(hide) end)
            local w = p.CurrentWeapon
            if valid(w) then pcall(function() w:SetActorHiddenInGame(hide) end) end
        end
    end
    for _, e in pairs(S.bodies or {}) do
        if e.dualGun then pcall(function() e.dualGun:SetActorHiddenInGame(hide) end) end
    end
end

S.cut = { active = false }

-- Cutscene gate: a cutscene only plays once every player has come to where it starts. The host
-- holds it (paused, with its own controls and camera back), shows "WAITING FOR PLAYERS k/n" at the
-- top of everybody's screen and a marker over the gathering point (the trigger that started it, or
-- the host's spot). After a level change, players still reconnecting count too (for 2 minutes).
local GATHER_R = 700
S.gateDone = {}
local function hostPlayerPawns()
    local list = {}
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and valid(pc.Pawn) then table.insert(list, pc.Pawn) end
    end
    return list
end
S.every(1000, function() if S.hosting and netDriver() then S.lastCount = #(FindAllOf("PlayerController") or {}) end end)
local function gateText(k, n)
    return (S.isRussian() and "ОЖИДАНИЕ ИГРОКОВ " or "WAITING FOR PLAYERS ") .. k .. "/" .. n
end
local gateMark = {}
local function showGate(k, n, point)
    if not point or n == 0 then
        S.banner(nil)
        if valid(gateMark.icon) then pcall(function() gateMark.icon:K2_DestroyActor() end) end
        gateMark.icon = nil
        return
    end
    S.banner(gateText(k, n))
    if not valid(gateMark.icon) then
        pcall(function()
            local cls = classOf(ICON_CLASS)
            if not valid(cls) and LoadAsset then cls = LoadAsset(ICON_CLASS) end
            local icon = world():SpawnActor(cls, { X = point.X, Y = point.Y, Z = point.Z + 60 }, { Pitch = 0, Yaw = 0, Roll = 0 })
            icon.OwningPlayer = localPC()
            S.modIcons[icon:GetFullName()] = true
            pcall(function() icon:Sickle_ShowIcon() end)
            pcall(function() icon:HackOverrideSubtitle(FText(S.isRussian() and "СБОР" or "GATHER HERE")) end)
            gateMark.icon = icon
        end)
    end
end
local function gateCount(g)
    local k, pawns = 0, hostPlayerPawns()
    for _, p in ipairs(pawns) do
        if dist2(p:K2_GetActorLocation(), g.point) <= (S.gatherR or GATHER_R) ^ 2 then k = k + 1 end
    end
    local n = #pawns
    if os.clock() < (S.expectUntil or 0) then n = math.max(n, S.expectPlayers or 1) end
    return k, n
end
local function holdCutscene(cur, name)
    local pc = localPC()
    local point
    if S.lastTrig and os.clock() - S.lastTrig.at < 3 then point = S.lastTrig.loc end
    if not point and valid(pc) and valid(pc.Pawn) then point = pc.Pawn:K2_GetActorLocation() end
    pcall(function() cur:Pause() end)
    -- a paused sequence keeps its camera: give the view back to the player while we wait
    pcall(function() cur:SetDisableCameraCuts(true) end)
    pcall(function() FindFirstOf("BaseGameMode_C"):SetPlayerCutsceneMode(false, false) end)
    pcall(function() pc.PlayerCameraManager:StopCameraFade() end)
    pcall(function() pc:SetViewTargetWithBlend(pc.Pawn, 0, 0, 0, false) end)
    S.gate = { name = name, player = cur, point = point, sentAt = 0 }
    -- the cutscene's own fade (many start from black) stays on the paused camera: keep it clear
    S.every(0, function()
        if S.gate ~= nil and S.gate.player == cur then
            pcall(function() pc.PlayerCameraManager:SetManualCameraFade(0.0, { R = 0, G = 0, B = 0, A = 1 }, false) end)
            pcall(function() pc.Pawn.PlayerHud:SetRenderOpacity(1) end)
            -- and out of cutscene mode: controls on, our pawn shown
            pcall(function() if pc:IsMoveInputIgnored() or pc:IsLookInputIgnored() then pc:ResetIgnoreInputFlags() end end)
            pcall(function() if pc.Pawn.bHidden then pc.Pawn:SetActorHiddenInGame(false) end end)
            pcall(function() if not same(pc:GetViewTarget(), pc.Pawn) then pc:SetViewTargetWithBlend(pc.Pawn, 0, 0, 0, false) end end)
        else
            return true
        end
    end)
    log("cutscene " .. name .. " held until everyone is here")
end
local function releaseCutscene(g)
    S.gate = nil
    S.gateDone[g.name] = true
    showGate(0, 0, nil)
    S.toClients("WB", 0, 0)
    pcall(function() FindFirstOf("BaseGameMode_C"):SetPlayerCutsceneMode(true, true) end)
    -- from the start again, so the cutscene's camera takes over the view properly
    pcall(function() g.player:SetDisableCameraCuts(false) end)
    pcall(function() g.player:JumpToSeconds(0) end)
    pcall(function() g.player:Play() end)
    log("everyone is here - cutscene " .. g.name)
end
S.every(250, function()
    local g = S.gate
    if not g or not S.hosting then return end
    if not valid(g.player) then S.gate = nil; showGate(0, 0, nil); S.toClients("WB", 0, 0); return end
    local k, n = gateCount(g)
    if k >= n then return releaseCutscene(g) end
    showGate(k, n, g.point)
    if os.clock() - g.sentAt >= 0.5 then
        g.sentAt = os.clock()
        S.toClients("WB", k, n, fmtVec(g.point))
    end
end)
handlers.client["WB"] = function(_, p)
    local k, n = tonumber(p[1]) or 0, tonumber(p[2]) or 0
    showGate(k, n, n > 0 and vec(p, 3) or nil)
end

-- host side
S.every(250, function()
    if not S.hosting or not netDriver() or S.gate then return end
    local name, t = hostCutscene()
    if name and not S.cut.active and not S.gateDone[name] and (t or 0) < 1.5 then
        local players = #(FindAllOf("PlayerController") or {})
        if os.clock() < (S.expectUntil or 0) then players = math.max(players, S.expectPlayers or 1) end
        if players > 1 then
            local gm = FindFirstOf("BaseGameMode_C")
            return holdCutscene(gm.CurrentCutscene, name)
        end
    end
    local c = S.cut
    if name then
        if not c.active or c.name ~= name then
            c.active, c.name, c.sentAt = true, name, 0
            log("cutscene " .. name .. " - shown to everyone")
            hidePlayersForCutscene(true)
        end
        if os.clock() - c.sentAt >= 0.5 then
            c.sentAt = os.clock()
            S.toClients("CS", name, string.format("%.2f", t))
        end
        hidePlayersForCutscene(true)   -- puppets that (re)appear meanwhile
    elseif c.active then
        c.active, c.endedAt = false, os.clock()
        S.toClients("CE", c.name or "")
        hidePlayersForCutscene(false)
        log("cutscene " .. tostring(c.name) .. " ended")
        -- the game may have moved us for the next scene: bring everyone over a moment later
        S.every(700, function()
            S.known = {}
            S.spawnIndex = 0
            return true
        end)
    end
end)

-- client side
local function clientCutsceneMode(on)
    local pc = localPC()
    local pawn = S.client and S.client.pawn
    pcall(function()
        if on then pc:SetIgnoreMoveInput(true); pc:SetIgnoreLookInput(true) else pc:ResetIgnoreInputFlags() end
    end)
    if valid(pawn) then
        pcall(function() pawn:SetActorHiddenInGame(on) end)
        pcall(function() local w = pawn.CurrentWeapon; if valid(w) then w:SetActorHiddenInGame(on) end end)
        pcall(function() pawn:SetInvulnerableState(on or S.devGod or false) end)
        pcall(function() pawn.PlayerHud:SetRenderOpacity(on and 0 or 1) end)
    end
    hidePlayersForCutscene(on)
    if not on and valid(pawn) then
        pcall(function() pc:SetViewTargetWithBlend(pawn, 0.3, 0, 0, false) end)
    end
end
local function findSequence(name)
    for _, a in ipairs(FindAllOf("LevelSequenceActor") or {}) do
        if valid(a) and a:GetFName():ToString() == name then return a end
    end
end
handlers.client["CS"] = function(_, p)
    local name, t = p[1], tonumber(p[2]) or 0
    local c = S.cut
    local actor = findSequence(name)
    if not actor or not valid(actor.SequencePlayer) then
        if c.missing ~= name then c.missing = name; log("cutscene " .. tostring(name) .. " not loaded here") end
        return
    end
    local player = actor.SequencePlayer
    if not c.active or c.name ~= name then
        c.active, c.name, c.player = true, name, player
        clientCutsceneMode(true)
        pcall(function() player:JumpToSeconds(t) end)
        pcall(function() player:Play() end)
        log("cutscene " .. name .. " from " .. string.format("%.1f", t) .. " s")
    else
        if not player:IsPlaying() then pcall(function() player:Play() end) end
        local mine = seqSeconds(player, "GetCurrentTime")
        if mine and math.abs(mine - t) > 0.6 then pcall(function() player:JumpToSeconds(t) end) end
    end
    c.lastMsg = os.clock()
    hidePlayersForCutscene(true)
end
local function endClientCutscene()
    local c = S.cut
    if not c.active then return end
    c.active, c.endedAt = false, os.clock()
    pcall(function() if valid(c.player) and c.player:IsPlaying() then c.player:GoToEndAndStop() end end)
    clientCutsceneMode(false)
    log("cutscene " .. tostring(c.name) .. " ended")
end
handlers.client["CE"] = function() endClientCutscene() end
-- lost the host mid-cutscene (or a missed "CE"): don't stay stuck in it
S.every(1000, function()
    local c = S.cut
    if S.joined and c.active and os.clock() - (c.lastMsg or 0) > 3 then endClientCutscene() end
end)

---------------------------------------------------------------------------
-- Scripted dialogue (radio chatter and lines during missions): BP_ScriptedDialogueActor_C level
-- actors, same names everywhere, each a list of lines (sound + subtitle + speaker). The host's
-- copies run the story; the host reports every line it starts ("DL|name|line|fallback") and when
-- a dialogue is over ("DF|name"). Clients play that line with their own copy (sound + subtitle);
-- their copies never start by themselves, so nothing is heard twice.
---------------------------------------------------------------------------
local DIALOGUE_CLASS = "BP_ScriptedDialogueActor_C"
local LINE_KEY = "Line_2_85F150E843D8D013D565129435324EE4"
local FALLBACK_KEY = "FallbackLines_5_DF5F8B254196DD2CF756F08574DB356A"
local SOUND_KEY = "Sound_6_EBA04BD14157F792FE918CBBED186C6F"
local SUBTITLE_KEY = "SubtitleFile_12_F2D285D44B3C1D1F6289718EBB5350F0"
S.dlgSeen = {}

-- a line is "on" while the actor's speaking audio plays (its started/finished flags are set by
-- the outer start event and miss lines started directly)
S.every(150, function()
    if not S.hosting or not netDriver() or #(FindAllOf("PlayerController") or {}) < 2 then return end
    for _, a in ipairs(FindAllOf(DIALOGUE_CLASS) or {}) do
        if valid(a) then
            local name = a:GetFName():ToString()
            local seen = S.dlgSeen[name] or {}
            local speaking = false
            pcall(function() speaking = valid(a.CurrentSpeakingAudioComp) and a.CurrentSpeakingAudioComp:IsPlaying() end)
            local line, fb = a.CurrentDialogueLineElement, a.FallbackLineElement
            if speaking and (seen.line ~= line or seen.fb ~= fb or not seen.speaking) then
                -- who speaks: the dialogue actor itself (radio) or a character (sent by position)
                local who = "radio"
                pcall(function()
                    local sp = a.CurrentSpeaker
                    if valid(sp) and not same(sp, a) then who = fmtVec(sp:K2_GetActorLocation()) end
                end)
                S.toClients("DL", name, line, fb, who)
                S.stats.dlgSent = (S.stats.dlgSent or 0) + 1
            elseif not speaking and seen.speaking and a.FinishedPlaying then
                S.toClients("DF", name)
            end
            seen.line, seen.fb, seen.speaking = line, fb, speaking
            S.dlgSeen[name] = seen
        end
    end
end)

local function findDialogue(name)
    for _, a in ipairs(FindAllOf(DIALOGUE_CLASS) or {}) do
        if valid(a) and a:GetFName():ToString() == name then return a end
    end
end
-- the n-th (0-based) element of a TArray
local function arrayAt(arr, n)
    local found
    pcall(function() arr:ForEach(function(i, el) if i - 1 == n then found = el:get() end end) end)
    return found
end
handlers.client["DL"] = function(_, p)
    local a = findDialogue(p[1] or "")
    local line, fb = tonumber(p[2]) or 0, tonumber(p[3]) or -1
    if not a then return end
    local info = arrayAt(a.ScriptedConversation, line)
    if not info then return end
    local l = info[LINE_KEY]
    if fb >= 0 then l = arrayAt(info[FALLBACK_KEY], fb) or l end
    local sound, subtitle = l[SOUND_KEY], l[SUBTITLE_KEY]
    local speaker = a                                        -- radio: the dialogue actor itself
    if p[4] and p[4] ~= "radio" then
        local at = vec(p, 4)
        speaker = nearestNPC(at, 400) or a
    end
    a.StartedPlaying, a.FinishedPlaying = true, false
    local ok, err = pcall(function() a:SpeakLine(speaker, line, fb, 0.0, sound, subtitle) end)
    log("dialogue " .. p[1] .. " line " .. line .. (ok and "" or (" failed: " .. tostring(err))))
end
handlers.client["DF"] = function(_, p)
    local a = findDialogue(p[1] or "")
    if a then a.FinishedPlaying = true end
end
-- client: dialogue actors that start when walked into stay quiet here (the host's start them)
S.every(1000, function()
    if not S.joined or not netDriver() then return end
    for _, a in ipairs(FindAllOf(DIALOGUE_CLASS) or {}) do
        if valid(a) and a.MakeThisATrigger then
            pcall(function() if a.TriggerColl:GetCollisionEnabled() ~= 0 then a.TriggerColl:SetCollisionEnabled(0) end end)
        end
    end
end)

---------------------------------------------------------------------------
-- Doors (ABaseDoorActor: bIsLocked, bIsOpen). The host's story scripts lock and unlock doors; a
-- client's copy would stay locked and block the way. Host -> clients: "DO|name|locked|open|side"
-- on every change (and for all doors to a newcomer). A client unlocks/locks its copy to match and
-- opens it when the host's opens. Doors a client opens itself stay its own business.
---------------------------------------------------------------------------
local DOOR_CLASS = "/Script/CPPFPS.BaseDoorActor"
S.doorSeen = {}
local function doorState(d)
    local side = 1
    pcall(function() if d.DoorMesh.RelativeRotation.Yaw < 0 then side = 0 end end)
    return (d.bIsLocked and 1 or 0), (d.bIsOpen and 1 or 0), side
end
S.every(500, function()
    if not S.hosting or not netDriver() or #(FindAllOf("PlayerController") or {}) < 2 then return end
    for _, d in ipairs(S.allOf(DOOR_CLASS)) do
        local name = d:GetFName():ToString()
        local l, o, side = doorState(d)
        local key = l .. o
        local was = S.doorSeen[name]
        if was == nil then
            S.doorSeen[name] = key
        elseif was ~= key then
            S.doorSeen[name] = key
            S.toClients("DO", name, l, o, side)
        end
    end
end)
function S.sendDoors(pc)
    for _, d in ipairs(S.allOf(DOOR_CLASS)) do
        local l, o, side = doorState(d)
        if l == 1 or o == 1 then S.toClient(pc, "DO", d:GetFName():ToString(), l, o, side) end
    end
end
handlers.client["DO"] = function(_, p)
    local name, locked, open, side = p[1], p[2] == "1", p[3] == "1", p[4] == "1"
    for _, d in ipairs(S.allOf(DOOR_CLASS)) do
        if d:GetFName():ToString() == name then
            if locked and not d.bIsLocked then pcall(function() d:LockDoor() end)
            elseif not locked and d.bIsLocked then pcall(function() d:UnlockDoor() end) end
            if open and not d.bIsOpen and not locked then pcall(function() d:OpenDoor(side) end) end
            return
        end
    end
end

---------------------------------------------------------------------------
-- Interactions: everything used with the interact key (UBaseInteractableComponent) - terminals,
-- buttons, levers, elevators, scripted "player interaction" scenes (BP_PlayerInteraction_C, e.g.
-- the cultists' heavy doors). The game calls these natively (Lua hooks never fire), so every
-- machine watches its own pawn's focused component (pawn.InteractableComp): a timed one that
-- counted down to the end, or an instant one when the interact key goes down.
--   client -> host "IA|owner|comp": the host uses its copy with the partner's body as the
--     instigator (InteractDuration -1 for the call = instant). The story runs on the host.
--   host -> clients "IX|owner|comp": it was used; a client uses its own copy too (machines and
--     elevators move locally), a scripted scene only plays the object's animation there.
--   host -> clients "IE|owner|comp|1/0": the host's level scripts switched it on / off.
-- Personal things (intel, collectables, pickups, crates, doors, the safehouse) stay per player.
---------------------------------------------------------------------------
do
local PERSONAL = { "intel", "collectable", "pickup", "supplycrate", "gramophone", "weaponbench",
    "safehouse", "buyzone", "smokegrenade", "weapon", "ammo", "health", "armor", "exitportal" }
local CLIENT_NO_MIRROR = { "extraction", "helicopter", "mission", "portal" }
local personalCache, sceneCache = {}, {}
local function clsName(o) return o:GetClass():GetFName():ToString() end
local function isPersonal(o)
    local cls = clsName(o)
    local v = personalCache[cls]
    if v == nil then
        local l = cls:lower()
        v = false
        for _, w in ipairs(PERSONAL) do if l:find(w, 1, true) then v = true end end
        if not v then pcall(function() if o:IsA(classOf(DOOR_CLASS)) then v = true end end) end
        personalCache[cls] = v
    end
    return v
end
local function isScene(o)
    local cls = clsName(o)
    local v = sceneCache[cls]
    if v == nil then
        v = false
        local c = o:GetClass()
        while valid(c) do
            if c:GetFName():ToString() == "BP_PlayerInteraction_C" then v = true break end
            c = c:GetSuperStruct()
        end
        sceneCache[cls] = v
    end
    return v
end
local function sharedComps()
    local out = {}
    for _, c in ipairs(FindAllOf("BaseInteractableComponent") or {}) do
        pcall(function()
            local o = c:GetOwner()
            if valid(o) and not isPersonal(o) then
                table.insert(out, { c = c, o = o, owner = o:GetFName():ToString(), name = c:GetFName():ToString() })
            end
        end)
    end
    return out
end
local function findComp(owner, name)
    for _, e in ipairs(sharedComps()) do
        if e.owner == owner and e.name == name then return e.c, e.o end
    end
end
-- use a component right now, as `who` (a timed one too: duration -1 for the call)
local function useNow(c, who)
    local d = c.InteractDuration
    c.InteractDuration = -1
    local ok, err = pcall(function() c:Interact(who) end)
    c.InteractDuration = d
    return ok, err
end
S.useNow = useNow

-- what a component is, read while it is still alive (a used pickup / intel is destroyed at once)
local function compInfo(c)
    local o = c:GetOwner()
    if not valid(o) then return nil end
    return { owner = o:GetFName():ToString(), name = c:GetFName():ToString(), cls = clsName(o),
        personal = isPersonal(o), instant = c.InteractDuration <= 0, allow = c.bAllowInteraction }
end
local function interacted(info)
    if not info then return end
    if S.iaDebug then log("used (any): " .. info.owner) end
    if info.personal then return end
    log("interaction: " .. info.owner .. "/" .. info.name .. " (" .. info.cls .. ")")
    S.stats.interactions = (S.stats.interactions or 0) + 1
    if S.joined then S.toServer("IA", info.owner, info.name) else S.toClients("IX", info.owner, info.name) end
end
S.interacted = function(c) interacted(compInfo(c)) end

-- ia.cur: the focused component (address + info); ia.hold: a timed one counting down
local ia = { cur = nil, hold = nil, keyWas = false }
local INTERACT_KEYS
S.every(0, function()
    if not (S.hosting or S.joined) or not netDriver() then return end
    local pawn, pc = myPawn(), localPC()
    if not valid(pawn) or not valid(pc) then return end
    INTERACT_KEYS = INTERACT_KEYS or {
        { KeyName = FName("F", EFindName.FNAME_Add) },
        { KeyName = FName("Gamepad_FaceButton_Left", EFindName.FNAME_Add) },
    }
    local down = false
    for _, k in ipairs(INTERACT_KEYS) do
        if pc:IsInputKeyDown(k) then down = true end
    end
    local c = pawn.InteractableComp
    if not valid(c) then c = nil end
    -- a timed interaction we saw counting down: finished (used) or let go (cancelled)?
    if ia.hold then
        local h = ia.hold
        if c and c:GetAddress() == h.addr and c.bIsCountingDownDuration then
            h.rem = c.RemainingDuration
        else
            -- gone from focus / stopped counting: used if it was about done (it may vanish on use)
            if h.rem < 0.25 then interacted(h.info) end
            ia.hold = nil
        end
    end
    -- instant ones are used on the key press, often before we look: take what was focused last tick
    if down and not ia.keyWas then
        local cur = ia.cur
        if c and (not cur or cur.addr ~= c:GetAddress()) then cur = { addr = c:GetAddress(), info = compInfo(c) } end
        if cur and cur.info and cur.info.instant and cur.info.allow then interacted(cur.info) end
    end
    if c then
        local addr = c:GetAddress()
        if not ia.cur or ia.cur.addr ~= addr then ia.cur = { addr = addr, info = compInfo(c) } end
        if ia.cur.info then ia.cur.info.allow = c.bAllowInteraction end
        if not ia.hold and ia.cur.info and not ia.cur.info.instant and c.bIsCountingDownDuration then
            ia.hold = { addr = addr, info = ia.cur.info, rem = c.RemainingDuration }
        end
    else
        ia.cur = nil
    end
    ia.keyWas = down
end)

local function otherClients(except)
    local out = {}
    local ex = valid(except) and except:GetFullName() or ""
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and not pc:IsLocalController() and pc:GetFullName() ~= ex then table.insert(out, pc) end
    end
    return out
end

handlers.server["IA"] = function(pc, p)
    local c, o = findComp(p[1], p[2])
    if not valid(c) then log("IA: no " .. tostring(p[1]) .. "/" .. tostring(p[2])) return end
    if not c.bAllowInteraction then log("IA: host's " .. p[1] .. " is off") return end
    local who = valid(pc.Pawn) and pc.Pawn or myPawn()
    local ok, err = useNow(c, who)
    log("partner used " .. p[1] .. "/" .. p[2] .. (ok and "" or (": " .. tostring(err))))
    for _, other in ipairs(otherClients(pc)) do S.toClient(other, "IX", p[1], p[2]) end
end

handlers.client["IX"] = function(_, p)
    local c, o = findComp(p[1], p[2])
    if not valid(c) then return end
    if isScene(o) then
        -- someone else's scripted scene: just play the object's part (doors swing open...)
        pcall(function() o.Interactable_SkeletalMesh:PlayAnimation(o.InteractionAnimation_Interactable, false) end)
        pcall(function() c:DisableInteraction() end)
        log("host scene " .. p[1] .. ": object animation")
        return
    end
    local l = clsName(o):lower()
    for _, w in ipairs(CLIENT_NO_MIRROR) do if l:find(w, 1, true) then return end end
    local pawn = myPawn()
    if valid(pawn) then
        local ok, err = useNow(c, pawn)
        log("host used " .. p[1] .. "/" .. p[2] .. (ok and "" or (": " .. tostring(err))))
    end
end

-- host: interactables its level scripts switch on/off
S.ieSeen = {}
S.every(500, function()
    if not S.hosting or not netDriver() or #(FindAllOf("PlayerController") or {}) < 2 then return end
    for _, e in ipairs(sharedComps()) do
        local k = e.owner .. "|" .. e.name
        local v = e.c.bAllowInteraction and 1 or 0
        local was = S.ieSeen[k]
        S.ieSeen[k] = v
        if was ~= nil and was ~= v then S.toClients("IE", e.owner, e.name, v) end
    end
end)
S.ieHost = {}   -- client: owner|comp -> what the host says
handlers.client["IE"] = function(_, p)
    S.ieHost[p[1] .. "|" .. p[2]] = p[3] == "1"
end
S.every(500, function()
    if not S.joined or not netDriver() or next(S.ieHost) == nil then return end
    for _, e in ipairs(sharedComps()) do
        local want = S.ieHost[e.owner .. "|" .. e.name]
        if want ~= nil and e.c.bAllowInteraction ~= want then
            pcall(function() if want then e.c:EnableInteraction() else e.c:DisableInteraction() end end)
        end
    end
end)

---------------------------------------------------------------------------
-- Story objective markers (BP_ObjectiveIcon_C: "find the enforcer", distance through walls).
-- The host's level scripts show/hide/move them; a client's copies don't follow on their own.
-- Host -> clients "OB|name|1/0|x|y|z|text1 class|text2 class|subtitle" on every change (and all of
-- them to a newcomer / after a level load). A client shows/hides/moves its copy of the same name,
-- or spawns its own for an icon the host made at run time. The mod's own icons are left alone.
---------------------------------------------------------------------------
local function iconInfo(a)
    local t1, t2, sub = "", "", ""
    pcall(function() local c = a["Localized Text 1"]; if valid(c) then t1 = c:GetFullName():match("%s(.+)$") or "" end end)
    pcall(function() local c = a["Localized Text 2"]; if valid(c) then t2 = c:GetFullName():match("%s(.+)$") or "" end end)
    pcall(function() sub = (a.OverrideSubtitle:ToString():gsub("|", "/")) end)
    return t1, t2, sub
end
local function far(a, b) return (a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2 > 50 * 50 end
S.obSeen = {}
local function obMessage(a)
    local l = a:K2_GetActorLocation()
    local t1, t2, sub = iconInfo(a)
    return (a.IconActive and 1 or 0), l, t1, t2, sub
end
S.every(500, function()
    if not S.hosting or not netDriver() or #(FindAllOf("PlayerController") or {}) < 2 then return end
    local alive = {}
    for _, a in ipairs(S.allOf(ICON_CLASS)) do
        if not S.modIcons[a:GetFullName()] then
            local name = a:GetFName():ToString()
            alive[name] = true
            local act, l, t1, t2, sub = obMessage(a)
            local key = act .. t1 .. t2 .. sub
            local e = S.obSeen[name]
            if not e or e.key ~= key or (act == 1 and far(e.l, l)) then
                S.obSeen[name] = { key = key, l = l }
                S.toClients("OB", name, act, fmtVec(l), t1, t2, sub)
            end
        end
    end
    for name in pairs(S.obSeen) do
        if not alive[name] then
            S.obSeen[name] = nil
            S.toClients("OB", name, 0, "0|0|0", "", "", "")
        end
    end
end)
function S.sendInteractState(pc)
    for _, e in ipairs(sharedComps()) do
        S.toClient(pc, "IE", e.owner, e.name, e.c.bAllowInteraction and 1 or 0)
    end
    for _, a in ipairs(S.allOf(ICON_CLASS)) do
        if not S.modIcons[a:GetFullName()] then
            local act, l, t1, t2, sub = obMessage(a)
            S.toClient(pc, "OB", a:GetFName():ToString(), act, fmtVec(l), t1, t2, sub)
        end
    end
end

S.obHost = {}   -- client: host icon name -> { act, own = our spawned copy or nil }
local function textClass(path)
    if not path or path == "" then return nil end
    local c = StaticFindObject(path)
    if not valid(c) and LoadAsset then pcall(function() c = LoadAsset(path) end) end
    return valid(c) and c or nil
end
local function localIcon(name)
    local e = S.obHost[name]
    if e and valid(e.own) then return e.own end
    for _, x in ipairs(S.allOf(ICON_CLASS)) do
        if x:GetFName():ToString() == name and not S.modIcons[x:GetFullName()] then return x end
    end
end
handlers.client["OB"] = function(_, p)
    local name, act, loc = p[1], p[2] == "1", vec(p, 3)
    local t1, t2, sub = p[6], p[7], p[8]
    local e = S.obHost[name] or {}
    S.obHost[name] = e
    e.act = act
    local a = localIcon(name)
    if not valid(a) then
        if not act then return end
        pcall(function()
            local cls = classOf(ICON_CLASS)
            if not valid(cls) and LoadAsset then cls = LoadAsset(ICON_CLASS) end
            a = world():SpawnActor(cls, loc, { Pitch = 0, Yaw = 0, Roll = 0 })
            a.OwningPlayer = localPC()
            e.own = a
        end)
        if not valid(a) then return end
    end
    local c1, c2 = textClass(t1), textClass(t2)
    local o1, o2 = iconInfo(a)
    if (c1 or c2) and (o1 ~= t1 or o2 ~= t2) then
        pcall(function() a["Override Icon Text"](a, c1, c2) end)
    end
    if sub ~= "" then pcall(function() a:HackOverrideSubtitle(FText(sub)) end) end
    if act then
        if far(a:K2_GetActorLocation(), loc) then pcall(function() a:K2_SetActorLocation(loc, false, {}, true) end) end
        if not a.IconActive then pcall(function() a:Sickle_ShowIcon() end) end
    elseif a.IconActive then
        pcall(function() a:Sickle_HideIcon() end)
    end
end
-- client: our own copies follow the host only (our level scripts mostly don't run, but replayed
-- triggers can still switch one on)
S.every(1000, function()
    if not S.joined or not netDriver() then return end
    for _, a in ipairs(S.allOf(ICON_CLASS)) do
        if not S.modIcons[a:GetFullName()] and a.IconActive then
            local e = S.obHost[a:GetFName():ToString()]
            if not e or not e.act then
                local own = false
                for _, x in pairs(S.obHost) do if valid(x.own) and x.own:GetFullName() == a:GetFullName() then own = x.act end end
                if not own then pcall(function() a:Sickle_HideIcon() end) end
            end
        end
    end
end)

end
---------------------------------------------------------------------------
-- Human shields (grab an enemy: BasePlayer.MyHostage / bHasAHostage, NPC.bIsAHostage).
-- A client grabs its own network copy of the enemy; the real one lives on the host.
--   client -> host "HG|x|y|z": I grabbed the enemy here -> the partner's body on the host takes the
--     real enemy (TakeHostage): it stops fighting and is carried in front of the partner, so the
--     copies everywhere follow. "HR|thrown": let go / threw it -> ReleaseHostage / ThrowHostage.
--     Killing it needs nothing: the shot goes to the host like any other.
--   host -> other clients "HH|enemy x|y|z|holder x|y|z" / "HE|enemy x|y|z": someone holds one; their
--     copy plays the hostage part too (StartBeingHostage / StopBeingHostage), for the look only.
---------------------------------------------------------------------------
do
local NPC_CLASS = "/Game/Blueprint/AI/BaseNPC.BaseNPC_C"
local hg = { has = false }
S.every(100, function()
    if not S.joined or not netDriver() then return end
    local pawn = S.client and S.client.pawn
    if not valid(pawn) then return end
    local h = pawn.MyHostage
    local has = pawn.bHasAHostage and valid(h)
    if has and not hg.has then
        hg.has, hg.npc = true, h
        S.toServer("HG", fmtVec(h:K2_GetActorLocation()))
        log("grabbed a hostage")
    elseif not has and hg.has then
        -- let go or thrown? A throw needs a moment to get going: look again in 0.4 s
        hg.has = false
        hg.release = { at = os.clock() + 0.4, npc = hg.npc, l = nil }
        pcall(function() hg.release.l = hg.npc:K2_GetActorLocation() end)
        hg.npc = nil
    end
    local r = hg.release
    if r and os.clock() >= r.at then
        hg.release = nil
        local thrown = 0
        pcall(function()
            if r.l and dist2(r.npc:K2_GetActorLocation(), r.l) > 120 * 120 then thrown = 1 end
        end)
        S.toServer("HR", thrown)
        log("let the hostage go" .. (thrown == 1 and " (thrown)" or ""))
    end
end)

handlers.server["HG"] = function(pc, p)
    local puppet = pc.Pawn
    if not valid(puppet) or puppet.bHasAHostage then return end
    local npc = nearestNPC(vec(p, 1), 300)
    if not valid(npc) or npc.bIsAHostage then log("HG: no enemy there") return end
    local ok, err = pcall(function() puppet:TakeHostage(npc) end)
    log("partner took a hostage: " .. npc:GetFName():ToString() .. (ok and "" or (" " .. tostring(err))))
end
handlers.server["HR"] = function(pc, p)
    local puppet = pc.Pawn
    if not valid(puppet) or not puppet.bHasAHostage then return end
    if p[1] == "1" then pcall(function() puppet:ThrowHostage() end)
    else pcall(function() puppet:ReleaseHostage() end) end
end

-- host: who holds whom (for the look on the other machines)
S.hhSeen = {}
S.every(250, function()
    if not S.hosting or not netDriver() or #(FindAllOf("PlayerController") or {}) < 2 then return end
    local now = {}
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local pawn = valid(pc) and pc.Pawn
        if valid(pawn) and pawn.bHasAHostage and valid(pawn.MyHostage) then
            local h = pawn.MyHostage
            local key = h:GetFullName()
            now[key] = true
            if not S.hhSeen[key] then
                S.hhSeen[key] = { pc = pc, l = h:K2_GetActorLocation() }
                local msg = { fmtVec(h:K2_GetActorLocation()), fmtVec(pawn:K2_GetActorLocation()) }
                for _, other in ipairs(FindAllOf("PlayerController") or {}) do
                    if valid(other) and not other:IsLocalController() and other:GetFullName() ~= pc:GetFullName() then
                        S.toClient(other, "HH", msg[1], msg[2])
                    end
                end
            else
                S.hhSeen[key].l = h:K2_GetActorLocation()
            end
        end
    end
    for key, e in pairs(S.hhSeen) do
        if not now[key] then
            S.hhSeen[key] = nil
            for _, other in ipairs(FindAllOf("PlayerController") or {}) do
                if valid(other) and not other:IsLocalController() and (not valid(e.pc) or other:GetFullName() ~= e.pc:GetFullName()) then
                    S.toClient(other, "HE", fmtVec(e.l))
                end
            end
        end
    end
end)
local function nearestPlayer(pos)
    local best, bd = nil, 300 * 300
    local mine = valid(myPawn()) and myPawn():GetFullName() or ""
    for _, pl in ipairs(S.allOf("/Script/CPPFPS.BasePlayer")) do
        if pl:GetFullName() ~= mine and not pl.bHidden then
            local d = dist2(pl:K2_GetActorLocation(), pos)
            if d < bd then best, bd = pl, d end
        end
    end
    return best
end
handlers.client["HH"] = function(_, p)
    local npc, holder = nearestNPC(vec(p, 1), 300), nearestPlayer(vec(p, 4))
    if valid(npc) and valid(holder) and not npc.bIsAHostage then
        pcall(function() npc:StartBeingHostage(holder) end)
        log("host side hostage: " .. npc:GetFName():ToString())
    end
end
handlers.client["HE"] = function(_, p)
    local pos = vec(p, 1)
    local best, bd = nil, 400 * 400
    for _, n in ipairs(S.allOf(NPC_CLASS)) do
        if n.bIsAHostage then
            local d = dist2(n:K2_GetActorLocation(), pos)
            if d < bd then best, bd = n, d end
        end
    end
    if valid(best) then pcall(function() best:StopBeingHostage() end) end
end
end

---------------------------------------------------------------------------
-- Fire. Enemies burn through their FireComponent (IsOnFire, OwnerActorStartFire). A client's fire
-- (incendiary rounds, molotov...) only lights its own copy of an enemy, which can't be hurt.
--   client -> host "FI|x|y|z": a copy here caught fire from us -> the host lights the real enemy
--     (burn damage and the kill go to the partner).
--   host -> clients "FV|x|y|z": this enemy is burning -> the client lights its copy too, for the look.
-- Copies on a client never burn anyone (the host's real fire does the damage).
---------------------------------------------------------------------------
do
local NPC_CLASS = "/Game/Blueprint/AI/BaseNPC.BaseNPC_C"
-- (the IsOnFire field reads false from Lua even while it burns: ask for the time left instead)
local function burning(fc)
    local t = {}
    local ok = pcall(function() fc:GetRemainingBurnDuration(t) end)
    return ok and (tonumber(t.RemainingTime) or 0) > 0
end
S.burning = burning
S.fireOwn, S.fireHost = {}, {}
S.every(250, function()
    if not S.joined or not netDriver() then return end
    for _, n in ipairs(S.allOf(NPC_CLASS)) do
        pcall(function()
            local fc = n.FireComponent
            if not valid(fc) then return end
            if fc.BurnDamageOtherAmountPlayer ~= 0 then
                fc.BurnDamageOtherAmountPlayer = 0
                fc.BurnDamageOtherAmount = 0
            end
            local key = n:GetFullName()
            if burning(fc) then
                if not S.fireOwn[key] and not S.fireHost[key] and not n.bIsDead and (tonumber(n.Health) or 0) > 0 then
                    S.fireOwn[key] = true
                    S.toServer("FI", fmtVec(n:K2_GetActorLocation()))
                    log("our fire: " .. n:GetFName():ToString())
                end
            else
                S.fireOwn[key], S.fireHost[key] = nil, nil
            end
        end)
    end
end)
handlers.server["FI"] = function(pc, p)
    local npc = nearestNPC(vec(p, 1), 300)
    if not valid(npc) then return end
    local fc = npc.FireComponent
    if valid(fc) and not burning(fc) then
        pcall(function() fc:OwnerActorStartFire(-1, pc) end)
        log("partner set " .. npc:GetFName():ToString() .. " on fire")
    end
end
S.fireSeen = {}
S.every(250, function()
    if not S.hosting or not netDriver() or #(FindAllOf("PlayerController") or {}) < 2 then return end
    local now = {}
    for _, n in ipairs(S.allOf(NPC_CLASS)) do
        pcall(function()
            local fc = n.FireComponent
            if valid(fc) and burning(fc) and not n.bIsDead then
                local key = n:GetFullName()
                now[key] = true
                if not S.fireSeen[key] then S.toClients("FV", fmtVec(n:K2_GetActorLocation())) end
            end
        end)
    end
    S.fireSeen = now
end)
handlers.client["FV"] = function(_, p)
    local npc = nearestNPC(vec(p, 1), 300)
    if not valid(npc) then return end
    local fc = npc.FireComponent
    if valid(fc) and not burning(fc) then
        S.fireHost[npc:GetFullName()] = true
        fc.BurnDamageOtherAmountPlayer, fc.BurnDamageOtherAmount = 0, 0
        pcall(function() fc:OwnerActorStartFire(-1, nil) end)
    end
end
end

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
-- Engine.ini. Two network modes (config.txt: net=ip|steam):
--   ip    - IpNetDriver + [OnlineSubsystem] DefaultPlatformService=Null (the shipped Steam/GOG
--           services can't host over IP). Needs UDP 7777 open on the host.
--   steam - the game's default Steam subsystem + SteamNetDriver: join by SteamID64, no port forwarding.
-- The game strips values equal to its defaults when it saves the file, so for Steam we only have to
-- remove our Null line. The file is read at startup: a change works from the next launch.
---------------------------------------------------------------------------
local function ensureEngineIni(mode)
    local base = os.getenv("LOCALAPPDATA")
    if not base then return end
    local path = base .. "/CPPFPS/Saved/Config/WindowsNoEditor/Engine.ini"
    local f = io.open(path, "r")
    local text = f and f:read("*a") or ""
    if f then f:close() end
    -- only counts inside [OnlineSubsystem] (a stray line in another section does nothing)
    local hasAnyNull = text:find("DefaultPlatformService%s*=%s*Null") ~= nil
    local hasNull = false
    for sec, body in text:gmatch("%[([^%]\n]+)%]([^%[]*)") do
        if sec == "OnlineSubsystem" and body:find("DefaultPlatformService%s*=%s*Null") then hasNull = true end
    end
    S.netMode = mode
    if mode == "steam" then
        S.driverClass = STEAM_DRIVER
        if not hasAnyNull then S.iniOk = true return end
        text = text:gsub("DefaultPlatformService%s*=%s*Null[^\n]*\n?", "")
        local w = io.open(path, "w")
        if not w then log("could not update Engine.ini") return end
        w:write(text)
        w:close()
    else
        S.driverClass = IP_DRIVER
        if hasNull then S.iniOk = true return end
        text = text:gsub("DefaultPlatformService%s*=%s*Null[^\n]*\n?", "")
        local w = io.open(path, "w")
        if not w then log("could not update Engine.ini") return end
        w:write(text .. "\n[OnlineSubsystem]\nDefaultPlatformService=Null\n")
        w:close()
    end
    S.iniOk = false
    log("Engine.ini updated for net=" .. tostring(mode) .. " - RESTART THE GAME once")
end

---------------------------------------------------------------------------
-- Player-facing controls.
--   F4  the co-op menu: host, next arena, join, leave, look, network mode, Steam invite
-- config.txt (next to this mod's folder): join_ip=, map=
---------------------------------------------------------------------------
local CONFIG_PATH = "ue4ss/Mods/T2Coop/config.txt"
local cfg = { join_ip = "127.0.0.1", map = "/Game/Maps/HordeMode/Horde_Killhouse", net = "ip", name = "", look = "player", skin = "", enemy_hp = "50" }
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
    f:write("# net=ip: the host's IP (whatismyip.com), UDP 7777 must be open - or use Porthole / Radmin VPN\n")
    f:write("# network: ip (the host opens UDP 7777) or steam (no port forwarding)\n")
    f:write("net=" .. cfg.net .. "\n")
    f:write("# host to join: IP address, or the host's SteamID64 (17 digits) when net=steam\n")
    f:write("join_ip=" .. cfg.join_ip .. "\n")
    f:write("# your name for other players (empty = your Steam name)\n")
    f:write("name=" .. cfg.name .. "\n")
    f:write("# arena to host (F4 menu - NEXT ARENA cycles through all arenas)\n")
    f:write("map=" .. cfg.map .. "\n")
    f:write("# how other players look: player (what each picked in the safehouse) or 106 (Light 106 suit for all)\n")
    f:write("look=" .. tostring(cfg.look or "player") .. "\n")
    f:write("# your enemy outfit (F4 menu - LOOK), empty = your safehouse look\n")
    f:write("skin=" .. tostring(cfg.skin or "") .. "\n")
    f:write("# enemies get this much more health (percent) for every extra player, set by the host; 0 = off\n")
    f:write("enemy_hp=" .. tostring(cfg.enemy_hp or "50") .. "\n")
    f:close()
end
loadConfig()
saveConfig()
S.cfg = cfg

-- Difficulty for more players: the host gives every enemy it sees for the first time
-- (1 + extra players * enemy_hp%) of its health. Enemies already there when a friend joins keep theirs.
S.hpSeen, S.hpSeenN = {}, 0
S.every(250, function()
    if not S.hosting or not netDriver() then return end
    local players = #(FindAllOf("PlayerController") or {})
    local pct = tonumber(cfg.enemy_hp) or 0
    if players < 2 or pct <= 0 then return end
    local mult = 1 + (players - 1) * pct / 100
    if S.hpSeenN > 3000 then S.hpSeen, S.hpSeenN = {}, 0 end
    for _, n in ipairs(S.allOf("/Game/Blueprint/AI/BaseNPC.BaseNPC_C")) do
        local key = n:GetFullName()
        if not S.hpSeen[key] then
            S.hpSeen[key], S.hpSeenN = true, S.hpSeenN + 1
            pcall(function()
                local h = tonumber(n.Health)
                if h and h > 0 and not n.bIsDead and not S.costumeSet[key] then
                    n.Health = h * mult
                    S.stats.hpScaled = (S.stats.hpScaled or 0) + 1
                end
            end)
        end
    end
end)
S.cfgModel = cfg.look
S.mySkin = cfg.skin or ""
-- v0.7.2 saved short ids ("mallcop"): use the class path now
if S.mySkin ~= "" and not S.mySkin:find("/") then
    S.mySkin = ""
    for _, k in ipairs(S.SKINS or {}) do if k.id == cfg.skin then S.mySkin = k.cls end end
end
pcall(ensureEngineIni, cfg.net)
S.bootNet, S.bootIniOk, S.bootDriver = S.netMode, S.iniOk, S.driverClass

-- switch ip <-> steam: rewrites Engine.ini for the next launch; this session keeps its mode
function S.switchNetMode()
    cfg.net = (cfg.net == "steam") and "ip" or "steam"
    saveConfig()
    pcall(ensureEngineIni, cfg.net)
    S.netMode, S.driverClass = S.bootNet, S.bootDriver
    if cfg.net == S.bootNet then S.iniOk = S.bootIniOk else S.iniOk = false end
    S.notify("CO-OP: network mode " .. cfg.net:upper() .. (S.iniOk == false and " - restart the game" or ""))
end

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

-- Banner at the top centre of the screen (e.g. "WAITING FOR PLAYERS 1/2"). Built from Lua like the
-- F4 menu: a text on the root canvas of a fresh popup widget, anchored top-centre. nil hides it.
local banner = {}
function S.banner(text)
    pcall(function()
        if not text then
            if valid(banner.box) then banner.box:SetRenderOpacity(0) end
            banner.text = nil
            return
        end
        if not valid(banner.w) or not valid(banner.box) then
            local cls = classOf(POPUP_CLASS)
            if not valid(cls) and LoadAsset then cls = LoadAsset(POPUP_CLASS) end
            if not valid(cls) then return end
            local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            local w = WBL:Create(world(), cls, localPC())
            if not valid(w) then return end
            local tree = w.WidgetTree
            local box = StaticConstructObject(StaticFindObject("/Script/UMG.Border"), tree, FName("T2CBannerBox", EFindName.FNAME_Add))
            local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree, FName("T2CBannerText", EFindName.FNAME_Add))
            box:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.6 })
            box:SetContent(t)
            local slot = tree.RootWidget:AddChildToCanvas(box)
            slot:SetAnchors({ Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } })
            slot:SetAlignment({ X = 0.5, Y = 0 })
            slot:SetPosition({ X = 0, Y = 40 })
            slot:SetAutoSize(true)
            w:AddToViewport(60)
            banner.w, banner.box, banner.t = w, box, t
        end
        if banner.text ~= text then
            banner.t:SetText(FText("  " .. text .. "  "))
            banner.text = text
        end
        banner.box:SetRenderOpacity(1)
    end)
end
-- the game's language: Russian text for a Russian game
function S.isRussian()
    if S.ru == nil then
        S.ru = false
        pcall(function()
            local c = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary"):GetCurrentCulture():ToString()
            S.ru = c:sub(1, 2) == "ru"
        end)
    end
    return S.ru
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
S.press = onKey   -- dev/tests: same as pressing a menu button ("host", "join", ...)
pcall(function()
    RegisterKeyBind(Key.F4, function() onKey("menu") end)
end)

-- Also read the keys through the game's own input (works whenever the game gets the key).
local keyState = {}
local KEYS = { F4 = "menu" }
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
        -- already on a Horde map (also custom ones that F8 can't list): host that map
        local arena = S.hordeLevelHere()
        if arena and not S.hosting then
            S.notify("CO-OP: hosting " .. arena .. (S.netMode == "steam" and " - F4 to invite Steam friends" or " (UDP 7777)"))
            S.host(arena)
            return
        end
        local here = S.campaignLevel()
        if here then
            S.notify("CO-OP: hosting " .. here .. " - reloading the last checkpoint" ..
                (S.netMode == "steam" and " (F4 to invite Steam friends)" or " (UDP 7777)"))
            S.hostHere(here)
            return
        end
        S.notify("CO-OP: hosting " .. shortName(cfg.map) .. (S.netMode == "steam" and " - F4 to invite Steam friends" or " (UDP 7777)"))
        S.host(cfg.map)
    elseif action == "join" then
        loadConfig()
        S.notify("CO-OP: joining " .. cfg.join_ip)
        S.join(cfg.join_ip)
    elseif action == "leave" then
        S.notify("CO-OP: leaving")
        S.leave()
    elseif action == "netmode" then
        S.switchNetMode()
    elseif action == "hpnext" or action == "hpprev" then
        -- enemy health per extra player (used by the host)
        local steps = { 0, 25, 50, 75, 100, 150, 200 }
        local cur, idx = tonumber(cfg.enemy_hp) or 50, 1
        for i, v in ipairs(steps) do if v <= cur then idx = i end end
        idx = idx + (action == "hpnext" and 1 or -1)
        if idx < 1 then idx = #steps elseif idx > #steps then idx = 1 end
        cfg.enemy_hp = tostring(steps[idx])
        saveConfig()
    elseif action == "menu" then
        S.menuToggle()
    elseif action == "nextlook" or action == "facnext" or action == "facprev" or action == "varnext" or action == "varprev" then
        -- faction 0 = safehouse outfit; factions 1..n each with their variants
        local cat = S.catalog()
        local fi, vi = S.lookIndex(S.mySkin)
        local function pickFirstGood(f, v, step)
            local list = cat[f].list
            for _ = 1, #list do
                if not S.badSkin[list[v].id] then return list[v].id end
                v = (v - 1 + step) % #list + 1
            end
            return ""
        end
        if action == "facnext" or action == "nextlook" then
            fi = (fi + 1) % (#cat + 1)
            S.mySkin = fi > 0 and pickFirstGood(fi, 1, 1) or ""
        elseif action == "facprev" then
            fi = (fi - 1) % (#cat + 1)
            S.mySkin = fi > 0 and pickFirstGood(fi, 1, 1) or ""
        elseif fi > 0 then
            local n = #cat[fi].list
            local step = action == "varnext" and 1 or -1
            S.mySkin = pickFirstGood(fi, (vi - 1 + step) % n + 1, step)
        end
        cfg.skin = S.mySkin
        saveConfig()
    elseif action == "invite" then
        S.steamInvite()
    elseif action == "nextmap" then
        local list = listArenas()
        if #list == 0 then S.notify("CO-OP: no arenas found") return end
        local idx = 1
        for i, m in ipairs(list) do if m == cfg.map then idx = i + 1 end end
        if idx > #list then idx = 1 end
        cfg.map = list[idx]
        saveConfig()
        S.notify("CO-OP arena: " .. shortName(cfg.map) .. "  (" .. idx .. "/" .. #list .. ")")
    end
end)


---------------------------------------------------------------------------
-- Steam invites. t2coop_steam.dll (built by tools/build_steamdll.py) calls the game's own
-- steam_api64.dll for us; commands and answers go through two files in %TMP%.
-- The host sets the rich presence "connect" key = "-t2coopjoin=<SteamID64>": friends see
-- "Join game" in Steam, the invite dialog sends it, and a game started from an invite gets it
-- on its command line.
---------------------------------------------------------------------------
local steamLib, steamTried
local TMPDIR = ((os.getenv("TMP") or os.getenv("TEMP") or "."):gsub("\\", "/"))
local function steamCall(cmd)
    if not steamTried then
        steamTried = true
        local ok, f = pcall(package.loadlib, "ue4ss/Mods/T2Coop/t2coop_steam.dll", "t2s_run")
        if ok and type(f) == "function" then steamLib = f else log("steam helper not loaded: " .. tostring(f)) end
    end
    if not steamLib then return nil end
    local h = io.open(TMPDIR .. "/t2coop_cmd.txt", "wb")
    if not h then return nil end
    h:write(cmd)
    h:close()
    os.remove(TMPDIR .. "/t2coop_out.txt")
    if not pcall(steamLib) then return nil end
    local o = io.open(TMPDIR .. "/t2coop_out.txt", "rb")
    if not o then return nil end   -- Steam is not running
    local out = o:read("a")
    o:close()
    return out
end
S.steamCall = steamCall

local function connectString()
    S.getMyName()
    if not S.mySteamId then return nil end
    return "-t2coopjoin=" .. S.mySteamId
end

-- friends whose game says "join me": { {name=, id=}, ... }
S.steamHosts = {}
function S.scanSteamFriends()
    local out = steamCall("F")
    local list = {}
    for line in (out or ""):gmatch("[^\n]+") do
        local name, id = line:match("^(.-)\t.-%-t2coopjoin=(%d+)")
        if id then table.insert(list, { name = cleanName(name) or name, id = id }) end
    end
    S.steamHosts = list
    return list
end

function S.steamInvite()
    if S.netMode ~= "steam" then S.notify("CO-OP: invites work in Steam mode (F4 - switch network mode)") return end
    if not S.hosting then S.notify("CO-OP: host an arena first, then invite") return end
    local c = connectString()
    if not c or steamCall("I" .. c) == nil then S.notify("CO-OP: Steam is not available") return end
    S.notify("CO-OP: pick a friend in the Steam overlay (Shift+Tab)")
end

local function joinSteamHost(id, name)
    if S.netMode ~= "steam" then
        S.notify("CO-OP: " .. (name or "a friend") .. " invited you - switch to Steam mode (F4) and restart the game")
        return
    end
    cfg.join_ip = id
    saveConfig()
    S.notify("CO-OP: joining " .. (name or id))
    S.join(id)
end
S.joinSteamHost = joinSteamHost

-- host: advertise the game while hosting in Steam mode; everyone: watch for accepted invites
local presence = nil
S.every(2000, function()
    local want = (S.hosting and S.netMode == "steam") and connectString() or ""
    if want ~= presence then
        if steamCall("P" .. want) ~= nil then presence = want end
    end
end)
S.every(1000, function()
    if S.netMode ~= "steam" then return end
    local out = steamCall("J")
    local id = out and out:match("%-t2coopjoin=(%d+)")
    if id and id ~= S.mySteamId then joinSteamHost(id) end
end)

-- the game was started from a Steam invite: join once the main menu is up
local cmdLineChecked = false
S.every(3000, function()
    if cmdLineChecked or not valid(localPC()) then return end
    cmdLineChecked = true
    local ok, line = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetCommandLine():ToString()
    end)
    local id = ok and line and line:match("%-t2coopjoin=(%d+)")
    if id and id ~= S.mySteamId then joinSteamHost(id) end
end)

---------------------------------------------------------------------------
-- Co-op menu (F4): host / next arena / join (address typed in) / leave, player list.
-- Built at runtime inside an instance of the horde music popup (its root is a CanvasPanel).
-- Buttons are polled (IsPressed -> released while hovered = click); no delegates from Lua.
-- Avoid VerticalBox/SetPadding/SetVisibility here: one of them crashed UE4SS.
---------------------------------------------------------------------------
local menu = { open = false, n = 0, buttons = {} }
local MENU_X, MENU_Y, MENU_W, MENU_SCALE = 60, 60, 760, 0.62
local MENU_H = 1168   -- panel height incl. margins (widget units before scaling)

local function mk(tree, cls, name)
    menu.n = menu.n + 1
    return StaticConstructObject(StaticFindObject("/Script/UMG." .. cls), tree, FName("T2CMenu_" .. name .. menu.n, EFindName.FNAME_Add))
end

local function place(root, w, x, y, sx, sy)
    local slot = root:AddChildToCanvas(w)
    table.insert(menu.slots, { slot = slot, x = x, y = y })
    slot:SetPosition({ X = MENU_X + x, Y = MENU_Y + y })
    if sx then slot:SetSize({ X = sx, Y = sy }) else slot:SetAutoSize(true) end
    return slot
end

local function textStyle(t, size, r, g, b)
    -- written before the widget is shown, so the Slate text is built with it
    pcall(function() t.Font.Size = size end)
    pcall(function() t.Font.TypefaceFontName = FName("Regular", EFindName.FNAME_Add) end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = { R = r or 1, G = g or 1, B = b or 1, A = 1 }, ColorUseRule = 0 }) end)
    pcall(function() t.Clipping = 1 end)   -- clip to its box: long names never spill out
end

local function setTextColor(t, r, g, b)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = { R = r, G = g, B = b, A = 1 }, ColorUseRule = 0 }) end)
end

local function box(tree, root, x, y, w, h, r, g, b, a, name)
    local e = mk(tree, "Border", name or "Box")
    e:SetBrushColor({ R = r, G = g, B = b, A = a })
    place(root, e, x, y, w, h)
    return e
end

-- a panel: thin grey edge around a dark see-through fill
local function panel(tree, root, x, y, w, h)
    box(tree, root, x, y, w, h, 0.6, 0.6, 0.6, 0.55, "Edge")
    return box(tree, root, x + 2, y + 2, w - 4, h - 4, 0, 0, 0, 0.82, "Fill")
end

local function label(tree, root, text, x, y, name, size, w, grey, h)
    local t = mk(tree, "TextBlock", name or "Text")
    t:SetText(FText(text))
    local c = grey and 0.62 or 1
    textStyle(t, size or 22, c, c, c)
    place(root, t, x, y, w or MENU_W, h or ((size or 22) + 14))
    return t
end

-- section header: grey caps and a thin line under it
local function section(tree, root, text, y)
    label(tree, root, text, 0, y, "Sec", 18, MENU_W, true)
    box(tree, root, 0, y + 30, MENU_W, 2, 0.6, 0.6, 0.6, 0.45, "Line")
end

local TILE_H = 58
local function button(tree, root, text, x, y, w, action, h, center)
    h = h or TILE_H
    box(tree, root, x, y, w, h, 0.6, 0.6, 0.6, 0.55, "Edge")
    local fill = box(tree, root, x + 2, y + 2, w - 4, h - 4, 0, 0, 0, 0.6, "Fill")
    local t = mk(tree, "TextBlock", "BtnText")
    t:SetText(FText(text))
    textStyle(t, 24)
    if center then
        place(root, t, x + (w - 16) / 2, y + (h - 36) / 2, w / 2, 36)
    else
        place(root, t, x + 20, y + (h - 36) / 2, w - 30, 36)
    end
    -- the clickable part: an invisible button over the tile
    local bt = mk(tree, "Button", "Btn")
    pcall(function() bt:SetBackgroundColor({ R = 1, G = 1, B = 1, A = 0 }) end)
    place(root, bt, x, y, w, h)
    local e = { b = bt, t = t, fill = fill, action = action, down = false, hot = false, enabled = true }
    table.insert(menu.buttons, e)
    return e
end

-- hover look (checked every frame for each tile)
local function paintTile(e, hot)
    if e.hot == hot and e.painted == e.enabled then return end
    e.hot, e.painted = hot, e.enabled
    pcall(function()
        if not e.enabled then
            e.fill:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.3 })
            setTextColor(e.t, 0.45, 0.45, 0.45)
        elseif hot then
            e.fill:SetBrushColor({ R = 0.8, G = 0.8, B = 0.8, A = 0.95 })
            setTextColor(e.t, 0.02, 0.02, 0.02)
        else
            e.fill:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.6 })
            setTextColor(e.t, 1, 1, 1)
        end
    end)
end

local function menuLevelIsFrontEnd()
    local ok, name = pcall(function()
        GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
        return GS:GetCurrentLevelName(world(), true):ToString()
    end)
    return ok and name:find("FrontEnd") ~= nil
end

local function buildMenu()
    local pc = localPC()
    if not valid(pc) then return false end
    local cls = classOf(POPUP_CLASS)
    if not valid(cls) and LoadAsset then cls = LoadAsset(POPUP_CLASS) end
    if not valid(cls) then return false end
    local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local w = WBL:Create(pc, cls, pc)
    if not valid(w) then return false end
    local tree = w.WidgetTree
    local root = tree.RootWidget
    menu.buttons = {}
    menu.slots = {}
    local W2 = (MENU_W - 10) / 2
    panel(tree, root, -30, -24, MENU_W + 60, 1138)
    label(tree, root, "TREPANG2 CO-OP", 0, 0, "Title", 34, MENU_W - 130)
    label(tree, root, "v" .. VERSION, MENU_W - 110, 14, "Ver", 20, 110, true)
    box(tree, root, 0, 52, MENU_W, 2, 0.6, 0.6, 0.6, 0.45, "Line")
    menu.status = label(tree, root, "", 0, 64, "Status", 22)
    button(tree, root, "HOST", 0, 106, W2, "host")
    button(tree, root, "NEXT ARENA", W2 + 10, 106, W2, "nextmap")
    menu.arena = label(tree, root, "", 0, 172, "Arena", 20, MENU_W, true)
    label(tree, root, "JOIN ADDRESS  (IP, or SteamID64 in Steam mode)", 0, 206, "JoinHint", 18, MENU_W, true)
    box(tree, root, 0, 238, 575, TILE_H, 0.6, 0.6, 0.6, 0.55, "Edge")
    local e = mk(tree, "EditableTextBox", "Addr")
    e:SetText(FText(cfg.join_ip or ""))
    place(root, e, 2, 240, 571, TILE_H - 4)
    menu.edit = e
    button(tree, root, "JOIN", 585, 238, MENU_W - 585, "join")
    button(tree, root, "LEAVE CO-OP", 0, 306, W2, "leave")
    button(tree, root, "CLOSE   F4", W2 + 10, 306, W2, "close")
    section(tree, root, "PLAYERS", 384)
    menu.players = label(tree, root, "", 0, 422, "Players", 22, MENU_W, false, 130)
    section(tree, root, "NETWORK", 556)
    menu.net = label(tree, root, "", 0, 594, "Net", 20, MENU_W, true)
    button(tree, root, "INVITE  (STEAM)", 0, 628, W2, "invite")
    button(tree, root, "IP / STEAM MODE", W2 + 10, 628, W2, "netmode")
    menu.friends = label(tree, root, "", 0, 694, "Friends", 18, MENU_W, true)
    menu.fslots = {}
    local fw = (MENU_W - 20) / 3
    for i = 1, 3 do
        menu.fslots[i] = button(tree, root, "", (i - 1) * (fw + 10), 724, fw, "friend" .. i, 48)
    end
    section(tree, root, "LOOK", 790)
    button(tree, root, "<", 0, 828, 64, "facprev", nil, true)
    menu.facTile = button(tree, root, "", 74, 828, MENU_W - 148, "facnext")
    button(tree, root, ">", MENU_W - 64, 828, 64, "facnext", nil, true)
    menu.varPrev = button(tree, root, "<", 0, 894, 64, "varprev", nil, true)
    menu.varTile = button(tree, root, "", 74, 894, MENU_W - 148, "varnext")
    menu.varNext = button(tree, root, ">", MENU_W - 64, 894, 64, "varnext", nil, true)
    menu.lookHint = label(tree, root, "", 0, 962, "LookHint", 18, MENU_W, true)
    section(tree, root, "ENEMY HEALTH", 996)
    button(tree, root, "<", 0, 1034, 64, "hpprev", nil, true)
    menu.hpTile = button(tree, root, "", 74, 1034, MENU_W - 148, "hpnext")
    button(tree, root, ">", MENU_W - 64, 1034, 64, "hpnext", nil, true)
    -- look preview (left of the panel), same frame style
    panel(tree, root, -400, -24, 350, 620)
    menu.previewTitle = label(tree, root, "", -380, 0, "PreviewTitle", 24, 310)
    menu.previewSub = label(tree, root, "", -380, 36, "PreviewSub", 18, 310, true)
    box(tree, root, -380, 70, 310, 2, 0.6, 0.6, 0.6, 0.45, "Line")
    menu.preview = mk(tree, "Image", "Preview")
    place(root, menu.preview, -375, 84, 300, 450)
    pcall(function() menu.preview:SetRenderOpacity(0) end)
    label(tree, root, "how the others see you", -380, 548, "PreviewHint", 18, 310, true)
    -- the game's default font is big at 1080p-like UI scale: shrink the whole panel
    pcall(function() root:SetRenderTransformPivot({ X = 0, Y = 0 }) end)
    pcall(function() root:SetRenderScale({ X = MENU_SCALE, Y = MENU_SCALE }) end)
    w:AddToViewport(300)
    menu.w = w
    return true
end

local function playerList()
    local names = {}
    if S.hosting or S.joined then
        for _, ps in ipairs(FindAllOf("PlayerState") or {}) do
            local n = S.stateName(ps)
            if n then table.insert(names, n) end
        end
    end
    if #names == 0 then names = { S.getMyName() } end
    return names
end

-- keep the panel at the right edge of the screen (the game's own menus are on the left);
-- the viewport size reads 0 for a moment after the loading screen, so this runs on every refresh
local function layoutMenu()
    local ok, x = pcall(function()
        local WLL = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local pc = localPC()
        local size = WLL:GetViewportSize(pc)
        local sx, sy = tonumber(size.X) or 0, tonumber(size.Y) or 0
        local vs = tonumber(WLL:GetViewportScale(pc)) or 1
        if sx <= 0 or sy <= 0 or vs <= 0 then return nil end
        -- as big as MENU_SCALE allows, smaller when the screen is short
        local scale = math.min(MENU_SCALE, (sy / vs) / (MENU_H + MENU_Y))
        local k = vs * scale
        if scale ~= menu.scale then
            menu.scale = scale
            pcall(function() menu.w.WidgetTree.RootWidget:SetRenderScale({ X = scale, Y = scale }) end)
        end
        return math.floor(sx / k - (MENU_W + 30) - 20 / k)
    end)
    if not ok or not x or x == menu.x then return end
    menu.x = x
    for _, e in ipairs(menu.slots or {}) do
        pcall(function() e.slot:SetPosition({ X = x + e.x, Y = MENU_Y + e.y }) end)
    end
end

local function refreshMenu()
    if not valid(menu.w) then return end
    layoutMenu()
    local status
    if S.hosting then
        status = "HOSTING  -  " .. shortName(S.hostMap or cfg.map)
    elseif S.joined then
        status = netDriver() and ("CONNECTED  to " .. tostring(S.lastIP)) or ("CONNECTING  to " .. tostring(S.lastIP))
    else
        status = "OFFLINE  -  host a game or join a friend"
    end
    if S.iniOk == false then status = "RESTART THE GAME to apply network settings" end
    pcall(function() menu.status:SetText(FText(status)) end)
    local here = S.campaignLevel()
    local arenaHere = not S.hosting and S.hordeLevelHere() or nil
    pcall(function()
        menu.arena:SetText(FText(arenaHere and ("HOST starts this arena: " .. arenaHere)
            or here and ("HOST restarts this level from the checkpoint: " .. here)
            or ("HOST starts the Horde arena: " .. shortName(cfg.map))))
    end)
    local list = playerList()
    pcall(function() menu.players:SetText(FText(table.concat(list, "\n"))) end)
    local net
    if cfg.net ~= S.netMode then
        net = "Network: " .. cfg.net:upper() .. " after you restart the game"
    elseif S.netMode == "steam" then
        net = "Steam mode  -  your SteamID64: " .. tostring(S.mySteamId or "?")
    else
        net = "IP mode  -  host needs UDP port 7777 open"
    end
    pcall(function() menu.net:SetText(FText(net)) end)
    -- Steam friends hosting co-op right now
    local hosts = S.steamHosts or {}
    local ftext
    if S.netMode ~= "steam" then
        ftext = "Steam friends hosting: Steam mode only"
    else
        ftext = #hosts == 0 and "Steam friends hosting: none yet" or "Steam friends hosting - click to join:"
    end
    pcall(function() menu.friends:SetText(FText(ftext)) end)
    local sk = S.skinById and S.skinById(S.mySkin or "")
    local fi, vi = S.lookIndex(S.mySkin)
    local cat = S.catalog()
    local fname = fi > 0 and cat[fi].name or "Safehouse outfit"
    pcall(function() menu.facTile.t:SetText(FText(fi > 0 and string.format("%s   %d/%d", fname:upper(), fi, #cat) or "YOUR OWN OUTFIT")) end)
    pcall(function() menu.varTile.t:SetText(FText(fi > 0 and string.format("%s   %d/%d", (sk and sk.name or "?"):upper(), vi, #cat[fi].list) or "AS DRESSED IN THE SAFEHOUSE")) end)
    menu.varTile.enabled, menu.varPrev.enabled, menu.varNext.enabled = fi > 0, fi > 0, fi > 0
    pcall(function() menu.lookHint:SetText(FText(fi > 0 and "Enemy outfit - arrows change the faction and the variant"
        or "Change it at the safehouse wardrobe, or press > for enemy outfits")) end)
    pcall(function() menu.previewTitle:SetText(FText(fi > 0 and (sk and sk.name or ""):upper() or "YOUR OUTFIT")) end)
    pcall(function() menu.previewSub:SetText(FText(fi > 0 and fname or "from the safehouse")) end)
    pcall(function() S.previewUpdate(menu.preview) end)
    pcall(function()
        local pct = tonumber(cfg.enemy_hp) or 0
        local n = #(FindAllOf("PlayerController") or {})
        local txt = pct <= 0 and "SAME FOR ANY NUMBER OF PLAYERS"
            or string.format("+%d%% PER EXTRA PLAYER   (NOW x%.2g)", pct, 1 + math.max(n - 1, 0) * pct / 100)
        if S.joined then txt = txt .. " - HOST DECIDES" end
        menu.hpTile.t:SetText(FText(txt))
    end)
    for i, slot in ipairs(menu.fslots or {}) do
        local h = hosts[i]
        pcall(function() slot.t:SetText(FText(h and h.name or "")) end)
        slot.enabled = h ~= nil
    end
end

local function setMenuInput(on)
    local pc = localPC()
    if not valid(pc) then return end
    local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if on then
        pcall(function() WBL:SetInputMode_GameAndUIEx(pc, menu.edit, 0, false) end)
        pc.bShowMouseCursor = true
    elseif not menuLevelIsFrontEnd() then
        pcall(function() WBL:SetInputMode_GameOnly(pc) end)
        pc.bShowMouseCursor = false
    end
end

function S.menuClose()
    pcall(S.previewDestroy)
    if valid(menu.w) then pcall(function() menu.w:RemoveFromParent() end) end
    menu.w = nil
    if menu.open then setMenuInput(false) end
    menu.open = false
end

function S.menuOpen()
    if menu.open and valid(menu.w) then return end
    menu.x, menu.scale = nil, nil
    if not buildMenu() then log("menu: could not build") return end
    menu.open = true
    refreshMenu()
    setMenuInput(true)
end

function S.menuToggle()
    if menu.open and valid(menu.w) then S.menuClose() else S.menuOpen() end
end

S.every(0, function()
    if not menu.open then return end
    if not valid(menu.w) then menu.open = false return end   -- the map changed under it
    for _, e in ipairs(menu.buttons) do
        local ok, pressed = pcall(function() return e.b:IsPressed() end)
        pressed = ok and pressed or false
        local okh0, hov = pcall(function() return e.b:IsHovered() end)
        paintTile(e, okh0 and hov and e.enabled or false)
        if e.down and not pressed and e.enabled then
            local okh, hovered = pcall(function() return e.b:IsHovered() end)
            e.down = false
            if okh and hovered then
                if e.action == "close" then
                    S.menuClose()
                    return
                end
                if e.action == "join" then
                    local okt, text = pcall(function() return menu.edit:GetText():ToString() end)
                    text = okt and text:gsub("%s", "") or ""
                    if text ~= "" then cfg.join_ip = text; saveConfig() end
                end
                local fi = tonumber(e.action:match("^friend(%d)$") or "")
                if fi then
                    local h = (S.steamHosts or {})[fi]
                    if h then S.menuClose(); joinSteamHost(h.id, h.name) end
                    return
                end
                if e.action == "host" or e.action == "join" or e.action == "leave" then S.menuClose() end
                onKey(e.action)
                return
            end
        end
        e.down = pressed
    end
end)

S.every(250, function() if menu.open then refreshMenu() end end)
S.every(2000, function() if menu.open and S.netMode == "steam" then S.scanSteamFriends() end end)

log("v" .. VERSION .. " loaded")
