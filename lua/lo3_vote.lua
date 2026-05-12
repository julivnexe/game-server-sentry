-- lo3_vote.lua
-- Unanimous in-chat lo3 vote. When every present player types "lo3"
-- (or any word starting with "lo3", so "lo3?", "go lo3", etc. all count),
-- the server runs sv_map_reset three times spaced 1s apart.
--
-- This is meant to pair with a SAPP command alias in cg/sapp/commands.txt:
--   lo3 'sv_map_reset;w8 30;sv_map_reset;w8 30;sv_map_reset' 3
-- (admins can still run `lo3` directly via rcon/chat to bypass voting.)
--
-- Setup:
--   * Place at  cg/sapp/lua/lo3_vote.lua
--   * Append to cg/sapp/init.txt:   lua_load lo3_vote
--
-- API: SAPP 10.2.1 CE

api_version = "1.12.0.0"

local voted = {}

function OnScriptLoad()
    register_callback(cb["EVENT_JOIN"], "OnJoin")
    register_callback(cb["EVENT_LEAVE"], "OnLeave")
    register_callback(cb["EVENT_CHAT"], "OnChat")
    register_callback(cb["EVENT_GAME_START"], "OnGameStart")
end

function OnScriptUnload() end

function OnGameStart()
    voted = {}
end

function OnJoin(playerIndex)
    voted[playerIndex] = nil
end

function OnLeave(playerIndex)
    voted[playerIndex] = nil
    CheckThreshold()
end

function OnChat(playerIndex, message, channel)
    if not message then return end
    local msg = string.lower(message)
    local matched = false
    for word in msg:gmatch("%S+") do
        if word:find("^lo3") then matched = true; break end
    end
    if not matched then return end
    if voted[playerIndex] then return end
    voted[playerIndex] = true
    local got = CountVoted()
    local total = CountPresent()
    local name = get_var(playerIndex, "$name") or "?"
    say_all(string.format("[lo3 vote] %s voted (%d/%d)", name, got, total))
    CheckThreshold()
end

function CountPresent()
    local n = 0
    for i = 1, 16 do
        if player_present(i) then n = n + 1 end
    end
    return n
end

function CountVoted()
    local n = 0
    for i, v in pairs(voted) do
        if v and player_present(i) then n = n + 1 end
    end
    return n
end

function CheckThreshold()
    local present = CountPresent()
    if present < 1 then return end
    local got = CountVoted()
    if got >= present then
        say_all("[lo3 vote] Unanimous! Resetting map (lo3).")
        execute_command("sv_map_reset")
        timer(1000, "Lo3Reset2")
        timer(2000, "Lo3Reset3")
        voted = {}
    end
end

function Lo3Reset2()
    execute_command("sv_map_reset")
    return false
end

function Lo3Reset3()
    execute_command("sv_map_reset")
    return false
end
