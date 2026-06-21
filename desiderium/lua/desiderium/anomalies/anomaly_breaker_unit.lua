--[[
DESIDERIUM Anomaly: Breaker Unit
File: desiderium/lua/desiderium/anomalies/anomaly_breaker_unit.lua

Behavior:
- Spawns a small mechanical unit (uses a simple prop model) that
  visually spins on all axes and walks toward built/structured objects.
- On contact it attempts to dismantle structure connections: remove
  welds/constraints and sever obvious vehicle attachments. It does not
  deal direct player damage.
- Instability spreads locally: when a target loses constraints nearby
  entities are more likely to be processed next.

Safety:
- Constraint removals are rate-limited (per-target and per-anomaly).
- All potentially-absent engine calls are wrapped in pcall/type checks.
- Timer callbacks are wrapped in xpcall so errors won't silently leave
  the instance stuck; dispatcher entity-watch will also unregister
  the instance when the entity is removed.

Tunables (top of file) are deliberately conservative. Adjust as needed.
]]--

if CLIENT then return end

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._BreakerLogs = DESIDERIUM._BreakerLogs or {}

local MODEL = "models/props_wasteland/wheel03a.mdl"
local MOVE_SOUND = "ambient/machines/thumper_hit.wav"
local BREAK_SOUND = "physics/metal/metal_box_impact_bullet1.wav"
local SPARK_EFFECT = "cball_explode" -- placeholder

-- Tunables
local WEIGHT = 1                -- selection weight for dispatcher
local COOLDOWN = 160            -- anomaly cooldown
local INSTANCE_EXPOSURE = 35    -- exposure contribution while active (rank 1)
local MOVE_SPEED = 80           -- base movement speed
local SEARCH_RADIUS = 900       -- how far it looks for structured targets
local BREAK_RATE = 3            -- max constraint removals per second (per unit)
local TARGET_COOLDOWN = 1.2     -- seconds before re-processing same target
local INSTABILITY_RADIUS = 220  -- radius in which instability spreads
local GLOBAL_BREAK_CAP = 18     -- global cap per tick to avoid mass breakage
local SPIN_SPEED = 8            -- visual spin multiplier

-- Debug convar to disable destructive behavior during testing
CreateConVar("desiderium_debug_disable_destruction", "0", FCVAR_SERVER_CAN_EXECUTE, "If set, Breaker Unit will not remove constraints (testing safe mode)")

-- Safe helpers
local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, res = pcall(fn, ...)
    return ok, res
end

local function SafeSetSchedule(ent, sched)
    if not IsValid(ent) then return end
    if type(ent.SetSchedule) == "function" then
        pcall(ent.SetSchedule, ent, sched)
    end
end

local function SafeSetLastPosition(ent, pos)
    if not IsValid(ent) then return end
    if type(ent.SetLastPosition) == "function" then
        pcall(ent.SetLastPosition, ent, pos)
    end
end

local function SafeStartActivity(ent, act)
    if not IsValid(ent) then return end
    if type(ent.StartActivity) == "function" then
        pcall(function() ent:StartActivity(act) end)
        return
    end
    -- fallback to schedule if StartActivity missing
    if type(ent.SetSchedule) == "function" then
        pcall(function() ent:SetSchedule(SCHED_FORCED_GO) end)
        return
    end
    if type(ent.SetNPCState) == "function" then
        pcall(function() ent:SetNPCState(NPC_STATE_IDLE) end)
    end
end

-- Best-effort constraint removal
local function RemoveConstraintsSafe(target)
    if not IsValid(target) then return 0 end
    if GetConVar("desiderium_debug_disable_destruction"):GetBool() then return 0 end

    local removed = 0

    -- try known constraint removal helpers, wrapped in pcall
    local try = function(fn, ...)
        if type(fn) ~= "function" then return end
        pcall(function(...) fn(...) end, ...)
    end

    -- common constraint types
    pcall(function() try(constraint.RemoveConstraints, target, "Weld") end)
    pcall(function() try(constraint.RemoveConstraints, target, "Axis") end)
    pcall(function() try(constraint.RemoveConstraints, target, "NoCollide") end)
    pcall(function() try(constraint.RemoveConstraints, target, "BallSocket") end)

    -- attempt a generic removal call if available
    pcall(function() if type(constraint.RemoveAll) == "function" then constraint.RemoveAll(target) end end)

    -- approximate count: break up to a few constraints by applying small physics impulses
    local physCount = 0
    if type(target.GetPhysicsObjectCount) == "function" then
        physCount = target:GetPhysicsObjectCount() or 0
    end
    removed = math.min( physCount, 4 )

    return removed
