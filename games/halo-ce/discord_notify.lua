-- discord_notify.lua
-- SAPP script: writes player events to a local CSV log so the Python
-- monitor can pick them up and post to Discord.
--
-- Logs: join, leave, command, startup (clears stale state), state
--       (periodic sv_maxplayers heartbeat so the bot's "x/y" reflects
--       live server config, not the static env var).
--
-- Background: in many SAPP-under-Wine builds, the built-in http_client()
-- function is stubbed and silently does nothing. So we don't try to post
-- to Discord directly from Lua; instead, we append to /opt/halo-monitor/
-- players.log and let the Python monitor tail that file.
--
-- CSV format (7 fields, comma-separated):
--   timestamp, server_name, action, player_name, ip:port, cdkey_hash, extra
-- For action="join"/"leave"/"startup", extra is empty.
-- For action="command",                 extra is "lvl=<n>|cmd=<text>".
-- For action="state",                   extra is "maxplayers=<n>".
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
local SERVER_NAME       = "Server 1"
local PLAYER_LOG        = "/opt/halo-monitor/players.log"
local STATE_INTERVAL_MS = 60000
local SCHEMA_VERSION    = "v1"  -- docs/CSV_FORMAT.md
-- ============================================

local function csv_safe(s)
    s = tostring(s or "")
    s = s:gsub(",", " "):gsub("\n", " "):gsub("\r", "")
    return s
end

local function write_log(action, name, ip, hash, extra)
    local f = io.open(PLAYER_LOG, "a")
    if not f then return end
    local ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
    -- 8 fields: ts,server,action,name,ip,hash,extra,schema_version
    f:write(string.format("%s,%s,%s,%s,%s,%s,%s,%s\n",
        ts, SERVER_NAME, action,
        csv_safe(name), ip or "", hash or "", csv_safe(extra),
        SCHEMA_VERSION))
    f:close()
end

local function read_maxplayers_from_init()
    -- SAPP's get_var(0, "$maxplayers") returns the literal string in some
    -- versions, so we read cg/init.txt directly. Halo's working directory
    -- is the server install root (e.g. /root/HaloCE-3), so the relative
    -- "cg/init.txt" path works regardless of which instance we're in.
    local f = io.open("cg/init.txt", "r")
    if not f then return nil end
    local result = nil
    for line in f:lines() do
        local m = line:match("^%s*sv_maxplayers%s+(%d+)")
        if m then result = m; break end
    end
    f:close()
    return result
end

function WriteServerState()
    local maxp = read_maxplayers_from_init() or "?"
    write_log("state", "", "", "", "maxplayers=" .. maxp)
    return true  -- keep the timer alive
end

function OnScriptLoad()
    register_callback(cb['EVENT_JOIN'],    "OnJoin")
    register_callback(cb['EVENT_LEAVE'],   "OnLeave")
    register_callback(cb['EVENT_COMMAND'], "OnCommand")
    write_log("startup", "", "", "", "")
    WriteServerState()
    timer(STATE_INTERVAL_MS, "WriteServerState")
end

function OnScriptUnload() end

function OnJoin(PlayerIndex)
    local name = get_var(PlayerIndex, "$name")
    local ip   = get_var(PlayerIndex, "$ip")
    local hash = get_var(PlayerIndex, "$hash")
    write_log("join", name, ip, hash, "")
end

function OnLeave(PlayerIndex)
    local name = get_var(PlayerIndex, "$name")
    local ip   = get_var(PlayerIndex, "$ip")
    local hash = get_var(PlayerIndex, "$hash")
    write_log("leave", name, ip, hash, "")
end

function OnCommand(PlayerIndex, Command, Environment, Password)
    -- PlayerIndex 0 = console/rcon; only snitch on real in-game players.
    if PlayerIndex == 0 then return end
    local name = get_var(PlayerIndex, "$name") or ""
    local ip   = get_var(PlayerIndex, "$ip")   or ""
    local hash = get_var(PlayerIndex, "$hash") or ""
    local lvl  = get_var(PlayerIndex, "$lvl")  or "0"
    local extra = string.format("lvl=%s|cmd=%s", lvl, Command or "")
    write_log("command", name, ip, hash, extra)
    -- Detect runtime sv_maxplayers changes (any source) and emit a fresh
    -- state line so the bot's Discord embed doesn't lag. Catches both the
    -- raw `sv_maxplayers <n>` and the common `max <n>` alias defined in
    -- many commands.txt files.
    local lc = (Command or ""):lower()
    local newmax = lc:match("^sv_maxplayers%s+(%d+)")
                or lc:match("^max%s+(%d+)")
    if newmax then
        write_log("state", "", "", "", "maxplayers=" .. newmax)
    end
end
