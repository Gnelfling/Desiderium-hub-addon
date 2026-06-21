--[==[
	DESIDERIUM - Client startup chat + sound receiver
	File: desiderium/lua/autorun/client/cl_addendum_startup.lua

	Receives server startup lines and prints them to client chat with a sound.
	Only plays for players who are connected; server already broadcasts lines
	via the 'desiderium_startup_line' net message when sv_addendum_enable is set.
]==]

if not CLIENT then return end

net.Receive("desiderium_startup_line", function()
    local line = net.ReadString()
    if not line then return end

    -- Play a short UI/audio cue for every line
    surface.PlaySound("buttons/button15.wav")

    -- Print colored label + body in chat
    chat.AddText(Color(100,220,100), "[DESIDERIUM] ", Color(180,255,180), line)
end)
