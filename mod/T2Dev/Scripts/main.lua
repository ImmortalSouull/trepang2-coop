-- T2Dev: development remote for Trepang2 (not part of the co-op mod itself).
-- Polls ue4ss/Mods/T2Dev/cmd.txt next to this game copy.
-- Lines: "lua:<code>" runs Lua, anything else runs as a console command.
local DIR = "ue4ss/Mods/T2Dev/"
local function log(s) print("[T2Dev] " .. tostring(s) .. "\n") end

local function pc()
    for _, p in ipairs(FindAllOf("PlayerController") or {}) do
        if p:IsValid() and p:IsLocalController() then return p end
    end
end

local KSL
local function console(cmd)
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local p = pc()
    KSL:ExecuteConsoleCommand(p, cmd, p)
end

_G.T2 = { log = log, pc = pc, console = console }

local function runLine(line)
    if line:sub(1, 4) == "lua:" then
        local f, err = load(line:sub(5))
        if not f then log("compile error: " .. err) return end
        local ok, res = pcall(f)
        log((ok and "lua ok: " or "lua error: ") .. tostring(res))
    else
        local ok, err = pcall(console, line)
        log((ok and "cmd ok: " or "cmd error: ") .. line .. (ok and "" or (" " .. tostring(err))))
    end
end

local function readAndClear(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    if data == nil or data == "" then return nil end
    local w = io.open(path, "w"); if w then w:close() end
    return data
end

-- Runs on the game thread, driven by a hook on the controller's per-frame tick
-- (UE4SS's own loops stopped on the host; hooks keep working).
local function poll()
    local data = readAndClear(DIR .. "cmd.txt")
    if data then
        for line in data:gmatch("[^\r\n]+") do runLine(line) end
    end
end
local hooked, acc, lastWall = false, 0, 0
local function hookTick()
    if hooked then return end
    hooked = pcall(function()
        RegisterHook("/Game/Blueprint/Player/PlayerControllerBP.PlayerControllerBP_C:ReceiveTick", function(self, dt)
            if not self:get():IsLocalController() then return end
            lastWall = os.time()
            acc = acc + dt:get()
            if acc >= 0.5 then acc = 0; poll() end
        end)
    end)
end
hookTick()
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(500, function()
        if not hooked then hookTick() end
        if os.time() - lastWall >= 1 then poll() end
    end)
end
pcall(function() RegisterLoadMapPostHook(function() hookTick() end) end)

pcall(function()
    RegisterLoadMapPostHook(function() log("map loaded") end)
    RegisterHook("/Script/Engine.GameInstance:HandleTravelError", function(self, t) log("TRAVEL ERROR " .. tostring(t:get())) end)
    RegisterHook("/Script/Engine.GameInstance:HandleNetworkError", function(self, t, s) log("NETWORK ERROR " .. tostring(t:get())) end)
end)

T2.world = function() return FindFirstOf("GameEngine").GameViewport.World end

log("ready")
