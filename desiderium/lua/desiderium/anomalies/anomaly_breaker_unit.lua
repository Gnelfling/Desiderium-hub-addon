--[[
DESIDERIUM Anomaly: Breaker Unit (idle/reactivate, prop‑priority, zombie loop)
File: desiderium/lua/desiderium/anomalies/anomaly_breaker_unit.lua
]]--

if CLIENT then return end

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._BreakerLogs = DESIDERIUM._BreakerLogs or {}
if #DESIDERIUM._BreakerLogs > 100 then
    table.remove(DESIDERIUM._BreakerLogs, 1)
end

local MODEL = "models/props_wasteland/wheel03a.mdl"
local MOVE_SOUND = "npc/fast_zombie/gurgle_loop1.wav"
local BREAK_SOUND = "physics/metal/metal_box_impact_bullet1.wav"
local SPARK_EFFECT = "cball_explode"

-- Tunables
local WEIGHT = 1
local COOLDOWN = 160
local INSTANCE_EXPOSURE = 35
local MOVE_FORCE = 800
local SEARCH_RADIUS = 1200
local BREAK_RATE = 4
local TARGET_COOLDOWN = 1.2
local INSTABILITY_RADIUS = 220
local GLOBAL_BREAK_CAP = 20
local SPIN_SPEED = 18
local MIN_SPAWN_DIST = 400
local MAX_SPAWN_ATTEMPTS = 64

-- Idle/reactivate config
local ACTIVE_DURATION = 12
local ACTIVATION_RADIUS = 350
local IDLE_CHECK_INTERVAL = 0.35

CreateConVar("desiderium_debug_disable_destruction", "0", FCVAR_SERVER_CAN_EXECUTE, "Disable Breaker Unit destructive behavior (testing)")

-- Utilities
local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, res = pcall(fn, ...)
    return ok, res
end

local function RemoveConstraintsSafe(target)
    if not IsValid(target) then return 0 end
    if GetConVar("desiderium_debug_disable_destruction"):GetBool() then return 0 end

    local removed = 0
    pcall(function() constraint.RemoveConstraints(target) end)
    pcall(function() constraint.RemoveAll(target) end)

    local physCount = 0
    if target.GetPhysicsObjectCount then physCount = target:GetPhysicsObjectCount() or 0 end
    removed = math.min(physCount, 4)
    return removed
end

-- Spawn point selection
local function FindRandomMapSpawn()
    for i = 1, MAX_SPAWN_ATTEMPTS do
        local radius = math.Rand(800, 6000)
        local ang = math.Rand(0, math.pi * 2)
        local sample = Vector(math.cos(ang) * radius, math.sin(ang) * radius, 0)
        local tr = util.TraceLine({
            start = sample + Vector(0, 0, 3000),
            endpos = sample - Vector(0, 0, 3000),
            mask = MASK_SOLID_BRUSHONLY
        })
        if tr.Hit and tr.HitNormal.z > 0.4 then
            return tr.HitPos + Vector(0, 0, 16)
        end
    end
    return Vector(0, 0, 64)
end

local function FindSpawnPointAwayFromPlayers()
    local players = player.GetAll()
    for _ = 1, MAX_SPAWN_ATTEMPTS do
        local candidate = FindRandomMapSpawn()
        local ok = true
        for _, ply in ipairs(players) do
            if IsValid(ply) and ply:Alive() and ply:GetPos():DistToSqr(candidate) <= (MIN_SPAWN_DIST ^ 2) then
                ok = false
                break
            end
        end
        if ok then return candidate end
    end
    return FindRandomMapSpawn()
end

