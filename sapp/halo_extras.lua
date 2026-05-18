-- halo_extras.lua  —  data producer for the Discord bot's live-status,
-- match-summary, and admin-command features.
--
-- Writes:
--   /opt/halo-monitor/server_status.json     (every 30s — current map/players)
--   /opt/halo-monitor/match_summaries.log    (one line per game end)
--
-- Reads:
--   /opt/halo-monitor/sapp_command_queue.txt (every 1s — executes each line)
--
-- Per-match counters reset on EVENT_GAME_START.

api_version = "1.12.0.0"

-- ====== CONFIG ======
local SERVER_NAME      = "Server 1"
local STATUS_FILE      = "/opt/halo-monitor/server_status.json"
local MATCH_LOG        = "/opt/halo-monitor/match_summaries.log"
local CMD_QUEUE        = "/opt/halo-monitor/sapp_command_queue.txt"
local TICK_RATE        = 30
local STATUS_EVERY_S   = 30
local QUEUE_EVERY_S    = 1
-- =====================

local match_stats   = {}   -- match_stats[idx] = {kills,deaths,assists,captures,streak,longest_streak}
local tick_counter  = 0

local function safe(s)
    s = tostring(s or "")
    return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " "):gsub("\r", "")
end

local function reset_match()
    match_stats = {}
    for i = 1, 16 do
        match_stats[i] = {kills=0, deaths=0, assists=0, captures=0, streak=0, longest_streak=0}
    end
end

function OnScriptLoad()
    register_callback(cb["EVENT_GAME_START"],         "OnGameStart")
    register_callback(cb["EVENT_GAME_END"],           "OnGameEnd")
    register_callback(cb["EVENT_DIE"],                "OnDie")
    register_callback(cb["EVENT_SCORE"],              "OnScore")
    register_callback(cb["EVENT_DAMAGE_APPLICATION"], "OnDamage")
    register_callback(cb["EVENT_TICK"],               "OnTick")
    reset_match()
end

function OnScriptUnload() end

function OnGameStart()
    reset_match()
end

----------------------------------------------------------------
-- Per-match stat tracking
----------------------------------------------------------------
-- Assist credit copies the stats_tracker logic at smaller scope:
-- damage within 6s of death, anyone but the killer gets +1 assist.
local recent_damagers = {}   -- recent_damagers[victim] = { [causer] = clock }

function OnDamage(victim, causer, _meta, _dmg, _hit, _backtap)
    local v = tonumber(victim) or 0
    local c = tonumber(causer) or 0
    if v <= 0 or c <= 0 or v == c then return end
    recent_damagers[v] = recent_damagers[v] or {}
    recent_damagers[v][c] = os.clock()
end

function OnDie(victim, killer)
    local v = tonumber(victim) or 0
    local k = tonumber(killer) or 0
    if v <= 0 then return end

    if match_stats[v] then
        match_stats[v].deaths = match_stats[v].deaths + 1
        match_stats[v].streak = 0
    end
    if k > 0 and k ~= v and match_stats[k] then
        match_stats[k].kills  = match_stats[k].kills + 1
        match_stats[k].streak = match_stats[k].streak + 1
        if match_stats[k].streak > match_stats[k].longest_streak then
            match_stats[k].longest_streak = match_stats[k].streak
        end
    end
    -- Assists
    local pool = recent_damagers[v] or {}
    local now  = os.clock()
    for damager, ts in pairs(pool) do
        if damager ~= k and (now - ts) <= 6 and match_stats[damager] then
            match_stats[damager].assists = match_stats[damager].assists + 1
        end
    end
    recent_damagers[v] = nil
end

function OnScore(idx)
    local i = tonumber(idx) or 0
    if i <= 0 or not match_stats[i] then return end
    local gt = (get_var(0, "$gt") or ""):lower()
    if gt == "ctf" then
        match_stats[i].captures = match_stats[i].captures + 1
    end
end

