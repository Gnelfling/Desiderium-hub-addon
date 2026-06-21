--[[
DESIDERIUM Anomaly: Cube Lattice
File: desiderium/lua/desiderium/anomalies/anomaly_cube_lattice.lua

Core idea:
- Invisible core with orbiting 1x1 cubes (models/hunter/blocks/cube025x025x025.mdl).
- Cubes are physical props that orbit the core by velocity steering.
- On contact a cube applies a random "rule" to the touched entity (physics invert, rotation lock, impulse burst, weld break, position snap).
- Orbits wobble and can destabilize; cubes behave as a distributed body and compensate if cubes are lost.
- Escalation: over time orbit speed increases and cube count can temporarily rise.

Safety / design notes:
- Respect desiderium_debug_disable_destruction convar to avoid destructive constraint removals during tests.
- Rate-limited per-cube and global effects to avoid runaway effects.
- All work is server-side only.
]]--

if CLIENT then return end

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._CubeLatticeLogs = DESIDERIUM._CubeLatticeLogs or {}

local CORE_MODEL = "models/hunter/plates/plate075x075.mdl" -- invisible anchor (we'll hide it)
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
local BASE_SPEED = 1.2          -- radians per second
local SPEED_VARIANCE = 0.7
local HEIGHT_VARIANCE = 48
local WOBBLE_STRENGTH = 8
local EFFECT_COOLDOWN = 0.7     -- seconds per cube between applying effects
local GLOBAL_EFFECT_CAP = 40    -- effects per second global cap
local ESCALATION_TIME = 240     -- seconds before escalation begins
local ESCALATION_SPEED_MULT = 1.7
local ESCALATION_SPLIT_CHANCE = 0.12 -- chance per interval to spawn extra cube

local SAFE_CONV = GetConVarNumber and GetConVarNumber("desiderium_debug_disable_destruction") or 0

-- Global effect counter (rate limiting)
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
    DESIDERIUM._CubeLattice_GlobalEffects.count = DESIDERIUM._CubeLattice_GlobalEffects.count + (n or 1)
end

local function SafeRemoveConstraints(ent)
    if not IsValid(ent) then return 0 end
    if GetConVar("desiderium_debug_disable_destruction") and GetConVar("desiderium_debug_disable_destruction"):GetBool() then return 0 end
    local removed = 0
    pcall(function() if constraint and type(constraint.RemoveConstraints) == "function" then constraint.RemoveConstraints(ent) end end)
    pcall(function() if constraint and type(constraint.RemoveAll) == "function" then constraint.RemoveAll(ent) end end)
    local physCount = 0
    if type(ent.GetPhysicsObjectCount) == "function" then physCount = ent:GetPhysicsObjectCount() or 0 end
    removed = math.min(physCount, 4)
    return removed
end

local function ApplyRandomEffect(cube, target)
    if not IsValid(target) or not IsValid(cube) then return end
    if not CanDoGlobalEffect() then return end

    NoteGlobalEffect(1)

    local phys = target:GetPhysicsObject()
    local effect = math.random(1,5)
    local now = CurTime()

    -- per-target safe checks
    if not phys or not phys:IsValid() then
        return
    end

    -- don't destroy players' core joints etc (safety)
    if target:IsPlayer() then
        -- For players we only apply an impulse burst that nudges them slightly
        phys = nil
        local push = (target:GetPos() - cube:GetPos()):GetNormalized() * 200 + Vector(0,0,200)
        target:SetVelocity(push)
        table.insert(DESIDERIUM._CubeLatticeLogs, {time=now,event="player_nudge",cube=cube, target=target})
        return
    end

    -- ensure we don't overstep testing mode
    if GetConVar("desiderium_debug_disable_destruction") and GetConVar("desiderium_debug_disable_destruction"):GetBool() then
        -- only do non-destructive effects: impulse burst and slight snap
        effect = math.random(2,5)
    end

    if effect == 1 then
        -- physics invert: briefly toggle gravity off or increase mass
        if phys and phys:IsValid() then
            -- invert by toggling gravity and pushing
            phys:EnableGravity(false)
            phys:ApplyForceCenter(Vector(0,0,300) * math.Clamp(phys:GetMass(),1,60))
            timer.Simple(1.3, function()
                if IsValid(phys) then phys:EnableGravity(true) end
            end)
            table.insert(DESIDERIUM._CubeLatticeLogs, {time=now,event="invert_gravity",cube=cube,target=target})
        end
    elseif effect == 2 then
        -- rotation lock: freeze physics motion for a short period
        if phys and phys:IsValid() then
            local saveVel = phys:GetVelocity()
            phys:EnableMotion(false)
            timer.Simple(0.9, function()
                if IsValid(phys) then
                    phys:EnableMotion(true)
                    phys:SetVelocity(saveVel)
                end
            end)
            table.insert(DESIDERIUM._CubeLatticeLogs, {time=now,event="rotation_lock",cube=cube,target=target})
        end
    elseif effect == 3 then
        -- impulse burst: shove or spin the object
        if phys and phys:IsValid() then
            local dir = (target:LocalToWorld(target:OBBCenter()) - cube:GetPos()):GetNormalized()
            local impulse = dir * (200 + math.random()*400) + VectorRand() * 120
            phys:ApplyForceCenter(impulse * math.Clamp(phys:GetMass(),1,40))
            phys:ApplyTorqueCenter(VectorRand() * 8000)
            table.insert(DESIDERIUM._CubeLatticeLogs, {time=now,event="impulse",cube=cube,target=target})
        end
    elseif effect == 4 then
        -- weld break: remove constraints/welds
        local removed = SafeRemoveConstraints(target)
        if removed > 0 then
            table.insert(DESIDERIUM._CubeLatticeLogs, {time=now,event="weld_break",cube=cube,target=target,removed=removed})
        end
    elseif effect == 5 then
        -- position snap: slight teleport/snap to avoid precision
        local pos = target:GetPos()
        local npos = pos + VectorRand() * math.Rand(4, 22)
        target:SetPos(npos)
        local physobj = target:GetPhysicsObject()
        if physobj and physobj:IsValid() then physobj:Wake() end
        table.insert(DESIDERIUM._CubeLatticeLogs, {time=now,event="position_snap",cube=cube,target=target})
    end
end

local function MakeCube(core, idx, total, radius)
    local ang = (idx / total) * math.pi * 2 + math.Rand(0,0.6)
    local height = math.Rand(-HEIGHT_VARIANCE, HEIGHT_VARIANCE)
    local speed = BASE_SPEED + math.Rand(-SPEED_VARIANCE, SPEED_VARIANCE)

    local ent = ents.Create("prop_physics")
    if not IsValid(ent) then return nil end
    ent:SetModel(CUBE_MODEL)
    ent:SetPos(core:GetPos() + Vector(math.cos(ang)*radius, math.sin(ang)*radius, height))
    ent:Spawn()
    ent:Activate()

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:Wake()
        phys:SetMass(CUBE_MASS)
        phys:EnableDrag(false)
    end

    local data = {
        ent = ent,
        phys = phys,
        ang = ang,
        speed = speed,
        radius = radius + math.Rand(-RADIUS_VARIANCE, RADIUS_VARIANCE),
        height = height,
        lastEffect = 0,
        core = core,
        wobble = math.Rand(-WOBBLE_STRENGTH, WOBBLE_STRENGTH),
    }

    -- Physics collision callback
    ent:AddCallback("PhysicsCollide", function(self, data)
        local now = CurTime()
        if not IsValid(data.HitEntity) then return end
        if now - data.Ts < 0 then return end
        -- when colliding with something, apply effect (rate limited per cube)
        if now - data.Ts < 0.02 then return end
        if now - data.Ts > 0.5 then -- ignore stale
        end
        if now - data.Ts <= 0.01 then return end

        local owner = data.HitEntity
        if not IsValid(owner) then return end
        if now - (data.HitEntity._desiderium_cube_last or 0) < EFFECT_COOLDOWN then return end

        data.HitEntity._desiderium_cube_last = now
        data.HitEntity._desiderium_cube_last_cube = ent

        -- apply effect asynchronously
        timer.Simple(0, function()
            ApplyRandomEffect(ent, owner)
        end)

        -- expand orbit radius slightly on disturbance
        if IsValid(core) and data.Speed > 10 then
            core._desiderium_radius = (core._desiderium_radius or BASE_RADIUS) + math.Clamp(data.Speed * 0.06, 6, 140)
        end
    end)

    return data
end

DESIDERIUM.RegisterAnomaly("cube_lattice", {
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

        -- create invisible core anchor
        local core = ents.Create("prop_physics")
        if not IsValid(core) then return false end
        core:SetModel(CORE_MODEL)
        core:SetPos(origin + Vector(0,0,120))
        core:Spawn()
        core:Activate()
        core:SetRenderMode(RENDERMODE_TRANSALPHA)
        core:SetColor(Color(255,255,255,0))
        core:SetSolid(SOLID_NONE)
        core:SetMoveType(MOVETYPE_NONE)

        core._desiderium_radius = BASE_RADIUS
        core._desiderium_start = CurTime()
        core._desiderium_cubes = {}
        core._desiderium_timer = "desiderium_cube_lattice_" .. tostring(core:EntIndex())

        local count = math.random(BASE_COUNT_MIN, BASE_COUNT_MAX)

        for i=1,count do
            local d = MakeCube(core, i, count, core._desiderium_radius)
            if d then table.insert(core._desiderium_cubes, d) end
        end

        table.insert(DESIDERIUM._CubeLatticeLogs, {time=CurTime(), event="spawn", core=core, count=#core._desiderium_cubes})

        -- orbit update timer
        timer.Create(core._desiderium_timer, 0.08, 0, function()
            if not IsValid(core) then timer.Remove(core._desiderium_timer) return end
            -- cleanup if gate disabled or lifetime exceeded
            if not GetConVar("sv_addendum_enable"):GetBool() then
                if IsValid(core) then
                    for _,c in ipairs(core._desiderium_cubes or {}) do
                        if IsValid(c.ent) then SafeRemoveEntity(c.ent) end
                    end
                    SafeRemoveEntity(core)
                end
                timer.Remove(core._desiderium_timer)
                return
            end

            -- escalation behavior
            local elapsed = CurTime() - core._desiderium_start
            local escalating = elapsed > ESCALATION_TIME

            -- possibly split/spawn extra cubes on escalation
            if escalating and math.random() < ESCALATION_SPLIT_CHANCE then
                if #core._desiderium_cubes < math.min(MAX_CUBES_HARD, #core._desiderium_cubes + 2) then
                    local idx = #core._desiderium_cubes + 1
                    local nd = MakeCube(core, idx, idx, core._desiderium_radius)
                    if nd then table.insert(core._desiderium_cubes, nd) end
                end
            end

            -- update cubes and steer toward orbit positions
            for i, c in ipairs(core._desiderium_cubes or {}) do
                if not IsValid(c.ent) then
                    -- compensate spacing if cube dead
                    table.remove(core._desiderium_cubes, i)
                    -- rebalance angles
                    for j=1,#(core._desiderium_cubes or {}) do
                        core._desiderium_cubes[j].ang = (j / #core._desiderium_cubes) * math.pi * 2
                    end
                    break
                end

                -- compute desired orbit target
                local total = math.max(1, #core._desiderium_cubes)
                c.ang = c.ang + (c.speed * (escalating and ESCALATION_SPEED_MULT or 1)) * 0.08
                -- small wobble
                local wob = math.sin(CurTime() * (0.5 + (i%3))) * (c.wobble)
                local targetPos = core:GetPos() + Vector(math.cos(c.ang) * c.radius, math.sin(c.ang) * c.radius, c.height + wob)

                -- steering: set velocity toward targetPos
                if IsValid(c.phys) then
                    local curPos = c.ent:GetPos()
                    local desiredVel = (targetPos - curPos) * 6 -- steering strength
                    -- weak anti-gravity to keep loose orbit
                    c.phys:ApplyForceCenter( (desiredVel - c.phys:GetVelocity()) * math.Clamp(c.phys:GetMass()/2, 1, 80) )
                    -- add rotational spin for visual noise
                    c.phys:AddAngleVelocity(VectorRand() * 60 * (escalating and 1.6 or 1))
                else
                    -- fallback: teleport if phys invalid
                    c.ent:SetPos(targetPos)
                end

                -- slightly expand radius if orbit disturbed
                core._desiderium_radius = math.Clamp((core._desiderium_radius or BASE_RADIUS) * 0.999 + 0.002, BASE_RADIUS*0.9, BASE_RADIUS*4)

                -- optional cleanup for long-lived cores
                if CurTime() - core._desiderium_start > 3600 then
                    -- long expiry
                    for _,cc in ipairs(core._desiderium_cubes) do SafeRemoveEntity(cc.ent) end
                    SafeRemoveEntity(core)
                    timer.Remove(core._desiderium_timer)
                    return
                end
            end
        end)

        -- Return cleanup closure and the core entity
        return (function()
            if timer.Exists(core._desiderium_timer) then timer.Remove(core._desiderium_timer) end
            if IsValid(core) then
                for _,c in ipairs(core._desiderium_cubes or {}) do
                    if IsValid(c.ent) then SafeRemoveEntity(c.ent) end
                end
                SafeRemoveEntity(core)
            end
        end), core
    end,

    Cleanup = function(ctx) end,
})
