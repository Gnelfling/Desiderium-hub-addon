--[[
	DESIDERIUM - Broadcast (server side)
	-------------------------------------
	Provides DESIDERIUM.BroadcastGateMessage(text, isContainment), used
	whenever the gate closes (manually or via forced containment) to
	show a colored chat message and play an alert sound for everyone
	on the server.

	This file must load before anything that calls
	DESIDERIUM.BroadcastGateMessage - it sorts alphabetically before
	core/dispatch/exposure/loader, so that's already guaranteed.

	The actual chat.AddText call has to happen on the CLIENT - the
	server can't print colored chat directly. So this sends a net
	message; the matching client file (cl_addendum_broadcast.lua)
	receives it and does the actual chat.AddText + sound.Play.
]]

DESIDERIUM = DESIDERIUM or {}

util.AddNetworkString( "desiderium_gate_message" )
util.AddNetworkString( "desiderium_gate_opened" )

-- ============================================================
-- text: the message to show in chat.
-- isContainment: true = forced shutdown (more severe framing),
--                false/nil = manual close.
-- ============================================================
function DESIDERIUM.BroadcastGateMessage( text, isContainment )
	net.Start( "desiderium_gate_message" )
		net.WriteString( text or "" )
		net.WriteBool( isContainment == true )
	net.Broadcast()
end

-- ============================================================
-- Distinct "gate just opened" cue - separate sound/message from
-- the close/containment one, so opening and closing are audibly
-- different events.
-- ============================================================
function DESIDERIUM.BroadcastGateOpened()
	net.Start( "desiderium_gate_opened" )
	net.Broadcast()
end
