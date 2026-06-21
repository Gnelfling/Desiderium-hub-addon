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
]]--

DESIDERIUM = DESIDERIUM or {}
DESIDERIUM.Anomalies = DESIDERIUM.Anomalies or {}
DESIDERIUM.LastTriggered = DESIDERIUM.LastTriggered or {}
-- ActiveInstances: map of instanceId -> { name=anomalyName, cleanup=function }
DESIDERIUM.ActiveInstances = DESIDERIUM.ActiveInstances or {}

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

-- Helper: register an active instance returned by an anomaly Trigger.
-- cleanupFunc is optional; if provided we wrap it so that when called
-- the instance is unregistered automatically and exposure is updated.
local function RegisterActiveInstance( name, cleanupFunc )
	local id = tostring(CurTime()) .. "-" .. tostring( math.random(1, 1000000) )
	local entry = { name = name }

	if type( cleanupFunc ) == "function" then
		-- wrap so unregister occurs after the anomaly's own cleanup
		entry.cleanup = function(...)
			local ok, err = pcall( cleanupFunc, ... )
			-- remove entry
			DESIDERIUM.ActiveInstances[ id ] = nil
			-- notify exposure subsystem
			if DESIDERIUM.UpdateExposure then pcall( DESIDERIUM.UpdateExposure ) end
			if not ok then print( "[DESIDERIUM] anomaly cleanup error:", err ) end
		end
	else
		entry.cleanup = nil
		-- unregister later when asked
		-- we still create an entry so it counts as active
	end

	DESIDERIUM.ActiveInstances[ id ] = entry
	-- notify exposure subsystem
	if DESIDERIUM.UpdateExposure then pcall( DESIDERIUM.UpdateExposure ) end
	return id, entry
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

	-- Call Trigger and capture optional cleanup closure the anomaly may return.
	local ok, r1, r2 = pcall( data.Trigger )
	if not ok then
		print( "[DESIDERIUM] ERROR running anomaly '" .. name .. "': " .. tostring( r1 ) )
		return false
	end

	-- Determine cleanup function from return values
	local cleanupFunc = nil
	if type( r2 ) == "function" then
		cleanupFunc = r2
	elseif type( r1 ) == "function" then
		-- some anomalies return only a cleanup function
		cleanupFunc = r1
	end

	-- Register this spawned instance so containment can be based on active count
	local id, entry = RegisterActiveInstance( name, cleanupFunc )
	-- expose the id on the entry so external systems can refer to it
	entry.id = id

	-- Return the instance id to callers as useful info (pcall already swallowed returns)
	return true, id
end

-- ============================================================
-- Optional manual cleanup call. If instanceId is provided it will
-- call that instance's cleanup. Otherwise, cleans up ALL active instances.
-- This will call the per-instance cleanup closures (if provided) or
-- simply remove the tracked entry if no cleanup was supplied.
-- ============================================================
function DESIDERIUM.CleanupActiveAnomaly( instanceId )
	if instanceId and DESIDERIUM.ActiveInstances[ instanceId ] then
		local entry = DESIDERIUM.ActiveInstances[ instanceId ]
		if entry.cleanup then
			local ok, err = pcall( entry.cleanup )
			if not ok then print( "[DESIDERIUM] ERROR cleaning up anomaly instance:", err ) end
		else
			DESIDERIUM.ActiveInstances[ instanceId ] = nil
		end
		return
	end

	-- No instance specified: attempt to clean up everything.
	for id, entry in pairs( table.Copy( DESIDERIUM.ActiveInstances ) ) do
		if entry.cleanup then
			local ok, err = pcall( entry.cleanup )
			if not ok then print( "[DESIDERIUM] ERROR cleaning up anomaly instance:", err ) end
		else
			DESIDERIUM.ActiveInstances[ id ] = nil
		end
	end

	-- ensure exposure is updated after clearing
	if DESIDERIUM.UpdateExposure then pcall( DESIDERIUM.UpdateExposure ) end
end

print( "[DESIDERIUM] Dispatcher loaded." )
