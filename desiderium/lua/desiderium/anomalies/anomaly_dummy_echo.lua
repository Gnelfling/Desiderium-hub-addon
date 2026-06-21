--[[
	DESIDERIUM Anomaly: dummy_echo
	------------------------------
	This anomaly does nothing scary. It exists purely to prove the full
	pipeline works: loader finds this file -> this file registers itself
	-> dispatcher picks it -> Trigger runs -> Cleanup runs on disable.

	Once real anomalies exist, this file can be deleted or left in as a
	low-weight "nothing happens" filler event (some real horror addons
	do this deliberately, so a trigger doesn't always mean something
	happened - which is its own kind of dread).
]]

local triggerCount = 0

DESIDERIUM.RegisterAnomaly( "dummy_echo", {

	Cooldown = 5,  -- seconds before this can fire again
	Weight   = 1,

	CanTrigger = function()
		return true  -- always eligible, no real conditions yet
	end,

	Trigger = function()
		triggerCount = triggerCount + 1
		print( "[anomaly:dummy_echo] fired (count: " .. triggerCount .. ")" )

		timer.Simple( 1, function()
			print( "[anomaly:dummy_echo] ...still here." )
		end )
	end,

	Cleanup = function()
		print( "[anomaly:dummy_echo] cleanup called, nothing to tear down." )
	end,

} )
