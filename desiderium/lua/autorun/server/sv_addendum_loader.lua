--[[
	DESIDERIUM - Anomaly Loader
	---------------------------
	Walks the lua/desiderium/anomalies/ folder and includes every .lua
	file found there. This is the piece that makes "drop a new file in
	and it just works" actually true - without this, every new anomaly
	file would need a manual include() added somewhere by hand.

	IMPORTANT: the "LUA" file.Find/include() search path only ever looks
	inside lua/ folders (addon lua/, gamemode lua/, base game lua/). It
	cannot see anything outside lua/. That's why this folder lives at
	lua/desiderium/anomalies/ and NOT as a sibling of lua/ at the addon
	root - a sibling folder would be invisible to both file.Find and
	include() no matter what path string is passed in.

	This file does not need editing when anomalies are added or removed.
]]

local ANOMALY_FOLDER = "desiderium/anomalies"

local function LoadAnomalies()
	local files, _ = file.Find( ANOMALY_FOLDER .. "/*.lua", "LUA" )

	if not files or #files == 0 then
		print( "[DESIDERIUM] No anomaly files found in " .. ANOMALY_FOLDER .. "/" )
		return
	end

	for _, filename in ipairs( files ) do
		local fullPath = ANOMALY_FOLDER .. "/" .. filename
		local ok, err = pcall( include, fullPath )

		if ok then
			print( "[DESIDERIUM] Loaded anomaly file: " .. filename )
		else
			print( "[DESIDERIUM] ERROR loading " .. filename .. ": " .. tostring( err ) )
		end
	end
end

LoadAnomalies()
