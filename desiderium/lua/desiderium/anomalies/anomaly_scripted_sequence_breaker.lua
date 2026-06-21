--[[
DESIDERIUM Anomaly: Scripted Sequence Breaker
File: desiderium/lua/desiderium/anomalies/anomaly_scripted_sequence_breaker.lua

Behavior summary:
- Spawns an npc_citizen that behaves as if running a corrupted scripted_sequence.
- Executes a short, repeatable sequence of steps (MoveToPosition, FaceAngle, PlayAnimation, Wait, UseAttempt).
- Steps may be missing/fail; NPC retries with slight variation and degrades over time.
- NPC ignores damage/combat (damage is zeroed out) and will not engage enemies.
- Respects the DESIDERIUM gate: if sv_addendum_enable closes the NPC is cleaned up.
- Exposes events via DESIDERIUM.OnAnomalyEvent and logs to DESIDERIUM._SequenceLogs.

Safety and containment:
- Per-NPC timer drives the sequence; the timer is protected by xpcall so runtime errors won't silently kill it.
- Cleanup closure returns proper removal of hooks and timers.
- NPC movement uses MOVETYPE_STEP and SetLastPosition/SetSchedule where possible; falls back to SetPos if necessary.
- Limits spawn to one NPC per Trigger call; duplicates are short-lived and controlled by the system.

Design note:
- This anomaly intentionally avoids combat logic and acts purely as a sequence executor. It can be extended to accept external anchors/markers for containment.
]]--

if CLIENT then return end

local NPC_CLASS = "npc_citizen"
local START_SOUND = "vo/npc/male01/answer10.wav"
local FAIL_SOUND = "ambient/alarms/klaxon1.wav"
local FINISH_SOUND = "ambient/alarms/warningbell1.wav"

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM._SequenceLogs = DESIDERIUM._SequenceLogs or {}

local function EmitEvent(name, data)
    if DESIDERIUM.OnAnomalyEvent and type(DESIDERIUM.OnAnomalyEvent) == "function" then
        pcall(DESIDERIUM.OnAnomalyEvent, name, data)
    end
end

-- Utility: pick some candidate nodes (props or players) around origin
local function GatherSequenceNodes(origin, radius, maxNodes)
    radius = radius or 800
    maxNodes = maxNodes or 4
    local nodes = {}

    -- Prefer anchored props
    for _, e in ipairs(ents.FindInSphere(origin, radius)) do
        if not IsValid(e) then continue end
        local cls = e:GetClass() or ""
        if cls:find("prop_physics") then
            table.insert(nodes, {pos = e:GetPos() + Vector(0,0,20), ent = e})
            if #nodes >= maxNodes then break end
        end
    end

    -- Add players as potential nodes
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:Alive() then continue end
        if ply:GetPos():DistToSqr(origin) <= radius * radius then
            table.insert(nodes, {pos = ply:GetPos() + Vector(0,0,10), ent = ply})
            if #nodes >= maxNodes then break end
        end
    end

    -- If empty, create a few synthetic points
    for i = 1, maxNodes do
        if #nodes >= maxNodes then break end
        local off = VectorRand() * math.Rand(80, 300)
        table.insert(nodes, {pos = origin + off, ent = nil})
    end

    return nodes
end

