--[[
DESIDERIUM Anomaly: Observer Node
File: desiderium/lua/desiderium/anomalies/anomaly_observer_node.lua

Behavior summary:
- Spawns a small floating ball (models/props_phx/ball.mdl) that spins and emits
  a droning loop. It is observation-aware: when a player directly looks at it
  it becomes invisible/quiet and records an "attention lock" entry.
- While unobserved it slowly drifts toward interesting targets (players/props)
  and occasionally touches them to jitter physics, nudge rotation, and rarely
  duplicate the prop (short-lived duplicate to avoid accumulation).

Design notes:
- Server-only. Uses DESIDERIUM.RegisterAnomaly to integrate with the core.
- Keeps per-anomaly timers but cleans them up in the Cleanup function.
- Uses simple line traces from player eyes to detect "observed" state.
]]--

if CLIENT then return end

local Model = "models/props_phx/ball.mdl"
local LoopSound = "ambient/levels/citadel/citadel_drone_loop1.wav"
local AppearSound = "ambient/alarms/klaxon1.wav" -- one-shot; if missing it's harmless

local function IsPlayerObservingEntity(ent)
    if not IsValid(ent) then return false end
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:Alive() then continue end
        local eye = ply:EyePos()
        local dir = ply:GetAimVector()
        local tr = util.TraceLine({
            start = eye,
            endpos = eye + dir * 3000,
            filter = ply,
            mask = MASK_SHOT
        })
        if tr.Entity == ent then
            return true, ply
        end
    end
    return false, nil
end

local function PickAnchorPoint()
    -- Prefer random prop_physics; fallback to random player; fallback to map origin
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

