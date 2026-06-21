--[[
DESIDERIUM Anomaly: Cube Lattice – Hunter Variant (with HL2 Dissolve)
File: desiderium/lua/desiderium/anomalies/anomaly_cube_lattice.lua
]]--

if CLIENT then return end

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._CubeLatticeLogs = DESIDERIUM._CubeLatticeLogs or {}
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
local WOBBLE_STRENGTH = 8

local EFFECT_COOLDOWN = 0.7
local GLOBAL_EFFECT_CAP = 40

local ESCALATION_TIME = 240
local ESCALATION_SPEED_MULT = 1.7
local ESCALATION_SPLIT_CHANCE = 0.12

local ANOMALY_DURATION = 600
local MAX_LOG_ENTRIES = 100

-- Targeting parameters
local TARGET_SEARCH_RADIUS = 1200
local TARGET_REFRESH_INTERVAL_MIN = 2
local TARGET_REFRESH_INTERVAL_MAX = 4
local PURSUIT_FORCE_MULT = 14        -- how strongly they chase
local RETURN_FORCE_MULT = 4          -- how strongly they try to keep orbit (formation)

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
    return math.min(ent:GetPhysicsObjectCount() or 0, 4)
end

-- ------------------------------------------------------------------------
-- DISINTEGRATION using built‑in Half‑Life 2 env_entity_dissolver
-- ------------------------------------------------------------------------
local function DisintegrateProp(ent)
    if not IsValid(ent) then return end
    -- Only target props (not players, NPCs, or world)
    local class = ent:GetClass()
    if not string.find(class, "prop") then return end
    -- Already being removed?
    if ent:IsMarkedForDeletion() then return end

    -- Create a dissolver
    local dissolver = ents.Create("env_entity_dissolver")
    if not IsValid(dissolver) then
        -- Fallback: just remove with sparks
        local effect = EffectData()
        effect:SetOrigin(ent:GetPos())
        effect:SetEntity(ent)
        util.Effect("sparks", effect, true, true)
        ent:Remove()
        return
    end

    dissolver:SetName("cube_dissolver_" .. ent:EntIndex())
    dissolver:SetKeyValue("dissolvetype", "0")  -- 0 = dissolve, 1 = burn, 2 = electrocute
    dissolver:Spawn()
    dissolver:Activate()

    -- Target the entity
    dissolver:Fire("Dissolve", ent:GetName(), 0)
    -- Clean up dissolver after a short delay
    timer.Simple(0.5, function()
        if IsValid(dissolver) then
            dissolver:Remove()
        end
    end)

    -- Log the event
    table.insert(DESIDERIUM._CubeLatticeLogs, {
        time = CurTime(),
        event = "disintegrate",
        target = ent,
        target_class = class
    })
    if #DESIDERIUM._CubeLatticeLogs > MAX_LOG_ENTRIES then
        table.remove(DESIDERIUM._CubeLatticeLogs, 1)
    end
end

-- Cleanup functions
local function CleanupCube(cubeData)
    if not cubeData then return end
    if IsValid(cubeData.ent) then
        cubeData.ent:Remove()
    end
    cubeData.ent = nil
    cubeData.phys = nil
end

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

