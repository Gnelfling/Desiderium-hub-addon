--[[
DESIDERIUM Anomaly: Observer Node (v3.2 - AI-like movement, faster spin, removal sound/effect)
File: desiderium/lua/desiderium/anomalies/anomaly_observer_node.lua

Changes in v3.2:
- Removed flashlight-based containment (was unreliable).
- Damage still forces DIRECT/freeze and plays alert sound (changed to whiteflash.wav).
- The node now moves with a simple AI-like steering using MOVETYPE_FLY and SetVelocity when UNOBSERVED.
  * Picks nearby targets (players/props) and drifts toward them non-linearly.
  * When DIRECT (observed) it stops immediately and zeroes velocity.
- Spin rate increased for a faster visual spin; timer tick rate increased for smoother updates.
- Keeps safety guards, duplicate caps, removal sound/effect, and protected timer.
]]--

if CLIENT then return end

local Model = "models/props_phx/ball.mdl"
local LoopSound = "ambient/levels/citadel/citadel_drone_loop1.wav"
local AppearSound = "ambient/alarms/klaxon1.wav"
local TouchSound = "ambient/alarms/warningbell1.wav"
local RemovalSound = "ambient/energy/spark1.wav"
local AlertSound = "ambient/energy/whiteflash.wav" -- changed per request

local CONSOLE_GATE_CVAR = "sv_addendum_enable"

-- Tunables and safety limits
local TOUCH_FORCE = 180
local TOUCH_ANGVEL = 8
local VELOCITY_SKIP_THRESHOLD = 900
local MAX_DUPLICATES_PER_ANOMALY = 8
local MAX_GLOBAL_GHOSTS = 18
local DUP_CHANCE_BASE = 0.05
local DUP_CHANCE_BOOST_NO_PLAYERS = 0.06
local GRAVITY_PULSE_FORCE = 80

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._GlobalGhostCount = DESIDERIUM._GlobalGhostCount or 0
DESIDERIUM._ObserverLogs = DESIDERIUM._ObserverLogs or {}

local function EmitEvent(name, data)
    if DESIDERIUM.OnAnomalyEvent and type(DESIDERIUM.OnAnomalyEvent) == "function" then
        pcall(DESIDERIUM.OnAnomalyEvent, name, data)
    end
end

local function IsPlayerDirectlyObserving(ent)
    if not IsValid(ent) then return false, nil end
    local entPos = ent:WorldSpaceCenter()
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:Alive() then continue end
        local eye = ply:EyePos()
        local dir = (entPos - eye):GetNormalized()
        local dot = math.max(-1, math.min(1, ply:GetAimVector():Dot(dir)))
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

