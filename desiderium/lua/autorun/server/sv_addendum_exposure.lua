--[[
	DESIDERIUM - Exposure & Containment
	------------------------------------
	This is the "wound" model. sv_addendum_enable being 1 doesn't fire
	anomalies directly anymore - it just means Exposure is currently
	RISING. Exposure is a single number from 0 upward that represents
	how compromised the breach is:

		- While enabled (sv_addendum_enable 1): Exposure climbs over time.
		- While disabled (sv_addendum_enable 0): Exposure decays slowly,
		  it does NOT reset to 0 instantly. Re-opening before it's fully
		  decayed starts from wherever it left off, not from zero.
		- The chance-to-trigger and check frequency both scale with
		  current Exposure (low/rare early, higher/frequent later).
		- If Exposure crosses CONTAINMENT_THRESHOLD, the system force-
		  closes itself: all active anomalies are cleaned up, the convar
		  is forced back to 0, Exposure is slashed hard, and a lockout
		  timer prevents immediately re-opening it.

	This file owns Exposure and the containment gate. The dispatcher
	(sv_addendum_dispatch.lua) still owns picking *which* anomaly fires -
	this file just decides *whether and how often* to ask it to.
]]

DESIDERIUM = DESIDERIUM or {}

DESIDERIUM.Exposure = 0
DESIDERIUM.ContainmentLockoutUntil = 0

-- ============================================================
-- Tunables. All in one place so the curve can be adjusted without
-- hunting through logic.
-- ============================================================
local RISE_RATE          = 1.0   -- Exposure gained per second while enabled
local DECAY_RATE         = 0.4   -- Exposure lost per second while disabled
local CONTAINMENT_THRESHOLD = 100  -- Exposure value that triggers forced shutdown
local CONTAINMENT_LOCKOUT   = 30   -- seconds the gate refuses to reopen after containment
local MIN_CHECK_INTERVAL = 8    -- seconds between dispatch checks at LOW exposure
local MAX_CHECK_INTERVAL = 1.5  -- seconds between dispatch checks at HIGH exposure
local MAX_FIRE_CHANCE    = 0.65 -- chance to actually dispatch on a check, at max exposure
local MIN_FIRE_CHANCE    = 0.05 -- chance to actually dispatch on a check, at low exposure

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
--
-- Note: setting the convar here will ALSO fire the change callback
-- in sv_addendum_core.lua (old="1" -> new="0"), which calls
-- CleanupActiveAnomaly() on its own. To avoid cleaning up twice,
-- this function clears DESIDERIUM.ActiveAnomaly itself BEFORE
-- changing the convar, so by the time that callback runs there's
-- nothing left for it to clean.
-- ============================================================
function DESIDERIUM.TriggerContainment( reason )
	reason = reason or "exposure threshold exceeded"

	print( "[addendum] CONTAINMENT TRIGGERED: " .. reason )

	if DESIDERIUM.CleanupActiveAnomaly then
		DESIDERIUM.CleanupActiveAnomaly()  -- clears DESIDERIUM.ActiveAnomaly as a side effect
	end

	DESIDERIUM.Exposure = DESIDERIUM.Exposure * 0.25  -- hard cut, not full reset
	DESIDERIUM.ContainmentLockoutUntil = CurTime() + CONTAINMENT_LOCKOUT

	-- This also fires the convar change callback, which will see
	-- ActiveAnomaly already nil and skip its own cleanup attempt.
	RunConsoleCommand( "sv_addendum_enable", "0" )

	DESIDERIUM.BroadcastGateMessage( "CONTAINMENT: network gate forced closed.", true )
end

-- ============================================================
-- Manual close command - sv_addendum_close. Distinct from setting
-- the convar to 0: this is an explicit player/admin action with its
-- own message, separate from "stopped feeding it."
-- ============================================================
concommand.Add( "sv_addendum_close", function( ply, cmd, args )
	-- Clean up first so that if the convar callback also fires from
	-- the command below, it finds nothing left to clean up.
	if DESIDERIUM.CleanupActiveAnomaly then
		DESIDERIUM.CleanupActiveAnomaly()
	end

	if GetConVar( "sv_addendum_enable" ):GetBool() then
		RunConsoleCommand( "sv_addendum_enable", "0" )
	end

	print( "[addendum] gate manually closed." )
	DESIDERIUM.BroadcastGateMessage( "Network gate manually closed.", false )
end, nil, "Manually closes the addendum network gate and cleans up any active anomaly." )

-- ============================================================
-- The actual tick loop. One single timer drives all of this -
-- no per-anomaly timers, per the lesson learned earlier about
-- runaway per-entity timer counts.
-- ============================================================
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

		if math.random() <= GetFireChance() then
			if DESIDERIUM.DispatchAnomaly then
				DESIDERIUM.DispatchAnomaly()
			end
		end
	end
end )

print( "[DESIDERIUM] Exposure/containment system loaded." )
