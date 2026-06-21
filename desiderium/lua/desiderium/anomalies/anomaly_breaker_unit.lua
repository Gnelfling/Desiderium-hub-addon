--[[
DESIDERIUM Anomaly: Breaker Unit (improved AI + physical spin + safer spawn)
File: desiderium/lua/desiderium/anomalies/anomaly_breaker_unit.lua

Improvements over the prior version:
- Spawns away from players by default (random offset with min distance).
- Uses physics-based movement: applies forces toward targets so the entity "walks" without requiring NPC methods.
- Implements physical multi-axis spin by adding angular velocity to the physics object each tick.
- Better obstruction handling: when blocked, will attempt to dismantle obstructions directly.
- Adds a small per-instance local break cap and respects global throttle.
- Returns cleanup closure and the spawned entity for dispatcher tracking.
]]--

if CLIENT then return end

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._BreakerLogs = DESIDERIUM._BreakerLogs or {}

local MODEL = "models/props_wasteland/wheel03a.mdl"
local MOVE_SOUND = "ambient/machines/thumper_hit.wav"
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
local MAX_SPAWN_ATTEMPTS = 16

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
    -- Attempt various removal helpers
    pcall(function() if constraint and type(constraint.RemoveConstraints) == "function" then constraint.RemoveConstraints(target) end end)
    pcall(function() if constraint and type(constraint.RemoveAll) == "function" then constraint.RemoveAll(target) end end)

    -- heuristic: count some physics objects and claim a small number removed
    local physCount = 0
    if type(target.GetPhysicsObjectCount) == "function" then physCount = target:GetPhysicsObjectCount() or 0 end
    removed = math.min(physCount, 4)

    return removed
end

local function FindSpawnPointAwayFromPlayers(origin)
    origin = origin or Vector(0,0,0)
    local players = player.GetAll()

    -- search attempts
    for i = 1, MAX_SPAWN_ATTEMPTS do
        local off = VectorRand() * math.Rand(300, 1200)
        local candidate = origin + off

        -- ensure not too close to any player
        local ok = true
        for _, ply in ipairs(players) do
            if IsValid(ply) and ply:Alive() then
                if ply:GetPos():DistToSqr(candidate) <= (MIN_SPAWN_DIST * MIN_SPAWN_DIST) then ok = false break end
            end
        end

        if not ok then continue end

        -- trace down to find ground
        local tr = util.TraceLine({ start = candidate + Vector(0,0,300), endpos = candidate - Vector(0,0,300), filter = function(ent) return false end })
        if tr.Hit and tr.HitPos and tr.HitNormal.z > 0.5 then
            return tr.HitPos + Vector(0,0,16)
        end
    end

    -- fallback: spawn at origin offset
    return origin + Vector(0,0,64)
end

