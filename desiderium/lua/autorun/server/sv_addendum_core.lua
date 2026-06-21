--[[
	DESIDERIUM - Core Module (server-side startup cascade)
	This file handles the gate convar and prints a startup cascade on gate open.

	Fix: The startup cascade should run every time the gate is opened so
	admins always see the boot-style green text. Previously it only ran
	when the anomaly registry was empty which prevented the lines from
	appearing in normal runs where anomalies are already registered.
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

function DESIDERIUM.RegisterAnomaly( name, data )
	if DESIDERIUM.Anomalies[ name ] then
		print( "[DESIDERIUM] WARNING: anomaly '" .. name .. "' is already registered, overwriting." )
	end

	DESIDERIUM.Anomalies[ name ] = data
	print( "[DESIDERIUM] Registered anomaly module: " .. name )
end

-- Server-side boot cascade: print colored lines directly to server console
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
			MsgC( Color(100,220,100), "[DESIDERIUM] ", Color(180,255,180), line .. "\n" )
			print( line )
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
