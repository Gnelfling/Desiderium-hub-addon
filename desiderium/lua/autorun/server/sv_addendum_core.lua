--[[
	DESIDERIUM - Core Module
	------------------------
	This is the "engine" file. It does three things:

	1. Creates the sv_addendum_enable ConVar (the gate toggle).
	2. Sets up DESIDERIUM.Anomalies, an empty registry table that future
	   anomaly files will register themselves into. This file does NOT
	   know what anomalies exist - it just reads whatever is in the table
	   when it needs to.
	3. Watches sv_addendum_enable for changes. Enabling it does NOT fire
	   an anomaly directly anymore - it just opens the gate, which lets
	   Exposure start rising (see sv_addendum_exposure.lua, which owns
	   the actual rise/decay/dispatch-timing logic). This file just
	   handles the moment of opening/closing itself: a sound cue, a
	   containment-lockout check, and cleanup on close.

	Nothing in this file should need to change when new anomalies are
	added later. New anomalies are separate files that hook into
	DESIDERIUM.Anomalies on their own.
]]

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM.Anomalies = DESIDERIUM.Anomalies or {}
DESIDERIUM.Version = "0.0.1-core"

-- ============================================================
-- The hidden trigger convar.
-- No flags, no admin gate - any client or the server console can
-- flip this for now. FCVAR_NOTIFY makes the change broadcast to
-- everyone's console, same as real cheat-style convars do.
-- ============================================================
CreateConVar(
	"sv_addendum_enable",
	"0",
	FCVAR_NOTIFY,
	"Internal addendum subsystem toggle.",
	0,
	1
)

-- ============================================================
-- Registration function for future anomaly files.
-- Each anomaly file will call:
--   DESIDERIUM.RegisterAnomaly( "name", { ... } )
-- This file just needs to exist and work - it doesn't need to
-- know about specific anomalies yet.
-- ============================================================
function DESIDERIUM.RegisterAnomaly( name, data )
	if DESIDERIUM.Anomalies[ name ] then
		print( "[DESIDERIUM] WARNING: anomaly '" .. name .. "' is already registered, overwriting." )
	end

	DESIDERIUM.Anomalies[ name ] = data
	print( "[DESIDERIUM] Registered anomaly module: " .. name )
end

-- ============================================================
-- The fake server-log cascade. This is the test payload.
-- Styled like a dedicated server boot log, not a map compile log.
-- This whole block gets replaced later by real anomaly dispatch logic.
-- ============================================================
local function PrintAddendumCascade()
	local lines = {
		"------------------------------------------------",
		"[addendum] subsystem awake",
		"[addendum] reading local manifest... ok",
		"[addendum] entity index: 0 known, 0 unindexed",
		"[addendum] resolving navmesh references... done",
		"[addendum] resolving navmesh references... done",
		"[addendum] resolving navmesh references... failed (1)",
		"[addendum] retrying failed reference... done",
		"[addendum] sound cache primed",
		"[addendum] light registry primed",
		"[addendum] presence flag cleared",
		"[addendum] presence flag cleared",
		"[addendum] presence flag set",
		"------------------------------------------------",
	}

	for i = 1, #lines do
		local line = lines[ i ]
		timer.Simple( i * 0.15, function()
			print( line )
		end )
	end
end

-- ============================================================
-- Watch the convar. Enabling no longer dispatches anything directly -
-- that's now owned by the exposure tick loop (sv_addendum_exposure.lua),
-- which rises while this is on and decides when/whether to actually
-- fire an anomaly. This callback just handles the "gate just opened/
-- closed" moment itself: the boot-cascade proof-of-life print (only
-- when the registry is still empty), the lockout check, and cleanup
-- on close.
-- ============================================================
cvars.AddChangeCallback( "sv_addendum_enable", function( name, old, new )
	if new == "1" and old ~= "1" then

		-- Respect containment lockout: refuse to actually open if we're
		-- still inside the post-containment cooldown window.
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

		local registryEmpty = not DESIDERIUM.Anomalies or table.IsEmpty( DESIDERIUM.Anomalies )
		if registryEmpty then
			PrintAddendumCascade()
		end
	elseif new == "0" and old ~= "0" then
		print( "[addendum] subsystem dormant" )

		if DESIDERIUM.CleanupActiveAnomaly then
			DESIDERIUM.CleanupActiveAnomaly()
		end
	end
end, "desiderium_addendum_watch" )

print( "[DESIDERIUM] Core loaded. (" .. DESIDERIUM.Version .. ")" )