-- Target selection with prop priority
local function FindTargets(origin, radius)
    local targets = {}
    for _, ent in ipairs(ents.FindInSphere(origin, radius)) do
        if not IsValid(ent) then continue end
        local cls = ent:GetClass()
        if cls:find("prop_physics") or cls:find("vehicle") or cls:find("gmod_vehicle") or cls:find("prop_vehicle") then
            targets[#targets + 1] = ent
        end
    end
    -- Sort: prop_physics first, then others
    table.sort(targets, function(a, b)
        local ca = a:GetClass():find("prop_physics") and 1 or 0
        local cb = b:GetClass():find("prop_physics") and 1 or 0
        return ca > cb
    end)
    return targets
end

-- Global break limiter
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

-- Anomaly registration
DESIDERIUM.RegisterAnomaly("breaker_unit", {
    Weight = WEIGHT,
    Cooldown = COOLDOWN,
    MinPlayers = 1,
    InstanceExposureWeight = INSTANCE_EXPOSURE,

    CanTrigger = function()
        return #player.GetAll() >= 1 and GetConVar("sv_addendum_enable"):GetBool()
    end,

    Trigger = function(ctx)
        if not GetConVar("sv_addendum_enable"):GetBool() then return false end

        local origin = (ctx and ctx.origin) or Vector(0,0,0)
        if origin == Vector(0,0,0) and #player.GetAll() > 0 then
            origin = player.GetAll()[1]:GetPos()
        end

        local spawnPos = FindSpawnPointAwayFromPlayers()

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

        -- State
        local state = {
            ent = ent,
            phys = phys,
            target = nil,
            perTargetCooldowns = {},
            lastBreakTime = CurTime(),
            breakCredits = BREAK_RATE,
            life = CurTime() + 900,
            timerName = "desiderium_breaker_" .. ent:EntIndex(),
            activeUntil = CurTime() + ACTIVE_DURATION,
            isActive = true,
            idleCheckNext = CurTime() + IDLE_CHECK_INTERVAL,
        }

        -- Start loop sound
        ent:EmitSound(MOVE_SOUND, 80, 100)

        -- Log
        table.insert(DESIDERIUM._BreakerLogs, { time = CurTime(), event = "spawn", ent = ent, pos = spawnPos })
        if #DESIDERIUM._BreakerLogs > 100 then table.remove(DESIDERIUM._BreakerLogs, 1) end

        if DESIDERIUM.BroadcastGateMessage then
            DESIDERIUM.BroadcastGateMessage("[DESIDERIUM SERVER] ANOMALY DATABASE DETECTED, BREAKER UNIT HAS ENTERED.", false)
            timer.Simple(4, function()
                if IsValid(ent) and GetConVar("sv_addendum_enable"):GetBool() then
                    DESIDERIUM.BroadcastGateMessage("[DESIDERIUM SERVER] DANGEROUS RANK DATABASE > RANK 1", false)
                    sound.Play("ambient/alarms/klaxon1.wav", ent:GetPos(), 100, 110, 0.8)
                end
            end)
        end

        -- Helper functions
        local function StopSound()
            if IsValid(ent) then
                ent:StopSound(MOVE_SOUND)
            end
        end

        local function StartSound()
            if IsValid(ent) then
                ent:EmitSound(MOVE_SOUND, 80, 100)
            end
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
            end
            return removed
        end

        local function ChooseBestTarget()
            local targets = FindTargets(ent:GetPos(), SEARCH_RADIUS)
            for _, t in ipairs(targets) do
                if IsValid(t) then
                    return t
                end
            end
            return nil
        end

        -- Main update timer
        timer.Create(state.timerName, 0.08, 0, function()
            if not IsValid(ent) then
                timer.Remove(state.timerName)
                return
            end

            local now = CurTime()

            -- Check lifetime
            if now > state.life then
                ent:Remove()
                timer.Remove(state.timerName)
                return
            end

            -- Idle/reactivate logic
            if not state.isActive then
                -- Idle: check if something approaches
                if state.idleCheckNext <= now then
                    state.idleCheckNext = now + IDLE_CHECK_INTERVAL
                    local targets = FindTargets(ent:GetPos(), ACTIVATION_RADIUS)
                    local found = false
                    for _, t in ipairs(targets) do
                        if IsValid(t) then
                            found = true
                            break
                        end
                    end
                    if found then
                        state.isActive = true
                        state.activeUntil = now + ACTIVE_DURATION
                        StartSound()
                        state.phys:Wake()
                    end
                end
                -- Do nothing else while idle (sound already stopped)
                return
            end

            -- Active behaviour
            -- Refill break credits
            state.breakCredits = math.min(BREAK_RATE, state.breakCredits + 0.02)

            -- Check if we should go idle early (no good target)
            local target = state.target
            if not IsValid(target) then
                target = ChooseBestTarget()
                state.target = target
            end

            if not IsValid(target) then
                -- No target: chance to go idle early (boredom)
                if math.random() < 0.02 then
                    state.isActive = false
                    StopSound()
                    state.phys:Sleep()
                    return
                end
                -- Otherwise just spin in place
                if IsValid(state.phys) then
                    state.phys:AddAngleVelocity(VectorRand() * (SPIN_SPEED * 2))
                end
                return
            end

            -- Move toward target
            InstructMoveTowards(target:GetPos())

            -- Spin
            if IsValid(state.phys) then
                state.phys:AddAngleVelocity(VectorRand() * (SPIN_SPEED * 3))
            end

            -- Dismantle if close enough
            local dist = ent:GetPos():DistTo(target:GetPos())
            if dist < INSTABILITY_RADIUS then
                local broke = AttemptDismantle(target)
                if broke > 0 then
                    -- Play break sound
                    sound.Play(BREAK_SOUND, ent:GetPos(), 80, 100)
                    local effect = EffectData()
                    effect:SetOrigin(target:GetPos())
                    util.Effect(SPARK_EFFECT, effect, true, true)
                    -- Clear target if dismantled
                    if not IsValid(target) then
                        state.target = nil
                    end
                end
            end

            -- Check if still active duration
            if now > state.activeUntil then
                state.isActive = false
                StopSound()
                state.phys:Sleep()
            end

            -- Random chance to drop target and go idle early (more unpredictable)
            if IsValid(state.target) and math.random() < 0.005 then
                state.target = nil
                state.isActive = false
                StopSound()
                state.phys:Sleep()
            end
        end)

        -- Cleanup on entity removal
        ent:AddCallback("OnRemove", function()
            StopSound()
            timer.Remove(state.timerName)
        end)

        return true
    end
})
