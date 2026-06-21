--[[
	DESIDERIUM - Dispatcher
	-----------------------
	This is the piece that actually reads DESIDERIUM.Anomalies and does
	something with it. Anything that wants to "fire an anomaly" should
	call DESIDERIUM.DispatchAnomaly() rather than picking one by hand.

	Anomaly table contract (what each registered anomaly must provide):
		{
			Name        = "string, must match the registration key",
			Cooldown    = number (seconds, optional, default 0),
			Weight      = number (optional, default 1 - higher = more likely),
			CanTrigger  = function() return true/false end,  (optional)
			Trigger     = function() ... end,                (required)
			Cleanup     = function() ... end,                (optional)
		}

	Only Trigger is strictly required. Everything else has a sane default
	so a minimal anomaly file can be very short.
]]

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM.Anomalies = DESIDERIUM.Anomalies or {}
DESIDERIUM.LastTriggered = DESIDERIUM.LastTriggered or {}
DESIDERIUM.ActiveAnomaly = nil

-- ============================================================
-- Picks one eligible, weighted-random anomaly from the registry.
-- Returns nil if nothing is eligible (empty registry, all on cooldown,
-- all CanTrigger() returning false).
-- ============================================================
local function PickAnomaly()
	local pool = {}
	local totalWeight = 0

	for name, data in pairs( DESIDERIUM.Anomalies ) do
		local cooldown = data.Cooldown or 0
		local lastFired = DESIDERIUM.LastTriggered[ name ] or -math.huge
		local offCooldown = ( CurTime() - lastFired ) >= cooldown

		local eligible = offCooldown
		if eligible and data.CanTrigger then
			eligible = data.CanTrigger() == true
		end

		if eligible then
			local weight = data.Weight or 1
			totalWeight = totalWeight + weight
			table.insert( pool, { name = name, data = data, weight = weight } )
		end
	end

	if #pool == 0 then return nil end

	local roll = math.random() * totalWeight
	local running = 0

	for _, entry in ipairs( pool ) do
		running = running + entry.weight
		if roll <= running then
			return entry.name, entry.data
		end
	end

	-- Fallback (floating point edge case): just return the last one checked.
	return pool[ #pool ].name, pool[ #pool ].data
end

-- ============================================================
-- Public dispatch function. Call this to fire one anomaly.
-- Returns true if something fired, false if nothing was eligible.
-- ============================================================
function DESIDERIUM.DispatchAnomaly()
	local name, data = PickAnomaly()

	if not name then
		print( "[DESIDERIUM] Dispatch requested but no anomaly is eligible to fire." )
		return false
	end

	print( "[DESIDERIUM] Dispatching anomaly: " .. name )
	DESIDERIUM.LastTriggered[ name ] = CurTime()
	DESIDERIUM.ActiveAnomaly = name

	local ok, err = pcall( data.Trigger )
	if not ok then
		print( "[DESIDERIUM] ERROR running anomaly '" .. name .. "': " .. tostring( err ) )
	end

	return true
end

-- ============================================================
-- Optional manual cleanup call. Anomalies that set up something
-- persistent (an entity, a hook) should provide Cleanup so it can
-- be torn down without waiting for a map change.
-- ============================================================
function DESIDERIUM.CleanupActiveAnomaly()
	local name = DESIDERIUM.ActiveAnomaly
	if not name then return end

	local data = DESIDERIUM.Anomalies[ name ]
	if data and data.Cleanup then
		local ok, err = pcall( data.Cleanup )
		if not ok then
			print( "[DESIDERIUM] ERROR cleaning up anomaly '" .. name .. "': " .. tostring( err ) )
		end
	end

	DESIDERIUM.ActiveAnomaly = nil
end

print( "[DESIDERIUM] Dispatcher loaded." )
