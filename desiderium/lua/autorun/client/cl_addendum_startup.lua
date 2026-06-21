--[==[
	DESIDERIUM - Client startup chat + sound receiver
	File: desiderium/lua/autorun/client/cl_addendum_startup.lua

	Receives server startup lines and prints them to client chat with a sound.
]==]

if not CLIENT then return end

net.Receive("desiderium_startup_line", function()
    local line = net.ReadString()
    if not line then return end

    -- Play a short UI/audio cue for every line
    surface.PlaySound("buttons/button15.wav")

    -- Print the entire message in a clear green color
    chat.AddText(Color(50,205,50), "[DESIDERIUM] " .. line)
end)