----------------------------------------------------------------
-- Match-end summary writer
----------------------------------------------------------------
function OnGameEnd()
    local mvp, mvp_score          = "?", -999
    local top_frag, top_frag_n    = "?", -1
    local longest_n, longest_name = -1, "?"
    local top_cap, top_cap_n      = "?", -1
    local player_lines = {}

    for i = 1, 16 do
        local s = match_stats[i]
        if s and (s.kills + s.deaths + s.assists + s.captures) > 0 then
            local name = get_var(i, "$name") or "?"
            local score = s.kills + s.assists - s.deaths
            if score > mvp_score        then mvp, mvp_score = name, score end
            if s.kills > top_frag_n     then top_frag, top_frag_n = name, s.kills end
            if s.longest_streak > longest_n then longest_n, longest_name = s.longest_streak, name end
            if s.captures > top_cap_n   then top_cap, top_cap_n = name, s.captures end
            table.insert(player_lines, string.format(
                '{"name":"%s","kills":%d,"deaths":%d,"assists":%d,"captures":%d,"streak":%d}',
                safe(name), s.kills, s.deaths, s.assists, s.captures, s.longest_streak
            ))
        end
    end

    local ts  = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local map = get_var(0, "$map") or "?"
    local gt  = get_var(0, "$gt")  or "?"
    local payload = string.format(
        '{"ts":"%s","server":"%s","map":"%s","gt":"%s",'..
        '"mvp":"%s","mvp_score":%d,'..
        '"top_fragger":"%s","top_fragger_kills":%d,'..
        '"longest_streak_name":"%s","longest_streak":%d,'..
        '"top_capper":"%s","top_caps":%d,'..
        '"players":[%s]}',
        ts, safe(SERVER_NAME), safe(map), safe(gt),
        safe(mvp), mvp_score,
        safe(top_frag), top_frag_n,
        safe(longest_name), longest_n,
        safe(top_cap), top_cap_n,
        table.concat(player_lines, ",")
    )
    local f = io.open(MATCH_LOG, "a")
    if f then f:write(payload .. "\n") f:close() end
end

----------------------------------------------------------------
-- Status snapshot writer (atomic)
----------------------------------------------------------------
local function write_status()
    local map = get_var(0, "$map") or "?"
    local gt  = get_var(0, "$gt")  or "?"
    local players = {}
    local count = 0
    for i = 1, 16 do
        if player_present(i) then
            count = count + 1
            local name = get_var(i, "$name") or "?"
            local s = match_stats[i] or {kills=0,deaths=0}
            table.insert(players, string.format(
                '{"name":"%s","kills":%d,"deaths":%d}',
                safe(name), s.kills, s.deaths))
        end
    end
    local ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local maxp = tonumber(get_var(0, "$maxplayers")) or 16
    local payload = string.format(
        '{"ts":"%s","server":"%s","map":"%s","gt":"%s","count":%d,"max":%d,"players":[%s]}',
        ts, safe(SERVER_NAME), safe(map), safe(gt), count, maxp, table.concat(players, ","))

    -- Atomic write: write to .tmp, then rename
    local tmp = STATUS_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if f then
        f:write(payload)
        f:close()
        os.rename(tmp, STATUS_FILE)
    end
end

----------------------------------------------------------------
-- Command queue processor
----------------------------------------------------------------
local function process_queue()
    local f = io.open(CMD_QUEUE, "r")
    if not f then return end
    local lines = {}
    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^#") then
            table.insert(lines, line)
        end
    end
    f:close()
    if #lines == 0 then return end
    -- Truncate the file BEFORE execution (avoids re-running if exec fails)
    local w = io.open(CMD_QUEUE, "w")
    if w then w:write("") w:close() end
    for _, cmd in ipairs(lines) do
        cprint("[halo_extras] queue exec: " .. cmd)
        execute_command(cmd)
    end
end

----------------------------------------------------------------
-- Tick driver — replaces SAPP timer() which drifts badly under Wine
----------------------------------------------------------------
function OnTick()
    tick_counter = tick_counter + 1
    if tick_counter % (TICK_RATE * QUEUE_EVERY_S) == 0 then
        process_queue()
    end
    if tick_counter % (TICK_RATE * STATUS_EVERY_S) == 0 then
        write_status()
    end
end
