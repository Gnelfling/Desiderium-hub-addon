--[[
DESIDERIUM Anomaly: Breaker Unit (idle/reactivate, prop-priority, zombie loop)
File: desiderium/lua/desiderium/anomalies/anomaly_breaker_unit.lua

Updates applied:
- Uses npc/fast_zombie/gurgle_loop1.wav as loop sound while active.
- Increased chance to enter idle (shorter ACTIVE_DURATION and random early-sleep when no good target).
- Sleeps (stops sound) while idle and wakes (plays sound) when a player/prop approaches.
- Prioritizes prop_physics targets over vehicles when selecting targets.
- Spawns farther from players by increasing spawn attempts and sampling.
]]--

if CLIENT then return end

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._BreakerLogs = DESIDERIUM._BreakerLogs or {}

local MODEL = "models/props_wasteland/wheel03a.mdl"
local MOVE_SOUND = "npc/fast_zombie/gurgle_loop1.wav"
local BREAK_SOUND = "physics/metal/metal_box_impact_bullet1.wav"
local SPARK_EFFECT = "cball_explode"

-- Tunables
local WEIGHT = 1
local COOLDOWN = 160
local INSTANCE_EXPOSURE = 35
local MOVE_FORCE = 800       -- force applied toward target
local SEARCH_RADIUS = 1200
local BREAK_RATE = 4         -- constraints removed per second per unit
local TARGET_COOLDOWN = 1.2
local INSTABILITY_RADIUS = 220
local GLOBAL_BREAK_CAP = 20
local SPIN_SPEED = 18        -- higher -> faster visual spin
local MIN_SPAWN_DIST = 400   -- minimum distance from players when picking spawn
local MAX_SPAWN_ATTEMPTS = 64 -- increased sampling for more random spawns

-- Idle/reactivate config
local ACTIVE_DURATION = 12       -- seconds active before going idle (shorter -> more likely to sleep)
local ACTIVATION_RADIUS = 350    -- wakes when target enters this radius
local IDLE_CHECK_INTERVAL = 0.35 -- how often idle units scan for approaching targets

CreateConVar("desiderium_debug_disable_destruction", "0", FCVAR_SERVER_CAN_EXECUTE, "Disable Breaker Unit destructive behavior (testing)")

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, res = pcall(fn, ...)
    return ok, res
end

local function RemoveConstraintsSafe(target)
    if not IsValid(target) then return 0 end
    if GetConVar("desiderium_debug_disable_destruction"):GetBool() then return 0 end

    local removed = 0
    pcall(function() if constraint and type(constraint.RemoveConstraints) == "function" then constraint.RemoveConstraints(target) end end)
    pcall(function() if constraint and type(constraint.RemoveAll) == "function" then constraint.RemoveAll(target) end end)

    local physCount = 0
    if type(target.GetPhysicsObjectCount) == "function" then physCount = target:GetPhysicsObjectCount() or 0 end
    removed = math.min(physCount, 4)

    return removed
end

-- Pick a random map point by sampling offsets from map origin and tracing down
local function FindRandomMapSpawn()
    local attempts = MAX_SPAWN_ATTEMPTS
    local mapcenter = Vector(0,0,0)
    for i = 1, attempts do
        local radius = math.Rand(800, 6000)
        local ang = math.Rand(0, math.pi * 2)
        local off = Vector(math.cos(ang) * radius, math.sin(ang) * radius, 0)
        local sample = mapcenter + off
        local tr = util.TraceLine({ start = sample + Vector(0,0,3000), endpos = sample - Vector(0,0,3000), mask = MASK_SOLID_BRUSHONLY })
        if tr.Hit and tr.HitPos and tr.HitNormal.z > 0.4 then
            return tr.HitPos + Vector(0,0,16)
        end
    end
    return Vector(0,0,64)
end

local function FindSpawnPointAwayFromPlayers(origin)
    origin = origin or Vector(0,0,0)
    local players = player.GetAll()
    for i = 1, MAX_SPAWN_ATTEMPTS do
        local candidate = FindRandomMapSpawn()
        local ok = true
        for _, ply in ipairs(players) do
            if IsValid(ply) and ply:Alive() then
                if ply:GetPos():DistToSqr(candidate) <= (MIN_SPAWN_DIST * MIN_SPAWN_DIST) then ok = false break end
            end
        end
        if ok then return candidate end
    end
    return FindRandomMapSpawn()
end

local function FindStructuredTargets(origin, radius, max)
    local candidates = {}
    for _, ent in ipairs(ents.FindInSphere(origin, radius)) do
        if not IsValid(ent) then continue end
        local cls = ent:GetClass() or ""
        if cls:find("prop_physics") or cls:find("vehicle") or cls:find("gmod_vehicle") or cls:find("prop_vehicle") then
            table.insert(candidates, ent)
            if #candidates >= (max or 12) then break end
        end
    end
    return candidates
end

DESIDERIUM._GlobalBreakCounter = DESIDERIUM._GlobalBreakCounter or { last = 0, count = 0 }
local function CanBreakMore()
    local t = CurTime()
    if t > DESIDERIUM._GlobalBreakCounter.last + 1 then
        DESIDERIUM._GlobalBreakCounter.last = t
        DESIDERIUM._GlobalBreakCounter.count = 0
    end
    return DESIDERIUM._GlobalBreakCounter.count < GLOBAL_BREAK_CAP
end
local function NoteBreak(n)
    DESIDERIUM._GlobalBreakCounter.count = DESIDERIUM._GlobalBreakCounter.count + (n or 1)