DESIDERIUM.RegisterAnomaly("scripted_sequence_breaker", {
    Weight = 1.5,
    Cooldown = 160,
    MinPlayers = 1,

    CanTrigger = function(ctx)
        return #player.GetAll() >= 1
    end,

    Trigger = function(ctx)
        if not GetConVar("sv_addendum_enable"):GetBool() then return false end

        local origin = ctx and ctx.origin or Vector(0,0,64)
        -- pick an anchor near players if possible
        local plys = player.GetAll()
        if #plys > 0 then origin = plys[math.random(#plys)]:GetPos() + Vector(0,0,40) end

        local npc = ents.Create(NPC_CLASS)
        if not IsValid(npc) then return false end

        npc:SetPos(origin + Vector(math.Rand(-40,40), math.Rand(-40,40), 0))
        npc:Spawn()
        npc:Activate()

        -- Make it non-combat, scripted-only: strip weapon, disable target acquisition
        npc:SetKeyValue("citizentype", "3") -- make it passive if supported
        npc:SetNPCState(NPC_STATE_SCRIPT)

        -- Prevent damage from affecting behavior by zeroing damage in hook
        local damageHook = "desiderium_seq_damage_" .. tostring(npc:EntIndex())
        hook.Add("EntityTakeDamage", damageHook, function(target, dmg)
            if target == npc then
                -- zero damage to make it ignore combat
                if dmg and dmg:IsValid() then
                    dmg:SetDamage(0)
                end
            end
        end)

        -- Sequence generation
        local nodes = GatherSequenceNodes(npc:GetPos(), 1000, 5)
        -- Build a nominal sequence: move -> face -> interact -> wait
        local sequence = {}
        for i = 1, math.max(2, math.min(4, #nodes)) do
            local n = nodes[((i-1) % #nodes) + 1]
            table.insert(sequence, {type = "MoveTo", pos = n.pos, ent = n.ent})
            table.insert(sequence, {type = "Face", ang = Angle(0, math.random(-180,180), 0)})
            table.insert(sequence, {type = "Interact", ent = n.ent})
            table.insert(sequence, {type = "Wait", duration = math.Rand(1.2, 3.5)})
        end

        -- State
        local state = {
            npc = npc,
            sequence = sequence,
            index = 1,
            retries = 0,
            degraded = 0,
            life = CurTime() + 140,
            timerName = "desiderium_seq_" .. tostring(npc:EntIndex()),
            lastMoveTarget = nil,
        }

        -- Play a starting cue
        npc:EmitSound(START_SOUND)
        table.insert(DESIDERIUM._SequenceLogs, {time = CurTime(), event = "spawn", npc = npc:GetClass(), pos = npc:GetPos()})
        EmitEvent("SequenceSpawned", {npc = npc})

        -- Helper: instruct NPC to move to position in a best-effort way
        local function InstructMoveTo(npcEnt, pos)
            if not IsValid(npcEnt) then return false end
            -- prefer engine nav movement if available
            if npcEnt.SetLastPosition and npcEnt.SetSchedule then
                npcEnt:SetLastPosition(pos)
                -- try forced go schedule; fall back to Run
                if SERVER and SCHED_FORCED_GO_RUN then
                    npcEnt:SetSchedule(SCHED_FORCED_GO_RUN)
                else
                    npcEnt:SetSchedule(SCHED_FORCED_GO)
                end
                return true
            else
                -- fallback: teleport a short distance toward target gradually
                npcEnt:SetPos(LerpVector(0.2, npcEnt:GetPos(), pos))
                return true
            end
        end

        -- Timer to execute sequence steps
        timer.Create(state.timerName, 0.25, 0, function()
            local ok, err = xpcall(function()
                if not IsValid(npc) then timer.Remove(state.timerName) return end

                -- Respect gate and lifespan
                if not GetConVar("sv_addendum_enable"):GetBool() or CurTime() >= state.life then
                    if IsValid(npc) then
                        npc:StopSound(START_SOUND)
                        SafeRemoveEntity(npc)
                    end
                    hook.Remove("EntityTakeDamage", damageHook)
                    timer.Remove(state.timerName)
                    EmitEvent("SequenceEnded", {npc = npc})
                    return
                end

                -- Degradation over time: increase degraded counter occasionally
                if math.random() < 0.04 then
                    state.degraded = state.degraded + 1
                end

                local step = state.sequence[state.index]
                if not step then
                    -- loop back with small chance of picking a wrong target (failure)
                    state.index = 1
                    state.retries = 0
                    return
                end

                -- Execute step types
                if step.type == "MoveTo" then
                    -- simulate missing destination by sometimes failing
                    if math.random() < 0.12 then
                        -- failure: snap back slightly and retry
                        npc:SetPos(npc:GetPos() + Vector(math.Rand(-8,8), math.Rand(-8,8), 0))
                        npc:EmitSound(FAIL_SOUND)
                        state.retries = state.retries + 1
                        if state.retries > 3 then
                            state.index = state.index + 1
                            state.retries = 0
                        end
                        table.insert(DESIDERIUM._SequenceLogs, {time = CurTime(), event = "move_fail", npc = npc, pos = step.pos})
                    else
                        -- instruct movement
                        InstructMoveTo(npc, step.pos)
                        state.lastMoveTarget = step.pos
                        -- if close enough, advance the sequence
                        if npc:GetPos():DistToSqr(step.pos) <= (64*64) or state.retries > 6 then
                            state.index = state.index + 1
                            state.retries = 0
                        else
                            state.retries = state.retries + 1
                        end
                    end

                elseif step.type == "Face" then
                    -- face a direction; if degraded, face wrong way randomly
                    local ang = step.ang
                    if state.degraded > 2 and math.random() < 0.25 then
                        ang = Angle(0, math.random(-180,180), 0)
                    end
                    npc:SetAngles(ang)
                    state.index = state.index + 1

                elseif step.type == "Interact" then
                    -- attempt to 'use' an entity (if present) or fake-animate
                    if step.ent and IsValid(step.ent) and math.random() < 0.6 then
                        -- do a naive 'use' by touching or playing an animation
                        npc:SetLastPosition(step.ent:GetPos())
                        npc:SetSchedule( SCHED_FORCED_GO )
                        npc:EmitSound("buttons/button3.wav")
                        state.index = state.index + 1
                        table.insert(DESIDERIUM._SequenceLogs, {time = CurTime(), event = "interact_ok", target = step.ent})
                    else
                        -- missing trigger: play idle/use animation and fail
                        npc:EmitSound("vo/npc/male01/question01.wav")
                        state.retries = state.retries + 1
                        if state.retries > 2 then
                            state.index = state.index + 1
                            state.retries = 0
                        end
                        table.insert(DESIDERIUM._SequenceLogs, {time = CurTime(), event = "interact_fail"})
                    end

                elseif step.type == "Wait" then
                    -- wait with possible animation desync
                    if state.degraded > 1 and math.random() < 0.4 then
                        -- act wrong: play walking anim while idle
                        npc:StartActivity( ACT_WALK )
                    else
                        npc:StartActivity( ACT_IDLE )
                    end
                    -- wait: use duration as chance to advance
                    if math.random() < (1/ (step.duration or 2.0)) then
                        state.index = state.index + 1
                    end
                else
                    state.index = state.index + 1
                end

                -- Occasionally, pick wrong target to simulate corruption
                if math.random() < 0.06 then
                    local fallback = GatherSequenceNodes(npc:GetPos(), 900, 3)[1]
                    if fallback and fallback.pos then
                        state.index = math.max(1, state.index - 1)
                        state.sequence[state.index] = { type = "MoveTo", pos = fallback.pos, ent = fallback.ent }
                    end
                end

            end, debug.traceback)

            if not ok then
                print("[desiderium] sequence breaker timer error:", err)
                if IsValid(npc) then SafeRemoveEntity(npc) end
                hook.Remove("EntityTakeDamage", damageHook)
                if timer.Exists(state.timerName) then timer.Remove(state.timerName) end
            end
        end)

        -- Return cleanup closure for dispatcher
        return true, function()
            if timer.Exists(state.timerName) then timer.Remove(state.timerName) end
            if IsValid(npc) then
                SafeRemoveEntity(npc)
            end
            hook.Remove("EntityTakeDamage", damageHook)
        end
    end,

    Cleanup = function(ctx)
        -- dispatcher-level cleanup not needed here
    end,
})
