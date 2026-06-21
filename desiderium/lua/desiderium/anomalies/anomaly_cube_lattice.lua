--[[
DESIDERIUM Anomaly: Cube Lattice
File: desiderium/lua/desiderium/anomalies/anomaly_cube_lattice.lua
]]--

if CLIENT then return end

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._CubeLatticeLogs = DESIDERIUM._CubeLatticeLogs or {}
-- Keep only the last 100 logs to prevent memory leaks
if #DESIDERIUM._CubeLatticeLogs > 100 then
    table.remove(DESIDERIUM._CubeLatticeLogs, 1)
end

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
local WOBBLE_STRENGTH = 8          -- now used for vertical oscillation

local EFFECT_COOLDOWN = 0.7
local GLOBAL_EFFECT_CAP = 40

local ESCALATION_TIME = 240
local ESCALATION_SPEED_MULT = 1.7
local ESCALATION_SPLIT_CHANCE = 0.12   -- now implemented

local ANOMALY_DURATION = 600           -- auto‑cleanup after 10 minutes
local MAX_LOG_ENTRIES = 100

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

-- Safe constraint removal
local function SafeRemoveConstraints(ent)
    if not IsValid(ent) then return 0 end
    pcall(constraint.RemoveConstraints, ent)
    pcall(constraint.RemoveAll, ent)
    -- Return number of removed constraints (approximate)
    return math.min(ent:GetPhysicsObjectCount() or 0, 4)
end

-- Cleanup a single cube (remove entity and clear references)
local function CleanupCube(cubeData)
    if not cubeData then return end
    if IsValid(cubeData.ent) then
        cubeData.ent:Remove()
    end
    cubeData.ent = nil
    cubeData.phys = nil
end

-- Cleanup the entire anomaly instance
local function CleanupAnomaly(core)
    if not IsValid(core) then return end

    if core._desiderium_timer then
        timer.Remove(core._desiderium_timer)
        core._desiderium_timer = nil
    end

    if core._desiderium_cubes then
        for _, c in ipairs(core._desiderium_cubes) do
            CleanupCube(c)
        end
        core._desiderium_cubes = nil
    end

    if IsValid(core) then
        core:Remove()
    end
end

-- Apply a random effect to a target (player or prop)
local function ApplyRandomEffect(cube, target)
    if not IsValid(target) or not IsValid(cube) then return end
    if not CanDoGlobalEffect() then return end
    NoteGlobalEffect(1)

    local phys = target:GetPhysicsObject()
    if not IsValid(phys) then return end

    local now = CurTime()
    local effect = math.random(1, 5)

    -- Safety: if destruction is disabled, skip effect 1 (gravity disable)
    local disableDestruction = GetConVar("desiderium_debug_disable_destruction")
    if disableDestruction and disableDestruction:GetBool() then
        effect = math.random(2, 5)
    end

    -- Player handling
    if target:IsPlayer() then
        local push = (target:GetPos() - cube:GetPos()):GetNormalized() * 200 + Vector(0, 0, 200)
        target:SetVelocity(push)

        -- Log with timestamp and player info
        table.insert(DESIDERIUM._CubeLatticeLogs, {
            time = now,
            event = "player_nudge",
            target = target,
            ply = target:SteamID() or target:Nick()
        })
        if #DESIDERIUM._CubeLatticeLogs > MAX_LOG_ENTRIES then
            table.remove(DESIDERIUM._CubeLatticeLogs, 1)
        end
        return
    end

    -- Effects on props / NPCs
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

