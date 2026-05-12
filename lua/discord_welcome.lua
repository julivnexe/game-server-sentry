-- discord_welcome.lua
-- Sends a private chat message to a player ~2 seconds after they join,
-- typically used to advertise your Discord server invite.
--
-- Setup:
--   * Place at  cg/sapp/lua/discord_welcome.lua
--   * Append to cg/sapp/init.txt:   lua_load discord_welcome
--   * Edit WELCOME_MESSAGE below.
--
-- API: SAPP 10.2.1 CE

api_version = "1.12.0.0"

-- ====== CONFIG ======
local WELCOME_MESSAGE = "JOIN OUR DISCORD: https://discord.gg/YOUR_INVITE_HERE"
local DELAY_MS = 2000   -- wait this long after join before sending
-- ====================

function OnScriptLoad()
    register_callback(cb["EVENT_JOIN"], "OnJoin")
end

function OnScriptUnload() end

function OnJoin(playerIndex)
    timer(DELAY_MS, "ShowWelcome", playerIndex)
end

function ShowWelcome(playerIndex)
    if player_present(playerIndex) then
        say(playerIndex, WELCOME_MESSAGE)
    end
    return false
end
