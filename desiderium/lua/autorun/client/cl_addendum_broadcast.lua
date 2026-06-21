--[[
	DESIDERIUM - Broadcast (client side)
	-------------------------------------
	Receives "desiderium_gate_message" from the server and actually
	shows the colored chat text + plays the alert sound. chat.AddText
	only works clientside, which is why this exists as a separate file
	from the server broadcast function.

	NOTE on the sound path: using a stock HL2/Source UI alert sound here
	(buttons/button10.wav). This ships with every Source game GMod can
	run on, so it should always be present, but if it doesn't fit the
	mood feel free to swap the path for something else - this is the
	one piece of this file I'd consider a placeholder rather than final.
]]

net.Receive( "desiderium_gate_message", function()
	local text = net.ReadString()
	local isContainment = net.ReadBool()

	if isContainment then
		chat.AddText( Color( 255, 40, 40 ), "[ADDENDUM] ", Color( 255, 80, 80 ), text )
		surface.PlaySound( "buttons/button10.wav" )
	else
		chat.AddText( Color( 255, 120, 120 ), "[ADDENDUM] ", Color( 255, 160, 160 ), text )
		surface.PlaySound( "buttons/button10.wav" )
	end
end )

-- ============================================================
-- Gate-opened cue. Deliberately a different, quieter/lower-key
-- sound than the close/containment one - opening should feel
-- like "something just connected," not an alarm.
-- ============================================================
net.Receive( "desiderium_gate_opened", function()
	surface.PlaySound( "buttons/blip1.wav" )
end )