-- Global break counter (rate limit across all units)
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
        -- prefer map center if no players
        if origin == Vector(0,0,0) and #player.GetAll() > 0 then
            origin = player.GetAll()[1]:GetPos()
        end

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
            -- give a small random angular impulse for an initial spin
            phys:AddAngleVelocity(VectorRand() * (SPIN_SPEED * 20))
        end

        ent:SetMoveType(MOVETYPE_VPHYSICS)
        ent:SetSolid(SOLID_VPHYSICS)
        ent:SetCollisionGroup(COLLISION_GROUP_NONE)

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
            -- apply a force toward the target; scaled down based on mass
            local mass = 1
            if IsValid(state.phys) then mass = math.max(1, state.phys:GetMass()) end
            local force = dir * MOVE_FORCE * (mass / 50)
            state.phys:ApplyForceCenter(force)
            -- small forward nudge to keep it grounded
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

                sound.Play(BREAK_SOUND, target:GetPos(), 90, math.random(90,110), 1)
                local physobj = target:GetPhysicsObject()
                if IsValid(physobj) then physobj:ApplyForceCenter(VectorRand() * 240)
                end

                for _, n in ipairs(ents.FindInSphere(target:GetPos(), INSTABILITY_RADIUS)) do
                    if not IsValid(n) or n == target then continue end
                    if n:GetClass():find("prop_physics") and math.random() < 0.35 then
                        n._desiderium_fragile = (n._desiderium_fragile or 0) + 1
                    end
                end
            end

            return removed
        end

        timer.Create(state.timerName, 0.1, 0, function()
            local ok, err = xpcall(function()
                if not IsValid(ent) then timer.Remove(state.timerName) return end
                if not GetConVar("sv_addendum_enable"):GetBool() or CurTime() >= state.life then
                    if IsValid(ent) then ent:StopSound(MOVE_SOUND) SafeRemoveEntity(ent) end
                    timer.Remove(state.timerName)
                    return
                end

                -- physical multi-axis spin: set angular velocity toward a rotating vector
                if IsValid(state.phys) then
                    local av = VectorRand() * (SPIN_SPEED * 50)
                    state.phys:AddAngleVelocity(av)
                end

                -- regenerate break credits slowly (per second)
                local now = CurTime()
                if now - state.lastBreakTime >= 1 then
                    state.breakCredits = math.min(BREAK_RATE, state.breakCredits + BREAK_RATE * (now - state.lastBreakTime))
                    state.lastBreakTime = now
                end

                -- choose target if none or invalid
                if not IsValid(state.target) or (IsValid(state.target) and state.target:GetPos():DistToSqr(ent:GetPos()) > (SEARCH_RADIUS*SEARCH_RADIUS)) then
                    local candidates = FindStructuredTargets(ent:GetPos(), SEARCH_RADIUS, 20)
                    table.sort(candidates, function(a,b)
                        local fa = (a._desiderium_fragile or 0)
                        local fb = (b._desiderium_fragile or 0)
                        if fa ~= fb then return fa > fb end
                        return a:GetPos():DistToSqr(ent:GetPos()) < b:GetPos():DistToSqr(ent:GetPos())
                    end)
                    state.target = candidates[1]
                end

                if IsValid(state.target) then
                    InstructMoveTowards(state.target:GetPos())

                    if ent:GetPos():DistToSqr(state.target:GetPos()) <= (110*110) then
                        local removedTotal = 0
                        for i = 1, math.max(1, math.floor(state.breakCredits)) do
                            if not CanBreakMore() then break end
                            local r = AttemptDismantle(state.target)
                            if r > 0 then removedTotal = removedTotal + r else break end
                        end
                        if removedTotal <= 0 then
                            state.perTargetCooldowns[state.target:EntIndex()] = CurTime() + 0.8
                            state.target = nil
                        else
                            table.insert(DESIDERIUM._BreakerLogs, { time = CurTime(), event = "dismantle", target = state.target, count = removedTotal })
                        end
                    end
                else
                    -- wander
                    local wanderPos = ent:GetPos() + VectorRand() * 150
                    InstructMoveTowards(wanderPos)
                end

                -- obstruction handling: if velocity is very low and there's something in front, try to break it
                if IsValid(state.phys) then
                    local vel = state.phys:GetVelocity()
                    if vel:Length() < 10 then
                        -- trace forward a short distance
                        local fwd = ent:GetForward()
                        local tr = util.TraceLine({ start = ent:GetPos() + Vector(0,0,24), endpos = ent:GetPos() + fwd * 60 + Vector(0,0,24), filter = ent })
                        if tr.Hit and IsValid(tr.Entity) and tr.Entity ~= ent then
                            AttemptDismantle(tr.Entity)
                        end
                    end
                end

            end, debug.traceback)

            if not ok then
                print("[desiderium] breaker unit timer error:", err)
                if IsValid(ent) then SafeRemoveEntity(ent) end
                timer.Remove(state.timerName)
            end
        end)

        -- Return cleanup closure and the entity so dispatcher can watch it
        return (function()
            if timer.Exists(state.timerName) then timer.Remove(state.timerName) end
            if IsValid(ent) then ent:StopSound(MOVE_SOUND) SafeRemoveEntity(ent) end
        end), ent
    end,

    Cleanup = function(ctx) end,
})
