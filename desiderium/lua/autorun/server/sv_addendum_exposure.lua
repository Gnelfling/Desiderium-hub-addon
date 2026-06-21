--[[
DESIDERIUM - Exposure & Containment
----------------------------------
Event-driven but still driven by tick for dispatch decisions. Added a
soft cap on simultaneous anomalies so the system will avoid flooding
multiple anomalies at once.
]]--

DESIDERIUM = DESIDERIUM or {}

DESIDERIUM.Exposure = DESIDERIUM.Exposure or 0
DESIDERIUM.ContainmentLockoutUntil = DESIDERIUM.ContainmentLockoutUntil or 0

-- ============================================================
-- Tunables. All in one place so the curve can be adjusted without
-- hunting through logic.
-- ============================================================
local RISE_RATE          = 1.2   -- Exposure gained per second while enabled (slightly reduced)
local DECAY_RATE         = 0.4   -- Exposure lost per second while disabled
local CONTAINMENT_THRESHOLD = 100  -- Exposure value that triggers forced shutdown
local CONTAINMENT_LOCKOUT   = 30   -- seconds the gate refuses to reopen after containment
local MIN_CHECK_INTERVAL = 5    -- seconds between dispatch checks at LOW exposure (increased to reduce simultaneous spawns)
local MAX_CHECK_INTERVAL = 1.5  -- seconds between dispatch checks at HIGH exposure
local MAX_FIRE_CHANCE    = 0.82 -- chance to actually dispatch on a check, at max exposure (reduced)
local MIN_FIRE_CHANCE    = 0.08 -- chance to actually dispatch on a check, at low exposure (reduced)
local MAX_SIMULTANEOUS_ANOMALIES = 2 -- soft cap to reduce chance of multiple anomalies spawning at once

-- ============================================================
-- Maps current Exposure (0 -> CONTAINMENT_THRESHOLD) into a 0-1
-- progress value used by both the interval and chance curves.
-- ============================================================
local function GetExposureProgress()
	return math.Clamp( DESIDERIUM.Exposure / CONTAINMENT_THRESHOLD, 0, 1 )
end

local function GetCheckInterval()
	local t = GetExposureProgress()
	return Lerp( t, MIN_CHECK_INTERVAL, MAX_CHECK_INTERVAL )
end

local function GetFireChance()
	local t = GetExposureProgress()
	return Lerp( t, MIN_FIRE_CHANCE, MAX_FIRE_CHANCE )
end

-- ============================================================
-- Containment: the forced-shutdown safety valve.
-- ============================================================
function DESIDERIUM.TriggerContainment( reason )
	reason = reason or "exposure threshold exceeded"

	print( "[addendum] CONTAINMENT TRIGGERED: " .. reason )

	if DESIDERIUM.CleanupActiveAnomaly then
		DESIDERIUM.CleanupActiveAnomaly()
	end

	DESIDERIUM.Exposure = DESIDERIUM.Exposure * 0.25
	DESIDERIUM.ContainmentLockoutUntil = CurTime() + CONTAINMENT_LOCKOUT

	RunConsoleCommand( "sv_addendum_enable", "0" )

	DESIDERIUM.BroadcastGateMessage( "CONTAINMENT: network gate forced closed.", true )
end

-- Manual close command
concommand.Add( "sv_addendum_close", function( ply, cmd, args )
	if DESIDERIUM.CleanupActiveAnomaly then
		DESIDERIUM.CleanupActiveAnomaly()
	end

	if GetConVar( "sv_addendum_enable" ):GetBool() then
		RunConsoleCommand( "sv_addendum_enable", "0" )
	end

	print( "[addendum] gate manually closed." )
	DESIDERIUM.BroadcastGateMessage( "Network gate manually closed.", false )
end, nil, "Manually closes the addendum network gate and cleans up any active anomaly." )

-- Tick loop used for dispatch timing. Contains a soft-cap check so we
-- don't start more than MAX_SIMULTANEOUS_ANOMALIES at once.
local nextCheckAt = 0

timer.Create( "desiderium_exposure_tick", 1, 0, function()
	local enabled = GetConVar( "sv_addendum_enable" ):GetBool()

	if enabled then
		DESIDERIUM.Exposure = DESIDERIUM.Exposure + RISE_RATE
	else
		DESIDERIUM.Exposure = math.max( 0, DESIDERIUM.Exposure - DECAY_RATE )
	end

	if DESIDERIUM.Exposure >= CONTAINMENT_THRESHOLD then
		DESIDERIUM.TriggerContainment( "exposure reached " .. math.Round( DESIDERIUM.Exposure ) )
		return
	end

	if enabled and CurTime() >= nextCheckAt then
		nextCheckAt = CurTime() + GetCheckInterval()

		-- soft cap: count active instances
		local activeCount = 0
		if DESIDERIUM.ActiveInstances then activeCount = table.Count( DESIDERIUM.ActiveInstances ) end
		if activeCount >= MAX_SIMULTANEOUS_ANOMALIES then
			-- skip spawn this cycle
			return
		end

		if math.random() <= GetFireChance() then
			if DESIDERIUM.DispatchAnomaly then
				DESIDERIUM.DispatchAnomaly()
			end
		end
	end
end )

print( "[DESIDERIUM] Exposure/containment system loaded." )
