--[[
DESIDERIUM Anomaly: Observer Node (v3 - perception & corruption)
File: desiderium/lua/desiderium/anomalies/anomaly_observer_node.lua

Purpose: make the node strictly perception-driven (doesn't move or teleport),
and focus its effects on subtle physics/world corruption when it is NOT
being observed. Add safety guards and caps to avoid crazy physics.

Key changes in v3:
- Node no longer jitters, teleports, or moves toward players; it stays
  at its spawn anchor and "observes" the world.
- When unobserved it corrupts nearby physics via small, bounded impulses,
  angle nudges, brief gravity perturbations, and rare short-lived ghost
  duplicates. Effects are stronger when few players are nearby.
- Physics calls are guarded (IsValid checks) and velocities are checked
  before applying impulses to avoid "crazy origin" removals.
- Duplicates are capped per-anomaly and globally to prevent accumulation.
- Timer callback is protected with xpcall so runtime errors won't silently
  kill the timer; failures attempt graceful cleanup.
- Respects sv_addendum_enable gate and auto-life as before.
]]--

if CLIENT then return end

local Model = "models/props_phx/ball.mdl"
local LoopSound = "ambient/levels/citadel/citadel_drone_loop1.wav"
local AppearSound = "ambient/alarms/klaxon1.wav"

local CONSOLE_GATE_CVAR = "sv_addendum_enable"

-- Tunables and safety limits
local TOUCH_FORCE = 180           -- magnitude multiplier for ApplyForceCenter (conservative)
local TOUCH_ANGVEL = 8            -- max angular velocity added
local VELOCITY_SKIP_THRESHOLD = 700 -- if a prop is already this fast, skip applying more force
local MAX_DUPLICATES_PER_ANOMALY = 2
local MAX_GLOBAL_GHOSTS = 18
local DUP_CHANCE_BASE = 0.02
local DUP_CHANCE_BOOST_NO_PLAYERS = 0.06
local GRAVITY_PULSE_FORCE = 40

local function IsPlayerDirectlyObserving(ent)
    if not IsValid(ent) then return false, nil end
    local entPos = ent:WorldSpaceCenter()
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:Alive() then continue end
        local eye = ply:EyePos()
        local dir = (entPos - eye):GetNormalized()
        local dot = math.max( -1, math.min(1, ply:GetAimVector():Dot(dir) ) )
        -- require roughly within player's forward cone (~40 deg)
        if dot < 0.77 then continue end
        local tr = util.TraceLine({ start = eye, endpos = entPos, filter = ply, mask = MASK_SHOT })
        if tr.Entity == ent then
            return true, ply
        end
    end
    return false, nil
end

local function IsPlayerIndirectlyObserving(ent)
    if not IsValid(ent) then return false end
    local entPos = ent:WorldSpaceCenter()
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:Alive() then continue end
        local eye = ply:EyePos()
        local tr = util.TraceLine({ start = eye, endpos = entPos, filter = ply, mask = MASK_SHOT })
        if tr.Hit and IsValid(tr.Entity) and tr.Entity ~= ent then
            if tr.HitPos:Distance(entPos) <= 64 then
                return true, ply, tr.Entity
            end
        end
    end
    return false, nil, nil
end

local function PickAnchorPoint()
    local props = {}
    for _, e in ipairs(ents.GetAll()) do
        if not IsValid(e) then continue end
        local cls = e:GetClass() or ""
        if cls:find("prop_physics") or cls:find("prop_physics_multiplayer") then
            table.insert(props, e)
        end
    end
    if #props > 0 then
        local p = props[math.random(#props)]
        return p:GetPos() + Vector(0,0,30)
    end
    local players = player.GetAll()
    if #players > 0 then
        local p = players[math.random(#players)]
        return p:GetPos() + Vector(0,0,50)
    end
    return Vector(0,0,64)
end

local function MakeAfterimage(orig)
    if not IsValid(orig) then return end
    local ghost = ents.Create("prop_physics")
    if not IsValid(ghost) then return end
    ghost:SetModel(orig:GetModel())
    ghost:SetPos(orig:GetPos())
    ghost:SetAngles(orig:GetAngles())
    ghost:Spawn()
    ghost:SetMoveType(MOVETYPE_NONE)
    ghost:SetSolid(SOLID_NONE)
    ghost:SetRenderMode(RENDERMODE_TRANSALPHA)
    ghost:SetColor(Color(200,255,220,140))
    ghost:DrawShadow(false)
    -- afterimages are cosmetic only and short-lived
    timer.Simple(2, function() if IsValid(ghost) then SafeRemoveEntity(ghost) end end)
end

-- Global ghost counter stored on DESIDERIUM to limit total ghosts
DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._GlobalGhostCount = DESIDERIUM._GlobalGhostCount or 0
DESIDERIUM._ObserverLogs = DESIDERIUM._ObserverLogs or {}

local function EmitEvent(name, data)
    if DESIDERIUM.OnAnomalyEvent and type(DESIDERIUM.OnAnomalyEvent) == "function" then
        pcall(DESIDERIUM.OnAnomalyEvent, name, data)
    end
end

DESIDERIUM.RegisterAnomaly("observer_node", {
    Weight = 1,
    Cooldown = 120,
    MinPlayers = 1,

    CanTrigger = function(ctx)
        return #player.GetAll() >= 1
    end,

    Trigger = function(ctx)
        if not GetConVar(CONSOLE_GATE_CVAR):GetBool() then return false end

        local origin = PickAnchorPoint()
        local ent = ents.Create("prop_physics")
        if not IsValid(ent) then return false end

        ent:SetModel(Model)
        ent:SetPos(origin)
        ent:Spawn()
        -- keep it effectively static but visible
        ent:SetMoveType(MOVETYPE_NONE)
        ent:SetSolid(SOLID_VPHYSICS)
        ent:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
        ent:DrawShadow(false)
        ent:SetRenderMode(RENDERMODE_TRANSALPHA)
        ent:SetColor(Color(180,255,200,255))

        ent:EmitSound(LoopSound, 80, 100)
        sound.Play(AppearSound, ent:GetPos(), 100, 100, 1)

        if DESIDERIUM and DESIDERIUM.BroadcastGateMessage then
            DESIDERIUM.BroadcastGateMessage("[DESIDERIUM SERVER] ANOMALY DATABASE DETECTED, OBSERVER NODE HAS ENTERED.", false)
            timer.Simple(4, function()
                if IsValid(ent) and GetConVar(CONSOLE_GATE_CVAR):GetBool() then
                    DESIDERIUM.BroadcastGateMessage("[DESIDERIUM SERVER] DANGEROUS RANK DATABASE > RANK 0.1", false)
                    sound.Play("ambient/alarms/klaxon1.wav", ent:GetPos(), 100, 110, 0.8)
                end
            end)
        end

        local state = {
            ent = ent,
            mode = "UNOBSERVED", -- DIRECT / INDIRECT / UNOBSERVED
            touched = {},
            duplicates = {},
            life = CurTime() + 120,
            lastAfterimage = 0,
        }

        local timerName = "desiderium_observer_node_" .. tostring(ent:EntIndex())

        timer.Create(timerName, 0.11, 0, function()
            local ok, err = xpcall(function()
                if not IsValid(ent) then timer.Remove(timerName) return end

                -- Respect gate
                if not GetConVar(CONSOLE_GATE_CVAR):GetBool() then
                    if IsValid(ent) then ent:StopSound(LoopSound); SafeRemoveEntity(ent) end
                    for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
                    timer.Remove(timerName)
                    return
                end

                -- Auto life expire
                if CurTime() >= state.life then
                    if IsValid(ent) then ent:StopSound(LoopSound); SafeRemoveEntity(ent) end
                    for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
                    timer.Remove(timerName)
                    return
                end

                -- Visibility checks
                local direct, dp = IsPlayerDirectlyObserving(ent)
                local indirect, ip, via = IsPlayerIndirectlyObserving(ent)
                local newMode = "UNOBSERVED"
                local observerPlayer = nil
                if direct then
                    newMode = "DIRECT"
                    observerPlayer = dp
                elseif indirect then
                    newMode = "INDIRECT"
                    observerPlayer = ip
                end

                if newMode ~= state.mode then
                    if newMode == "DIRECT" then
                        state.mode = "DIRECT"
                        table.insert(DESIDERIUM._ObserverLogs, {time = CurTime(), type = "observed_direct", by = IsValid(observerPlayer) and observerPlayer:SteamID() or "unknown"})
                        EmitEvent("OnObserved", {anomaly = "observer_node", by = observerPlayer})
                        ent:SetNoDraw(false)
                        ent:SetColor(Color(255,255,255,220))
                        ent:StopSound(LoopSound)
                        sound.Play("ambient/atmosphere/ambience_sky.wav", ent:GetPos(), 70, 90, 0.2)
                    elseif newMode == "INDIRECT" then
                        state.mode = "INDIRECT"
                        table.insert(DESIDERIUM._ObserverLogs, {time = CurTime(), type = "observed_indirect", via = tostring(via)})
                        EmitEvent("OnIndirectObserved", {anomaly = "observer_node", via = via})
                        ent:SetNoDraw(false)
                        ent:SetColor(Color(255,255,255,180))
                        ent:StopSound(LoopSound)
                        sound.Play("ambient/alarms/klaxon1.wav", ent:GetPos(), 70, 120, 0.25)
                    else
                        state.mode = "UNOBSERVED"
                        table.insert(DESIDERIUM._ObserverLogs, {time = CurTime(), type = "unobserved"})
                        EmitEvent("OnUnobserved", {anomaly = "observer_node"})
                        ent:SetNoDraw(false)
                        ent:SetColor(Color(180,255,200,255))
                        ent:EmitSound(LoopSound, 80, 100)
                        sound.Play("buttons/button17.wav", ent:GetPos(), 75, 100, 0.6)
                    end
                end

                -- If DIRECT: frozen; do minimal shimmer
                if state.mode == "DIRECT" then
                    if math.random() < 0.04 then sound.Play("ambient/atmosphere/thunder1.wav", ent:GetPos(), 75, 90, 0.12) end
                    return
                end

                -- INDIRECT: small cosmetic flicker only
                if state.mode == "INDIRECT" then
                    if math.random() < 0.22 then
                        ent:SetNoDraw(true)
                        timer.Simple(0.06, function() if IsValid(ent) then ent:SetNoDraw(false) end end)
                    end
                    return
                end

                -- UNOBSERVED: corruption effects only (no movement)
                -- Determine how "active" we are: boost when few players are nearby
                local playersNearby = 0
                for _, ply in ipairs(player.GetAll()) do
                    if not IsValid(ply) or not ply:Alive() then continue end
                    if ply:GetPos():DistToSqr(ent:GetPos()) <= (900 * 900) then playersNearby = playersNearby + 1 end
                end
                local noPlayersNearby = (playersNearby == 0)

                -- small ambient afterimage occasionally
                if CurTime() - state.lastAfterimage > 0.3 and math.random() < 0.08 then
                    MakeAfterimage(ent)
                    state.lastAfterimage = CurTime()
                end

                -- Corrupt nearby props: small, bounded impulses and angle nudges
                for _, e in ipairs(ents.FindInSphere(ent:GetPos(), 220)) do
                    if not IsValid(e) or e == ent then continue end
                    local cls = e:GetClass() or ""
                    if cls:find("prop_physics") then
                        local last = state.touched[e] or 0
                        if CurTime() - last > 1.2 then
                            state.touched[e] = CurTime()

                            local phys = e:GetPhysicsObject()
                            if IsValid(phys) then
                                local vel = phys:GetVelocity()
                                if vel:Length() <= VELOCITY_SKIP_THRESHOLD then
                                    -- small randomized force
                                    local magnitude = TOUCH_FORCE * (noPlayersNearby and 1.8 or 1.0)
                                    phys:ApplyForceCenter(VectorRand() * magnitude)
                                    phys:AddAngleVelocity(Vector(math.Rand(-TOUCH_ANGVEL,TOUCH_ANGVEL), math.Rand(-TOUCH_ANGVEL,TOUCH_ANGVEL), math.Rand(-TOUCH_ANGVEL,TOUCH_ANGVEL)))
                                end
                            end

                            -- slight rotation nudge (always safe server-side)
                            e:SetAngles(e:GetAngles() + Angle(math.Rand(-2,2), math.Rand(-2,2), math.Rand(-2,2)))

                            -- subtle gravity pulse nearby (cheap manifestation)
                            local nearby = ents.FindInSphere(e:GetPos(), 180)
                            for _, ne in ipairs(nearby) do
                                if not IsValid(ne) then continue end
                                local p = ne:GetPhysicsObject()
                                if IsValid(p) then
                                    local v = p:GetVelocity()
                                    if v:Length() <= VELOCITY_SKIP_THRESHOLD then
                                        p:ApplyForceCenter(Vector(0,0, (noPlayersNearby and 50 or -GRAVITY_PULSE_FORCE)))
                                    end
                                end
                            end

                            -- rare short ghost duplicate, with caps
                            local dupChance = (noPlayersNearby and DUP_CHANCE_BOOST_NO_PLAYERS or DUP_CHANCE_BASE)
                            if math.random() < dupChance and #state.duplicates < MAX_DUPLICATES_PER_ANOMALY and DESIDERIUM._GlobalGhostCount < MAX_GLOBAL_GHOSTS then
                                local dup = ents.Create("prop_physics")
                                if IsValid(dup) then
                                    dup:SetModel(e:GetModel())
                                    dup:SetPos(e:GetPos() + Vector(3,3,8))
                                    dup:SetAngles(e:GetAngles())
                                    dup:Spawn()
                                    dup:SetMoveType(MOVETYPE_NONE)
                                    dup:SetSolid(SOLID_NONE)
                                    dup:SetRenderMode(RENDERMODE_TRANSALPHA)
                                    dup:SetColor(Color(200,255,220,120))
                                    table.insert(state.duplicates, dup)
                                    DESIDERIUM._GlobalGhostCount = DESIDERIUM._GlobalGhostCount + 1
                                    timer.Simple(math.Rand(2,5), function() if IsValid(dup) then SafeRemoveEntity(dup) end DESIDERIUM._GlobalGhostCount = math.max(0, (DESIDERIUM._GlobalGhostCount or 1) - 1) end)
                                    EmitEvent("OnInstabilityEvent", {type = "ghost_dup", target = e})
                                end
                            end

                            sound.Play("ambient/alarms/klaxon1.wav", e:GetPos(), 64, 120, 0.28)
                            EmitEvent("OnTouch", {target = e})
                        end
                    end
                end

            end, debug.traceback)

            if not ok then
                print("[desiderium] observer_node timer error:", err)
                -- attempt graceful cleanup
                if IsValid(ent) then ent:StopSound(LoopSound); SafeRemoveEntity(ent) end
                for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
                if timer.Exists(timerName) then timer.Remove(timerName) end
            end
        end)

        return true, function()
            if timer.Exists(timerName) then timer.Remove(timerName) end
            if IsValid(ent) then ent:StopSound(LoopSound); SafeRemoveEntity(ent) end
            for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
        end
    end,

    Cleanup = function(ctx)
        -- nothing global here
    end,
})
