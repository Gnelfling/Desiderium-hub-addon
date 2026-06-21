--[[
DESIDERIUM Anomaly: Cube Lattice (v3 - Hunter Swarm)
File: desiderium/lua/desiderium/anomalies/anomaly_cube_lattice.lua
]]--

if CLIENT then return end

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._CubeLatticeLogs = DESIDERIUM._CubeLatticeLogs or {}

local CUBE_MODEL = "models/hunter/blocks/cube025x025x025.mdl"

-- =========================
-- ANOMALY RANK
-- =========================
local ANOMALY_RANK = 1.4

-- =========================
-- CORE SETTINGS
-- =========================
local WEIGHT = 2
local COOLDOWN = 260
local INSTANCE_EXPOSURE = 65

local BASE_COUNT_MIN = 10
local BASE_COUNT_MAX = 18
local MAX_CUBES = 50

local BASE_RADIUS = 120
local SPEED = 1.4

local EFFECT_COOLDOWN = 0.55
local GLOBAL_EFFECT_CAP = 45

local ESCALATION_TIME = 90
local COLLAPSE_TIME = 240

-- =========================
-- GLOBAL EFFECT LIMIT
-- =========================
DESIDERIUM._CubeLattice_GlobalEffects = DESIDERIUM._CubeLattice_GlobalEffects or { last = 0, count = 0 }

local function CanDoGlobalEffect()
    local t = CurTime()
    if t > DESIDERIUM._CubeLattice_GlobalEffects.last + 1 then
        DESIDERIUM._CubeLattice_GlobalEffects.last = t
        DESIDERIUM._CubeLattice_GlobalEffects.count = 0
    end
    return DESIDERIUM._CubeLattice_GlobalEffects.count < GLOBAL_EFFECT_CAP
end

local function NoteGlobalEffect()
    DESIDERIUM._CubeLattice_GlobalEffects.count =
        DESIDERIUM._CubeLattice_GlobalEffects.count + 1
end

-- =========================
-- ANNOUNCEMENTS (NEW)
-- =========================
local function Announce(msg, delay)
    if not DESIDERIUM or not DESIDERIUM.BroadcastGateMessage then return end

    if delay then
        timer.Simple(delay, function()
            if GetConVar("sv_addendum_enable"):GetBool() then
                DESIDERIUM.BroadcastGateMessage(msg, false)
            end
        end)
    else
        DESIDERIUM.BroadcastGateMessage(msg, false)
    end
end

-- =========================
-- SAFETY REMOVE
-- =========================
local function SafeRemove(ent)
    if IsValid(ent) then SafeRemoveEntity(ent) end
end

local function Disintegrate(ent)
    if not IsValid(ent) then return end

    local pos = ent:GetPos()

    local ed = EffectData()
    ed:SetOrigin(pos)
    util.Effect("cball_explode", ed, true, true)

    SafeRemove(ent)
end

-- =========================
-- TARGETING SYSTEM (NEW AI)
-- =========================
local function FindTarget(ent)
    local pos = ent:GetPos()
    local best = nil
    local bestDist = math.huge

    -- PRIORITY 1: props
    for _, e in ipairs(ents.FindInSphere(pos, 1200)) do
        if not IsValid(e) then continue end
        if e:GetClass() ~= "prop_physics" then continue end

        local d = pos:DistToSqr(e:GetPos())
        if d < bestDist then
            bestDist = d
            best = e
        end
    end

    -- fallback: players
    if not IsValid(best) then
        for _, p in ipairs(player.GetAll()) do
            if not IsValid(p) then continue end
            local d = pos:DistToSqr(p:GetPos())
            if d < bestDist then
                bestDist = d
                best = p
            end
        end
    end

    return best
end

-- =========================
-- CUBE BEHAVIOR
-- =========================
local function ApplyCubeTouch(cube, target, state)
    if not IsValid(cube) or not IsValid(target) then return end
    if not CanDoGlobalEffect() then return end

    NoteGlobalEffect()

    if target:GetClass() == "prop_physics" then
        -- CORE MECHANIC: DISINTEGRATION
        Disintegrate(target)

        DESIDERIUM._CubeLatticeLogs[#DESIDERIUM._CubeLatticeLogs + 1] = {
            time = CurTime(),
            event = "disintegrate_prop"
        }

        return
    end

    if target:IsPlayer() then
        target:SetVelocity((target:GetPos() - cube:GetPos()):GetNormalized() * 250 + Vector(0,0,120))
    end
