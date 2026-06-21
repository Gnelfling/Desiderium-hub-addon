--[[
DESIDERIUM Anomaly: Cube Lattice
File: desiderium/lua/desiderium/anomalies/anomaly_cube_lattice.lua
]]--

if CLIENT then return end

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._CubeLatticeLogs = DESIDERIUM._CubeLatticeLogs or {}

local CUBE_MODEL = "models/hunter/blocks/cube025x025x025.mdl"
local CUBE_MASS = 1

-- Tunables
local WEIGHT = 1
local COOLDOWN = 240
local INSTANCE_EXPOSURE = 48

local BASE_COUNT_MIN = 8
local BASE_COUNT_MAX = 16
local MAX_CUBES_HARD = 48

local BASE_RADIUS = 100
local RADIUS_VARIANCE = 28
local BASE_SPEED = 1.2
local SPEED_VARIANCE = 0.7

local HEIGHT_VARIANCE = 48
local WOBBLE_STRENGTH = 8

local EFFECT_COOLDOWN = 0.7
local GLOBAL_EFFECT_CAP = 40

local ESCALATION_TIME = 240
local ESCALATION_SPEED_MULT = 1.7
local ESCALATION_SPLIT_CHANCE = 0.12

-- Global effect limiter
DESIDERIUM._CubeLattice_GlobalEffects = DESIDERIUM._CubeLattice_GlobalEffects or { last = 0, count = 0 }

local function CanDoGlobalEffect()
    local t = CurTime()
    if t > DESIDERIUM._CubeLattice_GlobalEffects.last + 1 then
        DESIDERIUM._CubeLattice_GlobalEffects.last = t
        DESIDERIUM._CubeLattice_GlobalEffects.count = 0
    end
    return DESIDERIUM._CubeLattice_GlobalEffects.count < GLOBAL_EFFECT_CAP
end

local function NoteGlobalEffect(n)
    DESIDERIUM._CubeLattice_GlobalEffects.count =
        DESIDERIUM._CubeLattice_GlobalEffects.count + (n or 1)
end

local function SafeRemoveConstraints(ent)
    if not IsValid(ent) then return 0 end

    local removed = 0

    pcall(function()
        if constraint and constraint.RemoveConstraints then
            constraint.RemoveConstraints(ent)
        end
    end)

    pcall(function()
        if constraint and constraint.RemoveAll then
            constraint.RemoveAll(ent)
        end
    end)

    local physCount = 0
    if ent.GetPhysicsObjectCount then
        physCount = ent:GetPhysicsObjectCount() or 0
    end

    removed = math.min(physCount, 4)
    return removed
end

local function ApplyRandomEffect(cube, target)
    if not IsValid(target) or not IsValid(cube) then return end
    if not CanDoGlobalEffect() then return end

    NoteGlobalEffect(1)

    local phys = target:GetPhysicsObject()
    if not phys or not phys:IsValid() then return end

    local now = CurTime()
    local effect = math.random(1, 5)

    -- PLAYER HANDLING
    if target:IsPlayer() then
        local push = (target:GetPos() - cube:GetPos()):GetNormalized() * 200 + Vector(0, 0, 200)
        target:SetVelocity(push)

        table.insert(DESIDERIUM._CubeLatticeLogs, {
            time = now,
            event = "player_nudge",
            target = target
        })
        return
    end

    -- SAFETY MODE
    if GetConVar("desiderium_debug_disable_destruction") and
       GetConVar("desiderium_debug_disable_destruction"):GetBool() then
        effect = math.random(2, 5)
    end

    if effect == 1 then
        phys:EnableGravity(false)
        phys:ApplyForceCenter(Vector(0, 0, 300) * math.Clamp(phys:GetMass(), 1, 60))

        timer.Simple(1.3, function()
            if IsValid(phys) then
                phys:EnableGravity(true)
            end
        end)

    elseif effect == 2 then
        local saveVel = phys:GetVelocity()

        phys:EnableMotion(false)

        timer.Simple(0.9, function()
            if IsValid(phys) then
                phys:EnableMotion(true)
                phys:SetVelocity(saveVel)
            end
        end)

    elseif effect == 3 then
        local dir = (target:LocalToWorld(target:OBBCenter()) - cube:GetPos()):GetNormalized()
        local impulse = dir * (200 + math.random() * 400) + VectorRand() * 120

        phys:ApplyForceCenter(impulse * math.Clamp(phys:GetMass(), 1, 40))
        phys:ApplyTorqueCenter(VectorRand() * 8000)

    elseif effect == 4 then
        SafeRemoveConstraints(target)

    elseif effect == 5 then
        target:SetPos(target:GetPos() + VectorRand() * math.Rand(4, 22))
        phys:Wake()
    end