end

-- Find structured targets: clusters of prop_physics, vehicles, contraptions
local function FindStructuredTargets(origin, radius, max)
    local candidates = {}
    for _, ent in ipairs(ents.FindInSphere(origin, radius)) do
        if not IsValid(ent) then continue end
        local cls = ent:GetClass() or ""
        if cls:find("prop_physics") or cls:find("prop_vehicle") or cls:find("gmod_vehicle") then
            table.insert(candidates, ent)
            if #candidates >= (max or 8) then break end
        end
    end
    return candidates
end

-- Track global breaking per tick to avoid runaway
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

-- Breaker anomaly registration
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

        local origin = (ctx and ctx.origin) or Vector(0,0,64)
        local plys = player.GetAll()
        if #plys > 0 then origin = plys[ math.random(#plys) ]:GetPos() + Vector(0,0,40) end

        local ent = ents.Create("prop_physics")
        if not IsValid(ent) then return false end

        ent:SetModel(MODEL)
        ent:SetPos(origin + Vector(math.Rand(-40,40), math.Rand(-40,40), 0))
        ent:Spawn()
        ent:Activate()
        ent:SetMoveType(MOVETYPE_STEP)
        ent:SetSolid(SOLID_VPHYSICS)
        ent:SetCollisionGroup(COLLISION_GROUP_NONE)

        -- visual: make the prop non-shadow and slightly tinted
        if type(ent.SetRenderMode) == "function" then
            pcall(function() ent:SetRenderMode(RENDERMODE_TRANSALPHA) end)
        end

        -- play a looping mechanical sound
        ent:EmitSound(MOVE_SOUND, 80, 100)

        -- State
        local state = {
            ent = ent,
            target = nil,
            lastTarget = nil,
            lastBreakTime = 0,
            breakCredits = BREAK_RATE,
            perTargetCooldowns = {}, -- map ent:EntIndex() -> time
            lastSpin = RealTime(),
            lastThink = CurTime(),
            life = CurTime() + 900, -- long-lived by default
            timerName = "desiderium_breaker_" .. tostring(ent:EntIndex()),
        }

        table.insert(DESIDERIUM._BreakerLogs, { time = CurTime(), event = "spawn", ent = ent })
        if DESIDERIUM.BroadcastGateMessage then
            DESIDERIUM.BroadcastGateMessage("[DESIDERIUM SERVER] ANOMALY DATABASE DETECTED, BREAKER UNIT HAS ENTERED.", false)
            timer.Simple(4, function()
                if IsValid(ent) and GetConVar("sv_addendum_enable"):GetBool() then
                    DESIDERIUM.BroadcastGateMessage("[DESIDERIUM SERVER] DANGEROUS RANK DATABASE > RANK 1", false)
                    sound.Play("ambient/alarms/klaxon1.wav", ent:GetPos(), 100, 110, 0.8)
                end
            end)
        end

        -- Helper: instruct movement
        local function InstructMoveTo(entObj, pos)
            if not IsValid(entObj) then return false end
            SafeSetLastPosition(entObj, pos)
            SafeSetSchedule(entObj, SCHED_FORCED_GO)
            return true
        end

        -- Core dismantle attempt on a single target
        local function AttemptDismantle(target)
            if not IsValid(target) then return 0 end
            if not CanBreakMore() then return 0 end

            local idx = target:EntIndex()
            local now = CurTime()
            if state.perTargetCooldowns[idx] and state.perTargetCooldowns[idx] > now then
                return 0
            end

            -- consume credits
            local allowed = math.floor(state.breakCredits)
            if allowed <= 0 then return 0 end

            local removed = 0
            -- remove constraints safely (best-effort)
            removed = RemoveConstraintsSafe(target)

            if removed > 0 then
                NoteBreak(removed)
                state.perTargetCooldowns[idx] = now + TARGET_COOLDOWN
                -- play break sound and an effect
                sound.Play(BREAK_SOUND, target:GetPos(), 90, math.random(90,110), 1)
                local ang = target:GetAngles()
                -- give a small impulse to make it look like it broke free
                local phys = target:GetPhysicsObject()
                if IsValid(phys) then phys:ApplyForceCenter(VectorRand() * 120) end

                -- mark instability: nearby props will be considered next
                for _, n in ipairs(ents.FindInSphere(target:GetPos(), INSTABILITY_RADIUS)) do
                    if not IsValid(n) or n == target then continue end
                    -- small chance to tag them for priority
                    if n:GetClass():find("prop_physics") and math.random() < 0.35 then
                        n._desiderium_fragile = (n._desiderium_fragile or 0) + 1
                    end
                end
            end

            return removed
        end

        -- Timer loop for movement, spinning, and dismantle attempts
        timer.Create(state.timerName, 0.12, 0, function()
            local ok, err = xpcall(function()
                if not IsValid(ent) then timer.Remove(state.timerName) return end

                if not GetConVar("sv_addendum_enable"):GetBool() or CurTime() >= state.life then
                    -- cleanup
                    if IsValid(ent) then
                        ent:StopSound(MOVE_SOUND)
                        SafeCall(function() SafeRemoveEntity(ent) end)
                    end
                    timer.Remove(state.timerName)
                    return
                end

                -- Visual spin: multi-axis spin based on RealTime() so it's smooth
                local rt = RealTime()
                local dt = rt - state.lastSpin
                state.lastSpin = rt
                local a = ent:GetAngles()
                a:RotateAroundAxis(a:Up(), SPIN_SPEED * dt * 360)
                a:RotateAroundAxis(a:Right(), (SPIN_SPEED*0.6) * dt * 360)
                a:RotateAroundAxis(a:Forward(), (SPIN_SPEED*0.4) * dt * 360)
                ent:SetAngles(a)

                -- Throttle break credits regeneration
                local now = CurTime()
                if now - state.lastBreakTime >= 1 then
                    state.breakCredits = math.min(BREAK_RATE, state.breakCredits + BREAK_RATE * (now - state.lastBreakTime))
                    state.lastBreakTime = now
                end

                -- Select target: prefer fragile-tagged or clustered props/vehicles
                if not IsValid(state.target) or (IsValid(state.target) and state.target:GetPos():DistToSqr(ent:GetPos()) > (SEARCH_RADIUS*SEARCH_RADIUS)) then
                    local candidates = FindStructuredTargets(ent:GetPos(), SEARCH_RADIUS, 16)
                    -- sort candidates by fragility and distance
                    table.sort(candidates, function(a,b)
                        local fa = (a._desiderium_fragile or 0)
                        local fb = (b._desiderium_fragile or 0)
                        if fa ~= fb then return fa > fb end
                        return a:GetPos():DistToSqr(ent:GetPos()) < b:GetPos():DistToSqr(ent:GetPos())
                    end)
                    state.target = candidates[1]
                end

                if IsValid(state.target) then
                    -- move toward target
                    InstructMoveTo(ent, state.target:GetPos())

                    -- if close, attempt to dismantle
                    if ent:GetPos():DistToSqr(state.target:GetPos()) <= (100*100) then
                        -- attempt a handful of breaks up to available credits
                        local attempts = math.max(1, math.floor(state.breakCredits))
                        local removedTotal = 0
                        for i = 1, attempts do
                            if not CanBreakMore() then break end
                            local removed = AttemptDismantle(state.target)
                            if removed > 0 then
                                state.breakCredits = math.max(0, state.breakCredits - removed)
                                removedTotal = removedTotal + removed
                            else
                                break
                            end
                        end
                        if removedTotal > 0 then
                            table.insert(DESIDERIUM._BreakerLogs, { time = CurTime(), event = "dismantle", target = state.target, count = removedTotal })
                        else
                            -- nothing to break: pick a new target after a small delay
                            state.perTargetCooldowns[state.target:EntIndex()] = CurTime() + 0.8
                            state.target = nil
                        end
                    end
                else
                    -- no target: wander slowly to a random nearby point
                    local wanderPos = ent:GetPos() + VectorRand() * 180
                    InstructMoveTo(ent, wanderPos)
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
            if IsValid(ent) then
                ent:StopSound(MOVE_SOUND)
                SafeRemoveEntity(ent)
            end
        end), ent
    end,

    Cleanup = function(ctx)
        -- nothing global to do here; instances clean themselves
    end,
})