local function RandomNearbyTarget(ent, radius)
    radius = radius or 1200
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
        -- Use MOVETYPE_FLY for smooth AI-like movement via SetVelocity
        ent:SetMoveType(MOVETYPE_FLY)
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
            mode = "UNOBSERVED",
            touched = {},
            duplicates = {},
            life = CurTime() + 120,
            lastAfterimage = 0,
            anchor = ent:GetPos(),
            angAccum = 0,
            lastTick = CurTime(),
            frozenUntil = 0,
            target = nil,
            moveSpeed = 20,
        }

        local damageHookName = "desiderium_observer_damage_" .. tostring(ent:EntIndex())
        hook.Add("EntityTakeDamage", damageHookName, function(target, dmg)
            if target == ent then
                state.mode = "DIRECT"
                state.frozenUntil = CurTime() + 8
                sound.Play(AlertSound, ent:GetPos(), 90, 100, 1)
                table.insert(DESIDERIUM._ObserverLogs, {time = CurTime(), type = "damaged", dmg = dmg:GetDamage()})
                EmitEvent("OnDamaged", {anomaly = "observer_node", damage = dmg:GetDamage()})
                -- zero velocity immediately
                if IsValid(ent) then ent:SetVelocity(Vector(0,0,0)) end
            end
        end)

        local timerName = "desiderium_observer_node_" .. tostring(ent:EntIndex())

        timer.Create(timerName, 0.04, 0, function()
            local ok, err = xpcall(function()
                if not IsValid(ent) then timer.Remove(timerName) return end

                -- Respect gate
                if not GetConVar(CONSOLE_GATE_CVAR):GetBool() then
                    if IsValid(ent) then
                        ent:StopSound(LoopSound)
                        sound.Play(RemovalSound, ent:GetPos(), 90, 100, 1)
                        local ed = EffectData(); ed:SetOrigin(ent:GetPos()); util.Effect("Sparks", ed)
                        SafeRemoveEntity(ent)
                    end
                    for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
                    hook.Remove("EntityTakeDamage", damageHookName)
                    timer.Remove(timerName)
                    return
                end

                -- Auto life expire
                if CurTime() >= state.life then
                    if IsValid(ent) then
                        ent:StopSound(LoopSound)
                        sound.Play(RemovalSound, ent:GetPos(), 90, 100, 1)
                        local ed = EffectData(); ed:SetOrigin(ent:GetPos()); util.Effect("Sparks", ed)
                        SafeRemoveEntity(ent)
                    end
                    for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
                    hook.Remove("EntityTakeDamage", damageHookName)
                    timer.Remove(timerName)
                    return
                end

                -- Smooth spin (faster)
                local now = CurTime()
                local dt = math.Clamp(now - (state.lastTick or now), 0, 0.2)
                state.lastTick = now
                local spinRate = 240 -- degrees/sec
                state.angAccum = (state.angAccum + spinRate * dt) % 360
                local ang = Angle(0, state.angAccum, 0)

                -- gentle bob
                local bob = math.sin(now * 1.6) * 3
                local basePos = state.anchor
                if IsValid(ent) then
                    ent:SetAngles(ang)
                    -- position handled by movement via velocity; keep anchor for bob reference when not moving
                    if state.mode ~= "UNOBSERVED" then
                        -- when observed, stay anchored exactly (no movement)
                        ent:SetPos(basePos + Vector(0,0,bob))
                        ent:SetVelocity(Vector(0,0,0))
                    end
                end

                -- Visibility checks
                local direct, dp = IsPlayerDirectlyObserving(ent)
                local indirect, ip, via = IsPlayerIndirectlyObserving(ent)
                local newMode = "UNOBSERVED"
                local observerPlayer = nil
                if direct or (state.frozenUntil > CurTime()) then
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
                        -- stop motion
                        if IsValid(ent) then ent:SetVelocity(Vector(0,0,0)) end
                    elseif newMode == "INDIRECT" then
                        state.mode = "INDIRECT"
                        table.insert(DESIDERIUM._ObserverLogs, {time = CurTime(), type = "observed_indirect", via = tostring(via)})
                        EmitEvent("OnIndirectObserved", {anomaly = "observer_node", via = via})
                        ent:SetNoDraw(false)
                        ent:SetColor(Color(255,255,255,180))
                        ent:StopSound(LoopSound)
                        sound.Play("ambient/alarms/klaxon1.wav", ent:GetPos(), 70, 120, 0.25)
                        if IsValid(ent) then ent:SetVelocity(Vector(0,0,0)) end
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

                if state.mode == "DIRECT" then
                    return
                end

                if state.mode == "INDIRECT" then
                    if math.random() < 0.22 then
                        ent:SetNoDraw(true)
                        timer.Simple(0.06, function() if IsValid(ent) then ent:SetNoDraw(false) end end)
                    end
                    return
                end

                -- UNOBSERVED: AI-like movement + corruption effects
                -- Choose or validate target
                if not IsValid(state.target) or math.random() < 0.08 then
                    state.target = RandomNearbyTarget(ent, 1200)
                end

                local speedBase = state.moveSpeed or 80
                local speed = speedBase + (DESIDERIUM.Exposure and (DESIDERIUM.Exposure / 10) or 0)

                if IsValid(state.target) then
                    local tgtPos = state.target:GetPos() + Vector(0,0,30)
                    local dir = (tgtPos - ent:GetPos())
                    if dir:Length() > 5 then
                        dir:Normalize()
                        if IsValid(ent) then
                            -- set velocity for smooth movement
                            ent:SetVelocity(dir * speed)
                        end
                    end
                else
                    -- gentle wandering
                    if IsValid(ent) then
                        ent:SetVelocity(VectorRand() * (speed * 0.25))
                    end
                end

                -- corruption: nudge nearby props
                local playersNearby = 0
                for _, ply in ipairs(player.GetAll()) do
                    if not IsValid(ply) or not ply:Alive() then continue end
                    if ply:GetPos():DistToSqr(ent:GetPos()) <= (900 * 900) then playersNearby = playersNearby + 1 end
                end
                local noPlayersNearby = (playersNearby == 0)

                if CurTime() - state.lastAfterimage > 0.4 and math.random() < 0.06 then
                    MakeAfterimage(ent)
                    state.lastAfterimage = CurTime()
                end

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
                                    local magnitude = TOUCH_FORCE * (noPlayersNearby and 1.8 or 1.0)
                                    phys:ApplyForceCenter(VectorRand() * magnitude)
                                    phys:AddAngleVelocity(Vector(math.Rand(-TOUCH_ANGVEL,TOUCH_ANGVEL), math.Rand(-TOUCH_ANGVEL,TOUCH_ANGVEL), math.Rand(-TOUCH_ANGVEL,TOUCH_ANGVEL)))
                                end
                            end

                            e:SetAngles(e:GetAngles() + Angle(math.Rand(-2,2), math.Rand(-2,2), math.Rand(-2,2)))

                            local nearby = ents.FindInSphere(e:GetPos(), 180)
                            for _, ne in ipairs(nearby) do
                                if not IsValid(ne) then continue end
                                local p = ne:GetPhysicsObject()
                                if IsValid(p) then
                                    local v = p:GetVelocity()
                                    if v:Length() <= VELOCITY_SKIP_THRESHOLD then
                                        p:ApplyForceCenter(Vector(0,0, -GRAVITY_PULSE_FORCE))
                                    end
                                end
                            end

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

                            sound.Play(TouchSound, e:GetPos(), 64, 100, 0.34)
                            EmitEvent("OnTouch", {target = e})
                        end
                    end
                end

            end, debug.traceback)

            if not ok then
                print("[desiderium] observer_node timer error:", err)
                if IsValid(ent) then
                    ent:StopSound(LoopSound)
                    sound.Play(RemovalSound, ent:GetPos(), 90, 100, 1)
                    local ed = EffectData(); ed:SetOrigin(ent:GetPos()); util.Effect("Sparks", ed)
                    SafeRemoveEntity(ent)
                end
                for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
                hook.Remove("EntityTakeDamage", damageHookName)
                if timer.Exists(timerName) then timer.Remove(timerName) end
            end
        end)

        return true, function()
            if timer.Exists(timerName) then timer.Remove(timerName) end
            if IsValid(ent) then
                ent:StopSound(LoopSound)
                sound.Play(RemovalSound, ent:GetPos(), 90, 100, 1)
                local ed = EffectData(); ed:SetOrigin(ent:GetPos()); util.Effect("Sparks", ed)
                SafeRemoveEntity(ent)
            end
            for _, d in ipairs(state.duplicates) do if IsValid(d) then SafeRemoveEntity(d) end end
            hook.Remove("EntityTakeDamage", damageHookName)
        end
    end,

    Cleanup = function(ctx)
    end,
})