-- Create a single cube with targeting logic
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
        radius = radius + math.Rand(-RADIUS_VARIANCE, RADIUS_VARIANCE),
        baseHeight = math.Rand(-HEIGHT_VARIANCE, HEIGHT_VARIANCE),
        wobblePhase = math.Rand(0, math.pi * 2),
        lastEffect = 0,
        core = core,
        target = nil,               -- current target entity
        targetRefresh = 0,          -- next time to scan
        isChasing = false,
    }

    -- Collision callback – disintegrate props on touch
    ent:AddCallback("PhysicsCollide", function(self, collisionData)
        local now = CurTime()
        local hit = collisionData.HitEntity
        if not IsValid(hit) then return end

        -- Ignore players, core, other cubes (we only target props)
        if hit:IsPlayer() then return end
        if hit == core then return end
        if hit:GetClass() == "prop_physics" and hit:GetModel() == CUBE_MODEL then return end

        -- Cooldown per target
        if (hit._desiderium_cube_last or 0) > now - EFFECT_COOLDOWN then return end
        hit._desiderium_cube_last = now

        -- Disintegrate the prop
        DisintegrateProp(hit)

        -- Escalation: chance to split
        local elapsed = now - core._desiderium_start or 0
        if elapsed > ESCALATION_TIME and math.random() < ESCALATION_SPLIT_CHANCE then
            local count = #core._desiderium_cubes
            if count < MAX_CUBES_HARD then
                local newCubeData = MakeCube(core, count + 1, count + 1, BASE_RADIUS + math.Rand(-20, 20))
                if newCubeData then
                    newCubeData.ent:SetPos(hit:GetPos() + VectorRand() * 30)
                    table.insert(core._desiderium_cubes, newCubeData)
                end
            end
        end
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

        -- Invisible core
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
            local cube = MakeCube(core, i, count, BASE_RADIUS)
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
                    -- Refresh target if needed
                    if c.targetRefresh < CurTime() then
                        c.target = nil
                        c.isChasing = false
                        -- Scan for nearest prop (excluding players, cubes, core)
                        local bestDist = TARGET_SEARCH_RADIUS
                        for _, ent in ipairs(ents.FindInSphere(core:GetPos(), TARGET_SEARCH_RADIUS)) do
                            if IsValid(ent) and not ent:IsPlayer() and ent ~= core then
                                local class = ent:GetClass()
                                if string.find(class, "prop") and ent:GetModel() ~= CUBE_MODEL then
                                    local dist = c.ent:GetPos():DistToSqr(ent:GetPos())
                                    if dist < bestDist * bestDist then
                                        bestDist = math.sqrt(dist)
                                        c.target = ent
                                    end
                                end
                            end
                        end
                        if IsValid(c.target) then
                            c.isChasing = true
                        end
                        -- Randomize next refresh
                        c.targetRefresh = CurTime() + math.Rand(TARGET_REFRESH_INTERVAL_MIN, TARGET_REFRESH_INTERVAL_MAX)
                    end

                    -- Validate target (still exists and within range)
                    if c.isChasing and IsValid(c.target) then
                        local dist = c.ent:GetPos():DistTo(c.target:GetPos())
                        if dist > TARGET_SEARCH_RADIUS * 1.5 then
                            c.target = nil
                            c.isChasing = false
                        end
                    else
                        c.isChasing = false
                        c.target = nil
                    end

                    -- Update orbit angle
                    c.ang = c.ang + c.speed * speedMult * 0.08

                    -- Compute desired orbit position (formation)
                    local wobbleOffset = math.sin(elapsed * 0.5 + c.wobblePhase) * WOBBLE_STRENGTH
                    local orbitPos = core:GetPos()
                        + Vector(math.cos(c.ang) * c.radius, math.sin(c.ang) * c.radius, c.baseHeight + wobbleOffset)

                    -- Determine final target position
                    local targetPos = orbitPos
                    local forceMult = ORBIT_FORCE_MULT
                    if c.isChasing and IsValid(c.target) then
                        -- Chase target but also keep some orbit attraction
                        targetPos = c.target:GetPos() + Vector(0, 0, 10) -- slightly above
                        forceMult = PURSUIT_FORCE_MULT
                    end

                    -- Apply physics forces
                    if IsValid(c.phys) then
                        local force = (targetPos - c.ent:GetPos()) * forceMult
                        -- If chasing, add a bit of orbit pull so they don't drift too far
                        if c.isChasing then
                            local orbitPull = (orbitPos - c.ent:GetPos()) * 2
                            force = force + orbitPull
                        end
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

        core:AddCallback("OnRemove", function()
            CleanupAnomaly(core)
        end)

        return true
    end
})
