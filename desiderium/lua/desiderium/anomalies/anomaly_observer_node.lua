--[[
DESIDERIUM Anomaly: Observer Node (v2)
File: desiderium/lua/desiderium/anomalies/anomaly_observer_node.lua

Updates in v2:
- Observability state machine: DIRECT / INDIRECT / UNOBSERVED
  * DIRECT: overexposed white, audio suppressed, position locked.
  * INDIRECT: flicker state (brief visibility flickers), audio reduced.
  * UNOBSERVED: full behavior with richer wandering, jitter-teleport, afterimages.
- Respects global gate: if sv_addendum_enable becomes 0 the node cleans up immediately.
- More wandering: higher movement probability and non-linear drift; occasional small teleports (5-30 units) when unobserved.
- Afterimages: short-lived faded clones left behind when teleporting.
- Hooks: OnObserved/OnUnobserved/OnTouch/OnInstabilityEvent stubs emitted via DESIDERIUM events.

Design choices / safety:
- Still server-side only; afterimages are light-weight temporary props removed after 2s.
- Duplication ghost events are rarer and duplicates are short-lived.
- Auto-life and duplication timings are conservative; tune as needed.
]]--

if CLIENT then return end

local Model = "models/props_phx/ball.mdl"
local LoopSound = "ambient/levels/citadel/citadel_drone_loop1.wav"
local AppearSound = "ambient/alarms/klaxon1.wav"

local CONSOLE_GATE_CVAR = "sv_addendum_enable"

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
        local tr = util.TraceLine({
            start = eye,
            endpos = entPos,
            filter = ply,
            mask = MASK_SHOT
        })
        if tr.Entity == ent then
            return true, ply
        end
    end
    return false, nil
end

local function IsPlayerIndirectlyObserving(ent)
    -- crude heuristic: a trace toward the entity hits a prop very near it
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

local function RandomNearbyTarget(ent, radius)
    radius = radius or 800
    local pos = ent:GetPos()
    local candidates = {}

    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:Alive() then continue end
        if ply:GetPos():DistToSqr(pos) <= radius * radius then
            table.insert(candidates, ply)
        end
    end

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
    timer.Simple(2, function() if IsValid(ghost) then SafeRemoveEntity(ghost) end end)
end