-- Create a single cube and set up its collision callback
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
        baseHeight = math.Rand(-HEIGHT_VARIANCE, HEIGHT_VARIANCE), -- fixed height offset
        wobblePhase = math.Rand(0, math.pi * 2),
        lastEffect = 0,
        core = core
    }

    -- Collision callback
    ent:AddCallback("PhysicsCollide", function(self, collisionData)
        local now = CurTime()
        local hit = collisionData.HitEntity
        if not IsValid(hit) then return end

        -- Per‑target cooldown
        if (hit._desiderium_cube_last or 0) > now - EFFECT_COOLDOWN then return end
        hit._desiderium_cube_last = now

        -- Escalation: chance to split (create a new cube)
        local elapsed = now - core._desiderium_start or 0
        if elapsed > ESCALATION_TIME and math.random() < ESCALATION_SPLIT_CHANCE then
            local count = #core._desiderium_cubes
            if count < MAX_CUBES_HARD then
                -- Create a new cube near the collision point
                local newCubeData = MakeCube(core, count + 1, count + 1, BASE_RADIUS + math.Rand(-20, 20))
                if newCubeData then
                    newCubeData.ent:SetPos(hit:GetPos() + VectorRand() * 30)
                    table.insert(core._desiderium_cubes, newCubeData)
                end
            end
        end

        -- Apply the effect with a slight delay
        timer.Simple(0, function()
            if IsValid(ent) and IsValid(hit) then
                ApplyRandomEffect(ent, hit)
            end
        end)
    end)

    return data
end

-- Register the anomaly
DESIDERIUM.RegisterAnomaly("cube_lattice", {
    Weight = WEIGHT,
    Cooldown = COOLDOWN,
    InstanceExposureWeight = INSTANCE_EXPOSURE,

    CanTrigger = function()
        local enable = GetConVar("sv_addendum_enable")
        return enable and enable:GetBool() or false
    end,

    Trigger = function(ctx)
        local origin = (ctx and ctx.origin) or Vector(0, 0, 0)

        -- Create invisible core
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

        -- Spawn initial cubes
        local count = math.random(BASE_COUNT_MIN, BASE_COUNT_MAX)
        for i = 1, count do
            local cube = MakeCube(core, i, count, BASE_RADIUS + math.Rand(-RADIUS_VARIANCE, RADIUS_VARIANCE))
            if cube then
                table.insert(core._desiderium_cubes, cube)
            end
        end

        -- Main update timer
        timer.Create(core._desiderium_timer, 0.08, 0, function()
            if not IsValid(core) then
                timer.Remove(core._desiderium_timer)
                return
            end

            local elapsed = CurTime() - core._desiderium_start
            local escalating = elapsed > ESCALATION_TIME
            local speedMult = escalating and ESCALATION_SPEED_MULT or 1

            -- Remove dead cubes and update positions
            local cubesToRemove = {}
            for i, c in ipairs(core._desiderium_cubes) do
                if not IsValid(c.ent) then
                    table.insert(cubesToRemove, i)
                else
                    -- Update angle
                    c.ang = c.ang + c.speed * speedMult * 0.08

                    -- Compute target position with wobble (vertical oscillation)
                    local wobbleOffset = math.sin(elapsed * 0.5 + c.wobblePhase) * WOBBLE_STRENGTH
                    local targetPos = core:GetPos()
                        + Vector(math.cos(c.ang) * c.radius, math.sin(c.ang) * c.radius, c.baseHeight + wobbleOffset)

                    -- Move the cube
                    if IsValid(c.phys) then
                        local force = (targetPos - c.ent:GetPos()) * 6
                        c.phys:ApplyForceCenter(force)
                        c.phys:AddAngleVelocity(VectorRand() * 60)
                    else
                        c.ent:SetPos(targetPos)
                    end
                end
            end

            -- Remove invalid cubes
            for i = #cubesToRemove, 1, -1 do
                local idx = cubesToRemove[i]
                local c = core._desiderium_cubes[idx]
                if c then
                    CleanupCube(c)
                    table.remove(core._desiderium_cubes, idx)
                end
            end

            -- Auto‑cleanup after duration
            if elapsed > ANOMALY_DURATION then
                CleanupAnomaly(core)
            end
        end)

        -- Cleanup when core is removed (e.g., by admin or game cleanup)
        core:AddCallback("OnRemove", function()
            CleanupAnomaly(core)
        end)

        return true
    end
})
