--[[
DESIDERIUM Anomaly: Cube Lattice (v2 - Stateful / Reactive)
File: desiderium/lua/desiderium/anomalies/anomaly_cube_lattice.lua
]]--

if CLIENT then return end

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._CubeLatticeLogs = DESIDERIUM._CubeLatticeLogs or {}

local CUBE_MODEL = "models/hunter/blocks/cube025x025x025.mdl"
local CUBE_MASS = 1

-- Core tuning
local WEIGHT = 1
local COOLDOWN = 240
local INSTANCE_EXPOSURE = 48

local BASE_COUNT_MIN = 8
local BASE_COUNT_MAX = 16
local MAX_CUBES = 48

local BASE_RADIUS = 110
local BASE_SPEED = 1.2
local SPEED_VARIANCE = 0.6
local HEIGHT_VARIANCE = 45

local EFFECT_COOLDOWN = 0.65
local GLOBAL_EFFECT_CAP = 40

-- State timing
local ESCALATION_TIME = 120
local COLLAPSE_TIME = 260

local ESCALATION_SPEED_MULT = 1.8
local COLLAPSE_DURATION = 6

-- States
local STATE_STABLE = "STABLE"
local STATE_ESCALATING = "ESCALATING"
local STATE_COLLAPSING = "COLLAPSING"

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

local function SafeRemoveConstraints(ent)
    if not IsValid(ent) then return end
    pcall(function()
        if constraint then
            constraint.RemoveAll(ent)
        end
    end)
end

-- =========================
-- EFFECT CORE
-- =========================

local function ApplyCubeEffect(cube, target, state)
    if not IsValid(cube) or not IsValid(target) then return end
    if not CanDoGlobalEffect() then return end
    NoteGlobalEffect()

    local phys = target:GetPhysicsObject()
    local now = CurTime()

    local power = (state == STATE_ESCALATING and 1.5) or (state == STATE_COLLAPSING and 2.2) or 1

    -- PLAYER SAFE HANDLING
    if target:IsPlayer() then
        local dir = (target:GetPos() - cube:GetPos()):GetNormalized()
        target:SetVelocity(dir * 220 * power + Vector(0,0,120))
        return
    end

    if not IsValid(phys) then return end

    local effect = math.random(1, 5)

    if effect == 1 then
        phys:EnableGravity(false)
        phys:ApplyForceCenter(Vector(0,0,300) * power)

        timer.Simple(1, function()
            if IsValid(phys) then phys:EnableGravity(true) end
        end)

    elseif effect == 2 then
        local v = phys:GetVelocity()
        phys:EnableMotion(false)

        timer.Simple(0.8, function()
            if IsValid(phys) then
                phys:EnableMotion(true)
                phys:SetVelocity(v)
            end
        end)

    elseif effect == 3 then
        local dir = (target:GetPos() - cube:GetPos()):GetNormalized()
        phys:ApplyForceCenter(dir * 300 * power + VectorRand() * 120)

    elseif effect == 4 then
        SafeRemoveConstraints(target)

    elseif effect == 5 then
        target:SetPos(target:GetPos() + VectorRand() * (6 * power))
    end
end

-- =========================
-- CUBE CREATION
-- =========================

local function MakeCube(core, i, total)
    local ent = ents.Create("prop_physics")
    if not IsValid(ent) then return end

    ent:SetModel(CUBE_MODEL)
    ent:Spawn()

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:Wake()
        phys:SetMass(CUBE_MASS)
    end

    local data = {
        ent = ent,
        phys = phys,
        ang = (i / total) * math.pi * 2,
        speed = BASE_SPEED + math.Rand(-SPEED_VARIANCE, SPEED_VARIANCE),
        radius = BASE_RADIUS,
        height = math.Rand(-HEIGHT_VARIANCE, HEIGHT_VARIANCE),
        lastHit = 0
    }

    ent:AddCallback("PhysicsCollide", function(self, col)
        local hit = col.HitEntity
        if not IsValid(hit) then return end

        if CurTime() - (hit._cube_last or 0) < EFFECT_COOLDOWN then return end
        hit._cube_last = CurTime()

        timer.Simple(0, function()
            ApplyCubeEffect(ent, hit, core._state)
        end)
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

        core:SetSolid(SOLID_NONE)
        core:SetMoveType(MOVETYPE_NONE)
        core:SetRenderMode(RENDERMODE_TRANSALPHA)
        core:SetColor(Color(255,255,255,0))

        core._cubes = {}
        core._start = CurTime()
        core._state = STATE_STABLE
        core._radius = BASE_RADIUS
        core._timer = "cube_lattice_" .. core:EntIndex()

        local count = math.random(BASE_COUNT_MIN, BASE_COUNT_MAX)

        for i = 1, count do
            local c = MakeCube(core, i, count)
            if c then table.insert(core._cubes, c) end
        end

        -- MAIN LOOP
        timer.Create(core._timer, 0.05, 0, function()
            if not IsValid(core) then timer.Remove(core._timer) return end

            local elapsed = CurTime() - core._start

            -- STATE SYSTEM
            if elapsed > COLLAPSE_TIME then
                core._state = STATE_COLLAPSING
            elseif elapsed > ESCALATION_TIME then
                core._state = STATE_ESCALATING
            else
                core._state = STATE_STABLE
            end

            -- COLLAPSE EVENT
            if core._state == STATE_COLLAPSING then
                core._radius = core._radius * 0.85

                if math.random() < 0.08 then
                    for _, c in ipairs(core._cubes) do
                        if IsValid(c.ent) then
                            c.ent:ApplyForceCenter(VectorRand() * 800)
                        end
                    end
                end
            end

            -- ESCALATION GROWTH
            if core._state == STATE_ESCALATING then
                core._radius = math.min(core._radius + 0.15, BASE_RADIUS * 2.2)
            end

            -- UPDATE CUBES
            for i = #core._cubes, 1, -1 do
                local c = core._cubes[i]

                if not IsValid(c.ent) then
                    table.remove(core._cubes, i)
                    continue
                end

                local speedMult =
                    (core._state == STATE_ESCALATING and ESCALATION_SPEED_MULT) or
                    (core._state == STATE_COLLAPSING and 0.6) or 1

                c.ang = c.ang + (c.speed * speedMult) * 0.05

                local pos = core:GetPos() + Vector(
                    math.cos(c.ang) * core._radius,
                    math.sin(c.ang) * core._radius,
                    c.height
                )

                if IsValid(c.phys) then
                    local force = (pos - c.ent:GetPos()) * 6
                    c.phys:ApplyForceCenter(force)
                else
                    c.ent:SetPos(pos)
                end

                -- COLLAPSE DISINTEGRATION PRESSURE
                if core._state == STATE_COLLAPSING and math.random() < 0.01 then
                    ApplyCubeEffect(c.ent, c.ent, core._state)
                end
            end

            -- REFORM AFTER COLLAPSE
            if core._state == STATE_COLLAPSING and elapsed > COLLAPSE_TIME + COLLAPSE_DURATION then
                core._start = CurTime()
                core._state = STATE_STABLE
                core._radius = BASE_RADIUS
            end
        end)

        return true
    end
})