end

local function MakeCube(core, idx, total, radius)
    local ent = ents.Create("prop_physics")
    if not IsValid(ent) then return nil end

    ent:SetModel(CUBE_MODEL)
    ent:SetPos(core:GetPos() + Vector(math.random(-radius, radius), math.random(-radius, radius), math.random(-20, 20)))
    ent:Spawn()
    ent:Activate()

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:Wake()
        phys:SetMass(CUBE_MASS)
        phys:EnableDrag(false)
    end

    local ang = (idx / total) * math.pi * 2

    local data = {
        ent = ent,
        phys = phys,
        ang = ang,
        speed = BASE_SPEED + math.Rand(-SPEED_VARIANCE, SPEED_VARIANCE),
        radius = radius,
        height = math.Rand(-HEIGHT_VARIANCE, HEIGHT_VARIANCE),
        wobble = math.Rand(-WOBBLE_STRENGTH, WOBBLE_STRENGTH),
        lastEffect = 0,
        core = core
    }

    -- FIXED COLLISION CALLBACK
    ent:AddCallback("PhysicsCollide", function(self, dataCol)
        local now = CurTime()

        local hit = dataCol.HitEntity
        if not IsValid(hit) then return end

        -- proper cooldown system (NO data.Ts usage)
        if (hit._desiderium_cube_last or 0) > now - EFFECT_COOLDOWN then return end
        hit._desiderium_cube_last = now

        timer.Simple(0, function()
            ApplyRandomEffect(ent, hit)
        end)
    end)

    return data
end

DESIDERIUM.RegisterAnomaly("cube_lattice", {
    Weight = WEIGHT,
    Cooldown = COOLDOWN,
    InstanceExposureWeight = INSTANCE_EXPOSURE,

    CanTrigger = function()
        return GetConVar("sv_addendum_enable"):GetBool()
    end,

    Trigger = function(ctx)
        local origin = (ctx and ctx.origin) or Vector(0, 0, 0)

        local core = ents.Create("prop_physics")
        if not IsValid(core) then return false end

        core:SetModel("models/hunter/plates/plate075x075.mdl")
        core:SetPos(origin + Vector(0, 0, 120))
        core:Spawn()
        core:SetSolid(SOLID_NONE)
        core:SetMoveType(MOVETYPE_NONE)
        core:SetRenderMode(RENDERMODE_TRANSALPHA)
        core:SetColor(Color(255, 255, 255, 0))

        core._desiderium_cubes = {}
        core._desiderium_start = CurTime()
        core._desiderium_timer = "cube_lattice_" .. core:EntIndex()

        local count = math.random(BASE_COUNT_MIN, BASE_COUNT_MAX)

        for i = 1, count do
            local cube = MakeCube(core, i, count, BASE_RADIUS)
            if cube then
                table.insert(core._desiderium_cubes, cube)
            end
        end

        timer.Create(core._desiderium_timer, 0.08, 0, function()
            if not IsValid(core) then
                timer.Remove(core._desiderium_timer)
                return
            end

            local elapsed = CurTime() - core._desiderium_start
            local escalating = elapsed > ESCALATION_TIME

            for i, c in ipairs(core._desiderium_cubes or {}) do
                if not IsValid(c.ent) then continue end

                c.ang = c.ang + c.speed * (escalating and ESCALATION_SPEED_MULT or 1) * 0.08

                local targetPos =
                    core:GetPos()
                    + Vector(math.cos(c.ang) * c.radius, math.sin(c.ang) * c.radius, c.height)

                if IsValid(c.phys) then
                    local force = (targetPos - c.ent:GetPos()) * 6
                    c.phys:ApplyForceCenter(force)
                    c.phys:AddAngleVelocity(VectorRand() * 60)
                else
                    c.ent:SetPos(targetPos)
                end
            end
        end)

        return true
    end
})
