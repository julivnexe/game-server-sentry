-- discord_notify.lua
-- SAPP script: writes player join/leave rows to a local CSV log so the
-- Python monitor can pick them up and post to Discord.
--
-- Background: in many SAPP-under-Wine builds, the built-in http_client()
-- function is stubbed and silently does nothing. So we don't try to post
-- to Discord directly from Lua; instead, we append to /opt/halo-monitor/
-- players.log and let the Python monitor tail that file.
--
-- Setup:
--   * Place this file at  cg/sapp/lua/discord_notify.lua
--   * Append to cg/sapp/init.txt:   lua_load discord_notify
--   * Edit SERVER_NAME below to identify this instance in the log/Discord.
--   * If running multiple Halo servers on one box, give each its own
--     SERVER_NAME and load this script in each instance's lua dir.
--
-- API: SAPP 10.2.1 CE

api_version = "1.12.0.0"

-- ====== CONFIG (edit per server copy) ======
local SERVER_NAME = "Server 1"
local PLAYER_LOG  = "/opt/halo-monitor/players.log"
-- ============================================

local function write_player_log(action, name, ip, hash)
    local f = io.open(PLAYER_LOG, "a")
    if not f then return end
    local ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
    name = (name or ""):gsub(",", " ")
    -- 6 fields: ts,server,action,name,ip,hash
    f:write(string.format("%s,%s,%s,%s,%s,%s\n", ts, SERVER_NAME, action, name, ip or "", hash or ""))
    f:close()
end

function OnScriptLoad()
    register_callback(cb['EVENT_JOIN'], "OnJoin")
    register_callback(cb['EVENT_LEAVE'], "OnLeave")
    -- Tell the Python monitor to drop any stale "active" entries for this
    -- server. Necessary because SAPP's EVENT_LEAVE doesn't always fire when
    -- the server crashes or a client times out, leaving ghosts in the log.
    write_player_log("startup", "", "", "")
end

function OnScriptUnload() end

function OnJoin(PlayerIndex)
    local name = get_var(PlayerIndex, "$name")
    local ip   = get_var(PlayerIndex, "$ip")
    local hash = get_var(PlayerIndex, "$hash")
    write_player_log("join", name, ip, hash)
end

function OnLeave(PlayerIndex)
    local name = get_var(PlayerIndex, "$name")
    local ip   = get_var(PlayerIndex, "$ip")
    local hash = get_var(PlayerIndex, "$hash")
    write_player_log("leave", name, ip, hash)
end