end

-- =========================
-- CREATE CUBE
-- =========================
local function MakeCube(core, i, total)
    local ent = ents.Create("prop_physics")
    if not IsValid(ent) then return end

    ent:SetModel(CUBE_MODEL)
    ent:Spawn()

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:Wake()
        phys:SetMass(1)
    end

    local data = {
        ent = ent,
        phys = phys,
        ang = (i / total) * math.pi * 2,
        target = nil,
        lastTouch = 0
    }

    ent:AddCallback("PhysicsCollide", function(self, col)
        local hit = col.HitEntity
        if not IsValid(hit) then return end

        if CurTime() - (data.lastTouch or 0) < EFFECT_COOLDOWN then return end
        data.lastTouch = CurTime()

        ApplyCubeTouch(ent, hit, core._state)
    end)

    return data
end

-- =========================
-- MAIN ANOMALY
-- =========================
DESIDERIUM.RegisterAnomaly("cube_lattice", {
    Weight = WEIGHT,
    Cooldown = COOLDOWN,
    InstanceExposureWeight = INSTANCE_EXPOSURE,

    CanTrigger = function()
        return GetConVar("sv_addendum_enable"):GetBool()
    end,

    Trigger = function(ctx)

        local origin = (ctx and ctx.origin) or Vector(0,0,0)

        local core = ents.Create("prop_physics")
        if not IsValid(core) then return false end

        core:SetModel("models/hunter/plates/plate075x075.mdl")
        core:SetPos(origin + Vector(0,0,120))
        core:Spawn()

        core:SetMoveType(MOVETYPE_NONE)
        core:SetSolid(SOLID_NONE)
        core:SetColor(Color(255,255,255,0))

        core._cubes = {}
        core._start = CurTime()
        core._state = "STABLE"
        core._target = nil
        core._timer = "cube_lattice_" .. core:EntIndex()

        -- =========================
        -- ANNOUNCEMENT SYSTEM (NEW)
        -- =========================
        Announce("[DESIDERIUM SYSTEM] ANOMALY DETECTED: CUBE LATTICE", false)

        Announce("[DESIDERIUM CLASSIFICATION] RANK 1.4 - LATTICE SWARM ENTITY", 3)

        -- =========================
        -- SPAWN CUBES
        -- =========================
        local count = math.random(BASE_COUNT_MIN, BASE_COUNT_MAX)

        for i = 1, count do
            local c = MakeCube(core, i, count)
            if c then table.insert(core._cubes, c) end
        end

        -- =========================
        -- MAIN LOOP
        -- =========================
        timer.Create(core._timer, 0.05, 0, function()
            if not IsValid(core) then timer.Remove(core._timer) return end

            local elapsed = CurTime() - core._start

            -- STATE SWITCH
            if elapsed > COLLAPSE_TIME then
                core._state = "COLLAPSING"
            elseif elapsed > ESCALATION_TIME then
                core._state = "ESCALATING"
            else
                core._state = "STABLE"
            end

            -- ANNOUNCEMENTS ON STATE CHANGE
            if core._lastState ~= core._state then
                core._lastState = core._state

                if core._state == "ESCALATING" then
                    Announce("[DESIDERIUM] CUBE LATTICE ENTERING HUNTER MODE", false)
                elseif core._state == "COLLAPSING" then
                    Announce("[DESIDERIUM ALERT] STRUCTURAL FAILURE - CUBE SWARM UNSTABLE", false)
                end
            end

            -- TARGET UPDATE
            core._target = FindTarget(core)

            -- =========================
            -- CUBE AI
            -- =========================
            for i = #core._cubes, 1, -1 do
                local c = core._cubes[i]

                if not IsValid(c.ent) then
                    table.remove(core._cubes, i)
                    continue
                end

                local target = core._target
                local pos = c.ent:GetPos()

                if IsValid(target) then
                    local dir = (target:GetPos() - pos)
                    if dir:Length() > 10 then
                        dir:Normalize()

                        if IsValid(c.phys) then
                            c.phys:ApplyForceCenter(dir * 220)
                        end

                        -- “impact logic” handled in collision
                    end
                else
                    -- idle drift
                    if IsValid(c.phys) then
                        c.phys:ApplyForceCenter(VectorRand() * 10)
                    end
                end
            end
        end)

        return true
    end
})
