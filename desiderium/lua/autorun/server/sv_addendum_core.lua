--[[
	DESIDERIUM - Core Module (server-side startup cascade)
	This version sends chat messages from the server (PrintMessage) and
	emits a small client-side audio ping so clients hear a cue for each line.

	Note: Chat messages sent via PrintMessage/HUD_PRINTTALK are server-originated
	and will appear in client chat without requiring client autorun code.
	We still send a short net ping so clients can play an audio cue.
]]--

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM.Anomalies = DESIDERIUM.Anomalies or {}
DESIDERIUM.Version = "0.0.1-core"

CreateConVar(
	"sv_addendum_enable",
	"0",
	FCVAR_NOTIFY,
	"Internal addendum subsystem toggle.",
	0,
	1
)

-- Network string for playing a brief audio ping on clients
if SERVER then
	util.AddNetworkString("desiderium_startup_ping")
end

function DESIDERIUM.RegisterAnomaly( name, data )
	if DESIDERIUM.Anomalies[ name ] then
		print( "[DESIDERIUM] WARNING: anomaly '" .. name .. "' is already registered, overwriting." )
	end

	DESIDERIUM.Anomalies[ name ] = data
	print( "[DESIDERIUM] Registered anomaly module: " .. name )
end

-- Server-side boot cascade: print colored lines directly to server console
-- also print each line into client chat (server-originated) and send a small
-- net ping to clients so they play an audio cue.
local function BroadcastStartupLines()
	local lines = {
		"[DESIDERIUM] Initializing anomaly subsystem...",
		"[DESIDERIUM] Loading containment matrix...",
		"",
		"[ENGINE] sv_addendum_enable detected: TRUE",
		"[ENGINE] Authority level: OVERRIDE GRANTED",
		"",
		"[DESIDERIUM] Verifying anomaly registry...",
		"[DESIDERIUM] Registered entities: 03 active templates loaded",
		"[DESIDERIUM] Integrity check: PASS (some inconsistencies detected)",
		"",
		"[ENGINE] Starting physics hook extensions...",
		"[ENGINE] Lua environment secured",
		"",
		"[DESIDERIUM] Opening firewall gate...",
		"[DESIDERIUM] WARNING: containment boundary becoming unstable",
		"",
		"[DESIDERIUM] Syncing anomaly scheduler...",
		"[DESIDERIUM] Establishing spawn channels...",
		"",
		"[ENGINE] Networked entity tables updated",
		"[ENGINE] Pre-caching scripted_sequence handlers",
		"",
		"[DESIDERIUM] WARNING: observer interference detected (low level)",
		"[DESIDERIUM] WARNING: residual event traces found in memory buffer",
		"",
		"[DESIDERIUM] Firewall status: PARTIALLY OPEN",
		"",
		"[ENGINE] Activating anomaly runtime layer...",
		"",
		"[DESIDERIUM] Loading anomaly modules:",
		"    - anomaly_observer_node.lua .......... OK",
		"    - anomaly_replay_stutter.lua ......... OK",
		"    - anomaly_sequence_breaker.lua ....... OK",
		"    - anomaly_lockbreak_parasite.lua ..... OK",
		"",
		"[DESIDERIUM] Module stability: NOMINAL (degrading)",
		"",
		"[ENGINE] Hooking Think cycle...",
		"[ENGINE] Hooking Spawn events...",
		"[ENGINE] Hooking Damage override layer...",
		"",
		"[DESIDERIUM] WARNING: external observation not recommended",
		"",
		"[DESIDERIUM] Firewall state transition:",
		"        CLOSED -> OPENING -> ACTIVE",
		"",
		"[DESIDERIUM] SYSTEM ONLINE",
		"",
		"[ENGINE] Server anomaly layer is now ACTIVE",
	}

	for i = 1, #lines do
		local line = lines[i]
		timer.Simple(i * 0.06, function()
			if not line then return end
			-- server console colored output
			MsgC( Color(100,220,100), "[DESIDERIUM] ", Color(180,255,180), line .. "\n" )
			print( line )

			-- send as server-originated chat to clients
			PrintMessage(HUD_PRINTTALK, "[DESIDERIUM] " .. line)

			-- also send a tiny net ping so clients can play an audio cue
			if SERVER then
				net.Start("desiderium_startup_ping")
				net.Broadcast()
			end
		end )
	end
end

cvars.AddChangeCallback( "sv_addendum_enable", function( name, old, new )
	if new == "1" and old ~= "1" then

		-- Respect containment lockout
		if DESIDERIUM.ContainmentLockoutUntil and CurTime() < DESIDERIUM.ContainmentLockoutUntil then
			local remaining = math.ceil( DESIDERIUM.ContainmentLockoutUntil - CurTime() )
			print( "[addendum] gate refused to open - containment lockout active (" .. remaining .. "s remaining)" )
			RunConsoleCommand( "sv_addendum_enable", "0" )
			return
		end

		print( "Server enabled!" )

		if DESIDERIUM.BroadcastGateOpened then
			DESIDERIUM.BroadcastGateOpened()
		end

		-- Always show the startup cascade when the gate opens
		BroadcastStartupLines()

	elseif new == "0" and old ~= "0" then
		print( "[addendum] subsystem dormant" )

		if DESIDERIUM.CleanupActiveAnomaly then
			DESIDERIUM.CleanupActiveAnomaly()
		end
	end
end, "desiderium_addendum_watch" )

print( "[DESIDERIUM] Core loaded. (" .. DESIDERIUM.Version .. ")" )