-- Expose simple event emitters for chaining
local function EmitEvent(name, data)
    DESIDERIUM = DESIDERIUM or {}
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
        -- respect gate: if closed, don't start
        if not GetConVar(CONSOLE_GATE_CVAR):GetBool() then return false end

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

        DESIDERIUM._ObserverLogs = DESIDERIUM._ObserverLogs or {}

        local state = {
            ent = ent,
            mode = "UNOBSERVED", -- DIRECT / INDIRECT / UNOBSERVED
            touched = {},
            duplicates = {},
            life = CurTime() + 120,
            lastTeleport = 0,
            lastAfterimage = 0,
        }

        local timerName = "desiderium_observer_node_" .. tostring(ent:EntIndex())

        timer.Create(timerName, 0.09, 0, function()
            if not IsValid(ent) then timer.Remove(timerName) return end

            -- If gate closed, shutdown
            if not GetConVar(CONSOLE_GATE_CVAR):GetBool() then
                -- cleanup
                if IsValid(ent) then
                    ent:StopSound(LoopSound)
                    SafeRemoveEntity(ent)
                end
                for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
                timer.Remove(timerName)
                return
            end

            -- Auto life expire
            if CurTime() >= state.life then
                if IsValid(ent) then
                    ent:StopSound(LoopSound)
                    SafeRemoveEntity(ent)
                end
                for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
                timer.Remove(timerName)
                return
            end

            -- Always spin a little for presence
            if state.mode ~= "DIRECT" then
                local a = ent:GetAngles()
                a.y = a.y + 45 * (0.09) -- scaled per tick
                ent:SetAngles(a)
            end

            -- Visibility checks
            local directP = IsPlayerDirectlyObserving(ent)
            local indirectP, indirectBy, via = IsPlayerIndirectlyObserving(ent)
            local newMode = "UNOBSERVED"
            local observerPlayer = nil
            if directP then
                newMode = "DIRECT"
                observerPlayer = directP and select(2, IsPlayerDirectlyObserving(ent))
            elseif indirectP then
                newMode = "INDIRECT"
                observerPlayer = indirectBy
            end

            if newMode ~= state.mode then
                -- Mode transition
                if newMode == "DIRECT" then
                    state.mode = "DIRECT"
                    -- log
                    table.insert(DESIDERIUM._ObserverLogs, {time = CurTime(), type = "observed_direct", by = IsValid(observerPlayer) and observerPlayer:SteamID() or "unknown"})
                    EmitEvent("OnObserved", {anomaly = "observer_node", by = observerPlayer})

                    -- visual overexpose
                    ent:SetNoDraw(false)
                    ent:SetColor(Color(255,255,255,220))
                    ent:SetRenderMode(RENDERMODE_TRANSALPHA)
                    -- audio suppression
                    ent:StopSound(LoopSound)
                    sound.Play("ambient/atmosphere/ambience_sky.wav", ent:GetPos(), 70, 90, 0.2)
                    -- lock position by keeping current pos
                elseif newMode == "INDIRECT" then
                    state.mode = "INDIRECT"
                    table.insert(DESIDERIUM._ObserverLogs, {time = CurTime(), type = "observed_indirect", via = tostring(via)})
                    EmitEvent("OnIndirectObserved", {anomaly = "observer_node", via = via})
                    -- flicker: quick alpha modulation
                    ent:SetNoDraw(false)
                    ent:SetColor(Color(255,255,255,180))
                    ent:StopSound(LoopSound)
                    sound.Play("ambient/alarms/klaxon1.wav", ent:GetPos(), 70, 120, 0.25)
                else
                    state.mode = "UNOBSERVED"
                    table.insert(DESIDERIUM._ObserverLogs, {time = CurTime(), type = "unobserved"})
                    EmitEvent("OnUnobserved", {anomaly = "observer_node"})
                    -- resume
                    ent:SetNoDraw(false)
                    ent:SetColor(Color(180,255,200,255))
                    ent:EmitSound(LoopSound, 80, 100)
                    sound.Play("buttons/button17.wav", ent:GetPos(), 75, 100, 0.6)
                end
            end

            -- Behavior per mode
            if state.mode == "DIRECT" then
                -- Hard freeze: do nothing, keep locked
                -- Slight visual shimmer occasionally
                if math.random() < 0.06 then
                    sound.Play("ambient/atmosphere/thunder1.wav", ent:GetPos(), 75, 90, 0.15)
                end
                return
            end

            if state.mode == "INDIRECT" then
                -- Flicker: toggle small NoDraw pulses
                if math.random() < 0.28 then
                    ent:SetNoDraw(true)
                    timer.Simple(0.06, function() if IsValid(ent) then ent:SetNoDraw(false) end end)
                end
                -- small nudge movement
                if math.random() < 0.5 then
                    ent:SetPos(ent:GetPos() + VectorRand() * math.Rand(5,18))
                end
                return
            end

            -- UNOBSERVED: full behavior
            -- Occasional small teleport jitter (re-roll)
            if CurTime() - state.lastTeleport > 0.6 and math.random() < 0.15 then
                local jitter = VectorRand() * math.Rand(5,30)
                ent:SetPos(ent:GetPos() + jitter)
                state.lastTeleport = CurTime()
                -- afterimage
                if CurTime() - state.lastAfterimage > 0.2 then
                    MakeAfterimage(ent)
                    state.lastAfterimage = CurTime()
                end
                sound.Play("buttons/lever7.wav", ent:GetPos(), 65, 100, 0.4)
            end

            -- Movement: richer wandering toward interest vectors
            if math.random() < 0.62 then
                local tgt = RandomNearbyTarget(ent, 900)
                if IsValid(tgt) then
                    local tgtPos = tgt:GetPos()
                    local curPos = ent:GetPos()
                    local dir = (tgtPos + VectorRand()*math.Rand(-40,40) - curPos)
                    if dir:Length() > 1 then
                        dir:Normalize()
                        local step = 30 + math.random() * 80
                        ent:SetPos(curPos + dir * (step * FrameTime() * 20))
                    end
                else
                    ent:SetPos(ent:GetPos() + VectorRand() * math.Rand(8,40))
                end
            end

            -- Touch interactions
            for _, e in ipairs(ents.FindInSphere(ent:GetPos(), 96)) do
                if not IsValid(e) or e == ent then continue end
                local cls = e:GetClass() or ""
                if cls:find("prop_physics") then
                    local last = state.touched[e] or 0
                    if CurTime() - last > 1.2 then
                        state.touched[e] = CurTime()

                        local phys = e:GetPhysicsObject()
                        if IsValid(phys) then
                            phys:ApplyForceCenter(VectorRand() * 800)
                            phys:AddAngleVelocity(Vector(math.Rand(-20,20), math.Rand(-20,20), math.Rand(-20,20)))
                        end

                        e:SetAngles(e:GetAngles() + Angle(math.Rand(-6,6), math.Rand(-6,6), math.Rand(-6,6)))

                        -- instability leak: small gravity reduction nearby
                        local nearby = ents.FindInSphere(e:GetPos(), 220)
                        for _, ne in ipairs(nearby) do
                            if IsValid(ne) and ne:GetPhysicsObject() then
                                local p = ne:GetPhysicsObject()
                                p:Wake()
                                p:ApplyForceCenter(Vector(0,0, -50)) -- subtle
                            end
                        end

                        -- rare short ghost duplicate
                        if math.random() < 0.03 then
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
                                timer.Simple(math.Rand(2,5), function() if IsValid(dup) then SafeRemoveEntity(dup) end end)
                                EmitEvent("OnInstabilityEvent", {type = "ghost_dup", target = e})
                            end
                        end

                        sound.Play("ambient/alarms/klaxon1.wav", e:GetPos(), 68, 120, 0.35)
                        EmitEvent("OnTouch", {target = e})
                    end
                end
            end
        end)

        -- return cleanup closure to dispatcher
        return true, function()
            if timer.Exists(timerName) then timer.Remove(timerName) end
            if IsValid(ent) then
                ent:StopSound(LoopSound)
                SafeRemoveEntity(ent)
            end
            for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
        end
    end,

    Cleanup = function(ctx)
        -- nothing global here; Trigger provided its own cleanup closure
    end,
})