local function RandomNearbyTarget(ent, radius)
    radius = radius or 500
    local pos = ent:GetPos()
    local candidates = {}

    -- players
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:Alive() then continue end
        if ply:GetPos():DistToSqr(pos) <= radius * radius then
            table.insert(candidates, ply)
        end
    end

    -- props & npcs
    for _, e in ipairs(ents.FindInSphere(pos, radius)) do
        if not IsValid(e) or e == ent then continue end
        local cls = e:GetClass() or ""
        if cls:find("prop_physics") or e:IsNPC() or e:IsPlayer() then
            table.insert(candidates, e)
        end
    end

    if #candidates == 0 then return nil end
    return candidates[math.random(#candidates)]
end

DESIDERIUM.RegisterAnomaly("observer_node", {
    Weight = 1,
    Cooldown = 120,
    MinPlayers = 1,

    CanTrigger = function(ctx)
        -- Simple gating: at least one player on server
        return #player.GetAll() >= 1
    end,

    Trigger = function(ctx)
        local origin = PickAnchorPoint()
        local ent = ents.Create("prop_physics")
        if not IsValid(ent) then return false end

        ent:SetModel(Model)
        ent:SetPos(origin)
        ent:Spawn()
        ent:SetMoveType(MOVETYPE_NONE)
        ent:SetSolid(SOLID_VPHYSICS)
        ent:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
        ent:DrawShadow(false)
        ent:SetRenderMode(RENDERMODE_TRANSALPHA)

        -- Make it visually distinctive
        ent:SetColor(Color(180,255,200))

        -- Start loop sound
        ent:EmitSound(LoopSound, 80, 100)
        -- Appear cue
        sound.Play(AppearSound, ent:GetPos(), 100, 100, 1)

        -- Log/broadcast
        if DESIDERIUM and DESIDERIUM.BroadcastGateMessage then
            DESIDERIUM.BroadcastGateMessage("[DESIDERIUM SERVER] ANOMALY DATABASE DETECTED, OBSERVER NODE HAS ENTERED.", false)
            timer.Simple(4, function()
                if IsValid(ent) then
                    DESIDERIUM.BroadcastGateMessage("[DESIDERIUM SERVER] DANGEROUS RANK DATABASE > RANK 0.1", false)
                    sound.Play("ambient/alarms/klaxon1.wav", ent:GetPos(), 100, 110, 0.8)
                end
            end)
        end

        -- Internal attention logs table
        DESIDERIUM._ObserverLogs = DESIDERIUM._ObserverLogs or {}

        -- state
        local state = {
            ent = ent,
            observed = false,
            touched = {}, -- map of last touch times per ent
            duplicates = {},
            life = CurTime() + 90, -- auto-cleanup after 90s
        }

        local timerName = "desiderium_observer_node_" .. tostring(ent:EntIndex())

        timer.Create(timerName, 0.12, 0, function()
            if not IsValid(ent) then timer.Remove(timerName) return end

            -- Auto life expire
            if CurTime() >= state.life then
                -- cleanup
                if IsValid(ent) then
                    ent:StopSound(LoopSound)
                    SafeRemoveEntity(ent)
                end
                for _, d in ipairs(state.duplicates) do
                    if IsValid(d) then SafeRemoveEntity(d) end
                end
                timer.Remove(timerName)
                return
            end

            -- Spin effect
            local a = ent:GetAngles()
            a.y = a.y + 30
            ent:SetAngles(a)

            -- Observation check
            local obs, ply = IsPlayerObservingEntity(ent)
            if obs and not state.observed then
                state.observed = true
                -- attention lock
                table.insert(DESIDERIUM._ObserverLogs, {time = CurTime(), type = "attention_lock", by = IsValid(ply) and ply:SteamID() or "unknown"})

                -- hide and silence
                ent:SetNoDraw(true)
                ent:StopSound(LoopSound)
                -- subtle distortion cue
                sound.Play("ambient/atmosphere/thunder1.wav", ent:GetPos(), 80, 90, 0.6)
            elseif not obs and state.observed then
                state.observed = false
                ent:SetNoDraw(false)
                -- resume loop
                ent:EmitSound(LoopSound, 80, 100)
                sound.Play("buttons/button17.wav", ent:GetPos(), 75, 100, 0.6)
            end

            if state.observed then return end

            -- Movement: slowly drift toward an interesting target occasionally
            if math.random() < 0.22 then
                local tgt = RandomNearbyTarget(ent, 600)
                if IsValid(tgt) then
                    local tgtPos = (tgt:IsPlayer() or tgt:IsNPC()) and tgt:GetPos() or tgt:GetPos()
                    local curPos = ent:GetPos()
                    local dir = (tgtPos - curPos)
                    if dir:Length() > 1 then
                        dir:Normalize()
                        local newPos = curPos + dir * (20 + math.random() * 40)
                        ent:SetPos(newPos)
                    end
                else
                    -- small random wander
                    local rnd = VectorRand() * 20
                    ent:SetPos(ent:GetPos() + rnd)
                end
            end

            -- Touch interactions: find close props
            for _, e in ipairs(ents.FindInSphere(ent:GetPos(), 80)) do
                if not IsValid(e) or e == ent then continue end
                local cls = e:GetClass() or ""
                if cls:find("prop_physics") then
                    local last = state.touched[e] or 0
                    if CurTime() - last > 2 then
                        state.touched[e] = CurTime()

                        -- physics jitter
                        local phys = e:GetPhysicsObject()
                        if IsValid(phys) then
                            phys:ApplyForceCenter(VectorRand() * 500)
                            phys:AddAngleVelocity(Vector(math.Rand(-10,10), math.Rand(-10,10), math.Rand(-10,10)))
                        end

                        -- slight rotation nudge
                        e:SetAngles(e:GetAngles() + Angle(math.Rand(-3,3), math.Rand(-3,3), math.Rand(-3,3)))

                        -- rare duplication glitch
                        if math.random() < 0.05 then
                            local dup = ents.Create("prop_physics")
                            if IsValid(dup) then
                                dup:SetModel(e:GetModel())
                                dup:SetPos(e:GetPos() + Vector(5,5,10))
                                dup:Spawn()
                                local p2 = dup:GetPhysicsObject()
                                if IsValid(p2) then
                                    p2:ApplyForceCenter(VectorRand() * 200)
                                end
                                table.insert(state.duplicates, dup)
                                -- remove duplicate after a short time
                                timer.Simple(40 + math.random() * 40, function()
                                    if IsValid(dup) then SafeRemoveEntity(dup) end
                                end)
                            end
                        end

                        -- subtle touch sound
                        sound.Play("ambient/alarms/klaxon1.wav", e:GetPos(), 70, 120, 0.4)
                    end
                end
            end
        end)

        -- expose cleanup handle for the dispatcher
        return true, function()
            if timer.Exists(timerName) then timer.Remove(timerName) end
            if IsValid(ent) then
                ent:StopSound(LoopSound)
                SafeRemoveEntity(ent)
            end
            for _, d in ipairs(state.duplicates) do
                if IsValid(d) then SafeRemoveEntity(d) end
            end
        end
    end,

    Cleanup = function(ctx)
        -- dispatcher may call this; anomalies created their own cleanup in Trigger return
        -- nothing global to do here
    end,
})
