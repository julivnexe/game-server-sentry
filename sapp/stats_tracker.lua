-- stats_tracker.lua
-- SAPP script: tracks per-IP K/D/A/captures and exposes /stats, /top,
-- /rank in chat. Writes raw events to a CSV log for SoplonBOT to ingest
-- into SQLite; reads pre-baked TXT files written by SoplonBOT to answer
-- the in-game commands without needing a DB driver in Lua.
--
-- Architecture:
--   Lua (this file) → events.log   → Python (SoplonBOT ingest) → SQLite
--                   ← stats/*.txt  ←
--
-- VPN exclusion: stats for IPs flagged as VPN by ProxyCheck.io are
-- logged but NOT counted in the leaderboard. That filtering happens
-- Python-side; this script logs every event without judging.
--
-- File layout:
--   /opt/halo-monitor/events.log               (this script writes)
--   /opt/halo-monitor/stats/leaderboard.txt    (Python writes)
--   /opt/halo-monitor/stats/player/<ip>.txt    (Python writes)
--
-- Setup:
--   * Place at  cg/sapp/lua/stats_tracker.lua
--   * Append to cg/sapp/init.txt:   lua_load stats_tracker
--   * Set SERVER_NAME below to match this instance.
--
-- API: SAPP 10.2.1 CE

api_version = "1.12.0.0"

-- ====== CONFIG ======
local SERVER_NAME       = "Server 1"
local EVENT_LOG         = "/opt/halo-monitor/events.log"
local LEADERBOARD_PATH  = "/opt/halo-monitor/stats/leaderboard.txt"   -- sorted by KDA desc
local FRAGGERS_PATH     = "/opt/halo-monitor/stats/fraggers.txt"       -- sorted by raw kills desc
local CAPPERS_PATH      = "/opt/halo-monitor/stats/cappers.txt"        -- sorted by captures desc
local PLAYER_STATS_DIR  = "/opt/halo-monitor/stats/player"
local SCHEMA_VERSION    = "v1"
local ASSIST_WINDOW_SEC = 6        -- damagers within this window get assist credit
local TOP_SHOW_N        = 5
-- =====================

local function csv_safe(s)
    s = tostring(s or "")
    s = s:gsub(",", " "):gsub("\n", " "):gsub("\r", "")
    return s
end

local function strip_port(ip_port)
    if not ip_port then return "" end
    return (ip_port:match("^([^:]+)")) or ip_port
end

local function write_event(event_type, actor_ip, actor_name, target_ip, target_name, extra)
    local f = io.open(EVENT_LOG, "a")
    if not f then return end
    local ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
    -- 9 fields: ts,server,event,actor_ip,actor_name,target_ip,target_name,extra,schema
    f:write(string.format("%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
        ts, SERVER_NAME, event_type,
        strip_port(actor_ip),  csv_safe(actor_name),
        strip_port(target_ip), csv_safe(target_name),
        csv_safe(extra or ""),
        SCHEMA_VERSION))
    f:close()
end

----------------------------------------------------------------
-- DAMAGE TRACKING (for assists)
----------------------------------------------------------------
-- recent_damagers[victim_idx] = { [damager_idx] = os.clock() }
local recent_damagers = {}

local function note_damage(victim_idx, causer_idx)
    if victim_idx == causer_idx then return end   -- self-damage doesn't assist
    if not recent_damagers[victim_idx] then
        recent_damagers[victim_idx] = {}
    end
    recent_damagers[victim_idx][causer_idx] = os.clock()
end

local function pop_assisters(victim_idx, killer_idx)
    -- Returns list of damager indices (other than killer) who damaged
    -- the victim within ASSIST_WINDOW_SEC seconds.
    local now = os.clock()
    local out = {}
    local pool = recent_damagers[victim_idx] or {}
    for damager_idx, ts in pairs(pool) do
        if damager_idx ~= killer_idx and (now - ts) <= ASSIST_WINDOW_SEC then
            table.insert(out, damager_idx)
        end
    end
    recent_damagers[victim_idx] = nil   -- reset on death
    return out
end

----------------------------------------------------------------
-- GAMETYPE CHECK
----------------------------------------------------------------
local function is_ctf()
    -- $gt returns the gametype name; CTF caps fire EVENT_SCORE.
    local gt = (get_var(0, "$gt") or ""):lower()
    return gt == "ctf"
end

----------------------------------------------------------------
-- EVENT HANDLERS
----------------------------------------------------------------
function OnScriptLoad()
    register_callback(cb["EVENT_JOIN"],               "OnJoin")
    register_callback(cb["EVENT_LEAVE"],              "OnLeave")
    register_callback(cb["EVENT_DIE"],                "OnDie")
    register_callback(cb["EVENT_DAMAGE_APPLICATION"], "OnDamage")
    register_callback(cb["EVENT_SCORE"],              "OnScore")
    register_callback(cb["EVENT_CHAT"],               "OnChat")
    register_callback(cb["EVENT_GAME_END"],           "OnGameEnd")
end

function OnScriptUnload() end

function OnJoin(PlayerIndex)
    local name = get_var(PlayerIndex, "$name")
    local ip   = get_var(PlayerIndex, "$ip")
    write_event("JOIN", ip, name, "", "", "")
end

function OnLeave(PlayerIndex)
    recent_damagers[PlayerIndex] = nil
    local name = get_var(PlayerIndex, "$name")
    local ip   = get_var(PlayerIndex, "$ip")
    write_event("LEAVE", ip, name, "", "", "")
end

function OnDamage(VictimIndex, CauserIndex, MetaID, Damage, HitString, Backtap)
    -- CauserIndex 0 = world (fall, vehicle, env). Skip.
    if CauserIndex == 0 then return end
    -- Cast to numbers; SAPP passes these as strings in some builds.
    local v = tonumber(VictimIndex) or 0
    local c = tonumber(CauserIndex) or 0
    if v > 0 and c > 0 then note_damage(v, c) end
end

function OnDie(VictimIndex, KillerIndex)
    local v = tonumber(VictimIndex) or 0
    local k = tonumber(KillerIndex) or 0
    if v == 0 then return end

    local v_name = get_var(v, "$name")
    local v_ip   = get_var(v, "$ip")

    if k == 0 or k == v then
        -- World-killed (fall/vehicle) or suicide — death credit only.
        write_event("SUICIDE", v_ip, v_name, "", "", "")
        recent_damagers[v] = nil
        return
    end

    local k_name = get_var(k, "$name")
    local k_ip   = get_var(k, "$ip")
    write_event("KILL", k_ip, k_name, v_ip, v_name, "")

    -- Assists: any damager other than killer within window.
    local assisters = pop_assisters(v, k)
    for _, a_idx in ipairs(assisters) do
        if player_present(a_idx) then
            local a_name = get_var(a_idx, "$name")
            local a_ip   = get_var(a_idx, "$ip")
            write_event("ASSIST", a_ip, a_name, v_ip, v_name, "")
        end
    end
end

function OnScore(PlayerIndex)
    -- Only credit flag caps in CTF. Other gametypes fire SCORE for
    -- kills/hill-time/laps which we either already track via OnDie
    -- or don't care about.
    if not is_ctf() then return end
    local name = get_var(PlayerIndex, "$name")
    local ip   = get_var(PlayerIndex, "$ip")
    write_event("FLAG_CAP", ip, name, "", "", "")
end

function OnGameEnd()
    -- Clear damage tracking so end-of-round stragglers don't leak into
    -- the next match.
    recent_damagers = {}
end

----------------------------------------------------------------
-- CHAT COMMANDS
----------------------------------------------------------------
local function read_player_stats(ip)
    local path = PLAYER_STATS_DIR .. "/" .. ip .. ".txt"
    local f = io.open(path, "r")
    if not f then return nil end
    local out = {}
    for line in f:lines() do
        local k, v = line:match("^(%w+)=(.+)$")
        if k then out[k] = v end
    end
    f:close()
    return out
end

local function read_leaderboard(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local rows = {}
    for line in f:lines() do
        local row = {}
        for kv in line:gmatch("[^|]+") do
            local k, v = kv:match("^(%w+)=(.+)$")
            if k then row[k] = v end
        end
        if row.rank then table.insert(rows, row) end
    end
    f:close()
    return rows
end

-- Responses use say() so they appear in the player's CHAT log (persists
-- ~10 seconds before scrolling) rather than rprint() which goes to the
-- 1-second console overlay.
local function tell(PlayerIndex, msg)
    say(PlayerIndex, msg)
end

local function cmd_stats(PlayerIndex)
    local ip = strip_port(get_var(PlayerIndex, "$ip"))
    local s = read_player_stats(ip)
    if not s then
        tell(PlayerIndex, "No stats recorded yet. Play a few rounds.")
        return
    end
    tell(PlayerIndex, string.format(
        "K: %s  D: %s  A: %s  C: %s  -  KDA %s",
        s.kills or "0", s.deaths or "0", s.assists or "0",
        s.captures or "0", s.kda or "0.0"))
end

local function show_board(PlayerIndex, path, header, sort_metric_field)
    local rows = read_leaderboard(path)
    if not rows or #rows == 0 then
        tell(PlayerIndex, "Leaderboard not ready yet.")
        return
    end
    tell(PlayerIndex, "--- " .. header .. " ---")
    local shown = 0
    for _, r in ipairs(rows) do
        if shown >= TOP_SHOW_N then break end
        local metric = r[sort_metric_field] or "0"
        tell(PlayerIndex, string.format("#%s  %s  -  %s %s  (K%s/D%s/A%s/C%s)",
            r.rank, r.name or "?", sort_metric_field:upper(), metric,
            r.kills or "0", r.deaths or "0", r.assists or "0", r.captures or "0"))
        shown = shown + 1
    end
end

local function cmd_top(PlayerIndex)
    show_board(PlayerIndex, LEADERBOARD_PATH, "Top by KDA", "kda")
end

local function cmd_fragger(PlayerIndex)
    show_board(PlayerIndex, FRAGGERS_PATH, "Top Fraggers", "kills")
end

local function cmd_capper(PlayerIndex)
    show_board(PlayerIndex, CAPPERS_PATH, "Top Cappers", "captures")
end

local function cmd_rank(PlayerIndex)
    local ip = strip_port(get_var(PlayerIndex, "$ip"))
    local s = read_player_stats(ip)
    if not s or not s.rank then
        tell(PlayerIndex, "No rank yet. Play a few rounds.")
        return
    end
    tell(PlayerIndex, string.format("Your rank: %s / %s  -  KDA %s",
        s.rank, s.total or "?", s.kda or "0.0"))
end

local function cmd_commands(PlayerIndex)
    tell(PlayerIndex, "--- Stats commands ---")
    tell(PlayerIndex, "/stats   - your own K/D/A/captures and KDA")
    tell(PlayerIndex, "/top     - top 5 by KDA")
    tell(PlayerIndex, "/fragger - top 5 by raw kills")
    tell(PlayerIndex, "/capper  - top 5 by flag captures")
    tell(PlayerIndex, "/rank    - your rank vs all tracked players")
end

function OnChat(PlayerIndex, Message, Type)
    if not Message then return end
    local msg = Message:lower():match("^%s*(.-)%s*$")
    if msg == "/stats" or msg == "stats" then
        cmd_stats(PlayerIndex)
        return false
    elseif msg == "/top" or msg == "top" then
        cmd_top(PlayerIndex)
        return false
    elseif msg == "/fragger" or msg == "fragger" then
        cmd_fragger(PlayerIndex)
        return false
    elseif msg == "/capper" or msg == "capper" then
        cmd_capper(PlayerIndex)
        return false
    elseif msg == "/rank" or msg == "rank" then
        cmd_rank(PlayerIndex)
        return false
    elseif msg == "/commands" or msg == "commands" or msg == "/help" or msg == "help" then
        cmd_commands(PlayerIndex)
        return false
    end
end