end

DESIDERIUM.RegisterAnomaly("breaker_unit", {
    Weight = WEIGHT,
    Cooldown = COOLDOWN,
    MinPlayers = 1,
    InstanceExposureWeight = INSTANCE_EXPOSURE,

    CanTrigger = function(ctx)
        return #player.GetAll() >= 1 and GetConVar("sv_addendum_enable"):GetBool()
    end,

    Trigger = function(ctx)
        if not GetConVar("sv_addendum_enable"):GetBool() then return false end

        local origin = (ctx and ctx.origin) or Vector(0,0,0)
        if origin == Vector(0,0,0) and #player.GetAll() > 0 then origin = player.GetAll()[1]:GetPos() end

        local spawnPos = FindSpawnPointAwayFromPlayers(origin)

        local ent = ents.Create("prop_physics")
        if not IsValid(ent) then return false end

        ent:SetModel(MODEL)
        ent:SetPos(spawnPos)
        ent:Spawn()
        ent:Activate()

        local phys = ent:GetPhysicsObject()
        if IsValid(phys) then
            phys:EnableMotion(true)
            phys:Wake()
            phys:AddAngleVelocity(VectorRand() * (SPIN_SPEED * 20))
        end

        ent:SetMoveType(MOVETYPE_VPHYSICS)
        ent:SetSolid(SOLID_VPHYSICS)
        ent:SetCollisionGroup(COLLISION_GROUP_NONE)

        -- start active sound
        ent:EmitSound(MOVE_SOUND, 80, 100)

        local state = {
            ent = ent,
            phys = phys,
            target = nil,
            perTargetCooldowns = {},
            lastBreakTime = CurTime(),
            breakCredits = BREAK_RATE,
            lastSpin = RealTime(),
            life = CurTime() + 900,
            timerName = "desiderium_breaker_" .. tostring(ent:EntIndex()),
            activeUntil = CurTime() + ACTIVE_DURATION,
            isActive = true,
            idleCheckNext = CurTime() + IDLE_CHECK_INTERVAL,
        }

        table.insert(DESIDERIUM._BreakerLogs, { time = CurTime(), event = "spawn", ent = ent, pos = spawnPos })
        if DESIDERIUM.BroadcastGateMessage then
            DESIDERIUM.BroadcastGateMessage("[DESIDERIUM SERVER] ANOMALY DATABASE DETECTED, BREAKER UNIT HAS ENTERED.", false)
            timer.Simple(4, function()
                if IsValid(ent) and GetConVar("sv_addendum_enable"):GetBool() then
                    DESIDERIUM.BroadcastGateMessage("[DESIDERIUM SERVER] DANGEROUS RANK DATABASE > RANK 1", false)
                    sound.Play("ambient/alarms/klaxon1.wav", ent:GetPos(), 100, 110, 0.8)
                end
            end)
        end

        local function InstructMoveTowards(targetPos)
            if not IsValid(ent) or not IsValid(state.phys) then return end
            local dir = (targetPos - ent:GetPos())
            dir.z = 0
            local dist = dir:Length()
            if dist < 1 then return end
            dir:Normalize()
            local mass = 1
            if IsValid(state.phys) then mass = math.max(1, state.phys:GetMass()) end
            local force = dir * MOVE_FORCE * (mass / 50)
            state.phys:ApplyForceCenter(force)
            state.phys:ApplyForceOffset(force * 0.05, ent:GetPos() + ent:GetForward() * 10)
        end

        local function AttemptDismantle(target)
            if not IsValid(target) then return 0 end
            if GetConVar("desiderium_debug_disable_destruction"):GetBool() then return 0 end
            if not CanBreakMore() then return 0 end

            local idx = target:EntIndex()
            local now = CurTime()
            if state.perTargetCooldowns[idx] and state.perTargetCooldowns[idx] > now then return 0 end

            local allowed = math.floor(state.breakCredits)
            if allowed <= 0 then return 0 end

            local removed = RemoveConstraintsSafe(target)
            if removed > 0 then
                NoteBreak(removed)
                state.perTargetCooldowns[idx] = now + TARGET_COOLDOWN
                state.breakCredits = math.max(0, state.breakCredits - removed)

We need to continue editing file after line 230 to complete modifications; but tool create_or_update_file will replace whole file content. We'll prepare a full file now. Continue to produce rest of file including early-sleep snippet and prop-priority sort. Provide full content. Let's craft final file content accordingly. We already created earlier similar updated content; we can use that with added early-sleep and sound control stops/starts already. We must ensure ent:StopSound() on entering idle and ent:EmitSound on reactivating. In our previous create_or_update_file earlier, we had similar behavior. We'll generate final file content accordingly when calling create_or_update_file. We already attempted a create earlier; now we must overwrite with updated content including the early-sleep snippet and prop priority. Let's produce the full file content now. We'll call create_or_update_file with the updated content. Let's craft content. I'll incorporate earlier code but add early-sleep random chance earlier. Also add prop-priority comparator. Ensure sound stop/play when idle/reactivate implemented (we did earlier). Good. Now call create_or_update_file. We'll set message commit accordingly. Let's produce the call. (We must include sha? create_or_update_file guidance: If updating existing file, must include sha blob of file being replaced. We previously used create_or_update_file without sha and API accepted; our tool's create_or_update_file function requires sha param maybe optional. But earlier the tool accepted without sha. The tool will handle. We'll call again.) Let's proceed. We'll craft content as in previous block but ensure early-sleep snippet present. We'll include the full file content. Then commit message: 