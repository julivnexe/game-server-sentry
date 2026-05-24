-- lagcomp_v3.lua  —  server-side lag compensation for Halo Custom Edition
-- SAPP 10.2.1 CE
--
-- Phase 2 (live): snapshot every tick, on every damage event rewind the
-- victim by shooter.ping/2 and re-classify the hit using a closest-point-
-- on-aim-ray miss-distance test. When the engine called it a body hit
-- but the rewind says it was a headshot, boost the damage in-flight
-- (4× for sniper-class, 2× for pistol/AR-class). Body shots that "felt
-- like" headshots from the shooter's POV register correctly.
--
-- Verified biped offsets (lagcomp_diag 2026-05-17):
--   pos    biped + 0x5C / 0x60 / 0x64   (float×3, world coords, FEET position)
--   aim    biped + 0x230 / 0x234 / 0x238 (float×3, normalized world-space dir)
--   crouch biped + 0x50C                 (float, 0.0 standing → 1.0 crouched)
--   ping   player_static + 0xDC          (int, ms)
--
-- Log format is stable: per-damage DMG / UPGRADE lines are unchanged so
-- existing log readers keep working. Added on top:
--   * Buffered writes (flushed on tick interval, match end, script unload)
--     — kills the per-shot fopen+fclose churn during heavy firefights.
--   * MATCH_SUMMARY line on EVENT_GAME_END — one line per match with
--     event totals, upgrade count, damage delta, top-upgraded shooters.
--   * ASCII-safe player names — non-ASCII chars become '?' so log
--     readers don't see corrupted UTF-8.

api_version = "1.12.0.0"

-- ====== CONFIG ======
local SERVER_NAME     = "Server 1"
local LOG_FILE        = "/opt/halo-monitor/lagcomp_v3.log"
local HISTORY_TICKS   = 15      -- 500ms at 30Hz
local MAX_PING_MS     = 250
local APPLY_UPGRADES  = true    -- PHASE 2: top up body→head when rewind disagrees
-- Damage-aware headshot multipliers, matching Halo CE's vanilla head:body
-- ratios. Sniper body in HCE ~= 100, head ~= 400 (4x). Pistol/AR/Plasma body
-- ~= 8-30, head ~= 2x of that. We pick the bucket by the engine-reported
-- damage value, which already includes the weapon's per-shot multipliers.
local HEADSHOT_MULT_BIG   = 4.0   -- sniper-class weapons
local HEADSHOT_MULT_SMALL = 2.0   -- pistol / AR / plasma / etc.
local BIG_WEAPON_THRESHOLD = 80   -- damage >= this is treated as sniper-class

-- High-ping caution: the rewind math is less reliable at higher pings
-- because a larger time window means the victim could have changed
-- direction between our ring-buffer samples. We still LOG every rewind
-- decision up to MAX_PING_MS (250) for analysis, but only actually
-- APPLY the damage boost when ping is <= this. Cases just above this
-- get logged as "UPGRADE skipped: ping too high".
local UPGRADE_MAX_PING_MS = 150
local TICK_RATE       = 30

-- Chimera client-side interpolation compensation. Modern HCE clients run
-- Chimera (by Snowy), which interpolates other players' rendered positions
-- N ticks behind the latest server update for smooth movement — Chimera's
-- default `chimera_interpolate` is 9 ticks (300ms @ 30Hz). The shooter aims
-- at where Chimera *drew* the victim, which is older than where the server
-- has them now. We rewind by `RTT/2 + interp_ticks` to actually land on
-- the head the shooter saw.
--
-- Used as the default for new players. Per-player auto-tuning (below)
-- overrides this once a player has accumulated enough damage samples.
local INTERP_COMPENSATION_TICKS = 9

-- Per-player interpolation auto-detect. For every damage event we ALSO
-- classify the hit at a spread of candidate rewind offsets (in addition to
-- the one used for the upgrade decision). Per shooter CD-key, we keep a
-- {offset → {matches, total}} table — matches counts how often the rewind
-- classification at that offset agrees with the engine's hit verdict. After
-- INTERP_AUTO_MIN_SAMPLES events the offset with the highest agreement rate
-- becomes that player's tuned compensation. No player input required.
local INTERP_AUTO_DETECT      = true
local INTERP_AUTO_CANDIDATES  = {0, 3, 6, 9, 12, 15}
local INTERP_AUTO_MIN_SAMPLES = 50              -- per shooter, total across offsets
local INTERP_PREFS_FILE       = "/opt/halo-monitor/lagcomp_derived.csv"
local INTERP_BUCKET_CAP       = 500             -- per-offset cap before halving (decay)
-- Hysteresis: only switch a player's derived offset if the new candidate's
-- match rate beats the current offset's rate by this much. Without it the
-- pick flip-flops between two near-tied offsets every minute (we saw 0↔3
-- swings on 0.74 vs 0.75 in early v6 testing).
local INTERP_SWITCH_HYSTERESIS = 0.03

-- Warp-detection: when victim's between-snapshot velocity exceeds this,
-- their position at rewind time is unreliable — they're being knocked back
-- by an explosion, dismounting a vehicle, taking a teleport, etc. Halo CE
-- player walking speed is ~3 u/s; sprinting/charging tops ~5. Dismounts +
-- explosion knockback routinely produce 15-40+ u/s spikes for 1-3 ticks.
-- We log every such case (regardless of upgrade decision) and refuse to
-- promote body→head while a victim is in a warp window — the snapshot
-- we'd rewind to wasn't really there.
local WARP_VELOCITY_UPS = 12.0      -- units/sec; above this = unreliable

-- Buffered-write tuning. Flushing on every damage event was 1 fopen +
-- 1 fclose per shot — under a 10-player firefight that's ~30 fopens/sec
-- competing with haloceded for the same disk. The buffer drains:
--   * every LOG_FLUSH_EVERY lines accumulated
--   * every LOG_FLUSH_TICKS ticks elapsed
--   * on EVENT_GAME_END  (so a MATCH_SUMMARY is never lost to a crash mid-match)
--   * on OnScriptUnload  (so a clean lua_reload doesn't drop tail lines)
-- Worst case loss on hard process death is one flush interval (≤5s).
local LOG_FLUSH_EVERY = 50
local LOG_FLUSH_TICKS = 150     -- 150 ticks @ 30Hz = 5s
-- =====================

-- Memory offsets
local OBJ_POS_X    = 0x5C
local OBJ_POS_Y    = 0x60
local OBJ_POS_Z    = 0x64
local OBJ_AIM_I    = 0x230
local OBJ_AIM_J    = 0x234
local OBJ_AIM_K    = 0x238
local OBJ_CROUCH   = 0x50C
local OBJ_HEALTH   = 0xE0
local OBJ_SHIELD   = 0xE4
local PLR_PING     = 0xDC

-- Hitbox (closest-point-on-ray model — these are MISS-DISTANCE radii,
-- not exact body sizes. Generous on purpose so we count grazes.)
local EYE_HEIGHT      = 0.55    -- shooter eye above feet
local HEAD_CZ         = 0.62    -- head center Z above feet (standing)
local TORSO_CZ        = 0.30    -- torso center Z above feet (standing)
local HEAD_HIT_R      = 0.15    -- max miss distance to credit as headshot
local BODY_HIT_R      = 0.45    -- max miss distance to credit as bodyshot
local CROUCH_Z_SCALE  = 0.55    -- crouched biped vertical scale

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local history    = {}    -- history[idx][ring_idx] = snapshot
local rpos       = {}
local tick_count = 0

-- Buffered-write state
local pending_lines  = {}
local last_flush_tick = 0

-- Interp auto-detect state. interp_samples[hash][offset] = {matches, total}
-- accumulates across the script's lifetime; interp_derived[hash] is the
-- current best-fit offset (mirrors what's saved to INTERP_PREFS_FILE).
local interp_samples = {}
local interp_derived = {}

-- Per-match counters (reset on EVENT_GAME_START, dumped on EVENT_GAME_END)
local match_total_dmg               = 0
local match_upgrades_applied        = 0
local match_upgrades_skipped_ping   = 0   -- skipped: shooter ping too high to trust the rewind
local match_upgrades_skipped_shield = 0   -- skipped: victim had shield up (head bonus wouldn't apply)
local match_upgrades_skipped_warp   = 0   -- skipped: victim warping (dismount / explosion knockback)
local match_damage_added            = 0
local match_shooter_upgrades        = {}  -- shooter_name -> upgrade count

local function ascii_safe(s)
    s = tostring(s or "")
    return (s:gsub("[\128-\255]", "?"))
end

local function csv_safe(s)
    s = ascii_safe(s)
    return s:gsub(",", " "):gsub("\n", " "):gsub("\r", "")
end

local function flush_logs()
    if #pending_lines == 0 then return end
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(table.concat(pending_lines))
        f:close()
    end
    pending_lines = {}
end

local function log_line(s)
    pending_lines[#pending_lines + 1] =
        os.date("!%Y-%m-%dT%H:%M:%SZ") .. " [" .. SERVER_NAME .. "] " .. s .. "\n"
    if #pending_lines >= LOG_FLUSH_EVERY then
        flush_logs()
    end
end

----------------------------------------------------------------
-- INTERP AUTO-DETECT
----------------------------------------------------------------
local function load_derived_prefs()
    interp_derived = {}
    local f = io.open(INTERP_PREFS_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local h, n = line:match("^([0-9a-fA-F]+),(%d+)%s*$")
        if h and n then interp_derived[h] = tonumber(n) end
    end
    f:close()
end

local function save_derived_prefs()
    local f = io.open(INTERP_PREFS_FILE, "w")
    if not f then return end
    for h, n in pairs(interp_derived) do
        f:write(string.format("%s,%d\n", h, n))
    end
    f:close()
end

local function effective_interp(hash)
    if hash and interp_derived[hash] then return interp_derived[hash] end
    return INTERP_COMPENSATION_TICKS
end

-- Bucket halving when a per-offset counter hits the cap. Keeps the system
-- adaptive — a player who changes their chimera_interpolate setting will
-- gradually drift to their new effective offset instead of being locked in
-- by years of stale samples.
local function decay_if_capped(bucket)
    if bucket.total >= INTERP_BUCKET_CAP then
        bucket.matches = math.floor(bucket.matches * 0.5)
        bucket.total   = math.floor(bucket.total   * 0.5)
    end
end

-- per_offset_class: table {[ticks_offset] = "head"|"body"|nil-string}
local function update_interp_samples(hash, engine, per_offset_class)
    if not hash or hash == "" then return end
    if engine ~= "head" and engine ~= "body" then return end
    local rec = interp_samples[hash]
    if not rec then rec = {}; interp_samples[hash] = rec end
    local grand_total = 0
    for off, cls in pairs(per_offset_class) do
        local b = rec[off]
        if not b then b = {matches = 0, total = 0}; rec[off] = b end
        b.total = b.total + 1
        if cls == engine then b.matches = b.matches + 1 end
        decay_if_capped(b)
        grand_total = grand_total + b.total
    end
    if grand_total < INTERP_AUTO_MIN_SAMPLES then return end
    -- Derive best offset: highest match rate, tie-break by lower offset
    -- (less aggressive). Require a per-bucket floor so a 1-of-1 perfect
    -- score doesn't outweigh a 40-of-50 strong score.
    local best_rate, best_off = -1, nil
    for off, b in pairs(rec) do
        if b.total >= 5 then
            local r = b.matches / b.total
            if r > best_rate or (r == best_rate and (best_off == nil or off < best_off)) then
                best_rate = r
                best_off  = off
            end
        end
    end
    if not best_off then return end
    local current = interp_derived[hash]
    if best_off == current then return end
    -- Hysteresis: don't switch unless the new offset's rate beats the current
    -- offset's rate by INTERP_SWITCH_HYSTERESIS. Computes current's rate from
    -- its own bucket; if current isn't in the table yet (first derivation),
    -- any pick wins.
    if current then
        local cur_bucket = rec[current]
        if cur_bucket and cur_bucket.total >= 5 then
            local cur_rate = cur_bucket.matches / cur_bucket.total
            if best_rate < cur_rate + INTERP_SWITCH_HYSTERESIS then return end
        end
    end
    local prev = current or INTERP_COMPENSATION_TICKS
    interp_derived[hash] = best_off
    log_line(string.format(
        "INTERP_DERIVED hash=%s prev=%d new=%d rate=%.2f samples=%d",
        hash, prev, best_off, best_rate, grand_total))
    save_derived_prefs()
end

local function reset_match_counters()
    match_total_dmg               = 0
    match_upgrades_applied        = 0
    match_upgrades_skipped_ping   = 0
    match_upgrades_skipped_shield = 0
    match_upgrades_skipped_warp   = 0
    match_damage_added            = 0
    match_shooter_upgrades        = {}
end

local function safe_read_float(addr)
    if not addr or addr == 0 then return nil end
    local ok, v = pcall(read_float, addr); return ok and v or nil
end
local function safe_read_int(addr)
    if not addr or addr == 0 then return nil end
    local ok, v = pcall(read_int, addr); return ok and v or nil
end

----------------------------------------------------------------
-- SNAPSHOTS
----------------------------------------------------------------
local function snapshot(idx)
    if not player_present(idx) then return nil end
    local biped = get_dynamic_player(idx)
    local pstat = get_player(idx)
    if not biped or biped == 0 then return nil end
    return {
        tick   = tick_count,
        biped  = biped,
        px = safe_read_float(biped + OBJ_POS_X),
        py = safe_read_float(biped + OBJ_POS_Y),
        pz = safe_read_float(biped + OBJ_POS_Z),
        ai = safe_read_float(biped + OBJ_AIM_I),
        aj = safe_read_float(biped + OBJ_AIM_J),
        ak = safe_read_float(biped + OBJ_AIM_K),
        crouch = safe_read_float(biped + OBJ_CROUCH) or 0,
        hp     = safe_read_float(biped + OBJ_HEALTH),
        shield = safe_read_float(biped + OBJ_SHIELD),
        ping   = pstat and pstat ~= 0 and safe_read_int(pstat + PLR_PING) or 0,
        name   = get_var(idx, "$name"),
    }
end

local function push_snapshot(idx, s)
    history[idx] = history[idx] or {}
    rpos[idx] = (rpos[idx] or 0) % HISTORY_TICKS + 1
    history[idx][rpos[idx]] = s
end

local function get_historical(idx, ticks_ago)
    if not history[idx] then return nil end
    local cur = rpos[idx]
    local n = ((cur - 1 - ticks_ago) % HISTORY_TICKS) + 1
    local s = history[idx][n]
    if not s then return nil end
    return s
end

-- Returns the victim's position-delta magnitude (units/sec) between the
-- rewind snapshot and the snapshot immediately prior. Used to detect warp
-- windows where the snapshot is unreliable. Returns nil if either snapshot
-- is missing or biped pointer changed (respawn / dismount creates a new
-- biped — previous-pos comparison would be bogus).
local function victim_warp_velocity(idx, ticks_ago)
    local cur  = get_historical(idx, ticks_ago)
    local prev = get_historical(idx, ticks_ago + 1)
    if not cur or not prev or not cur.px or not prev.px then return nil end
    if cur.biped ~= prev.biped then return nil end
    local dx, dy, dz = cur.px - prev.px, cur.py - prev.py, cur.pz - prev.pz
    local d = math.sqrt(dx*dx + dy*dy + dz*dz)
    return d * TICK_RATE   -- per-tick distance × ticks/sec = units/sec
end

----------------------------------------------------------------
-- GEOMETRY: closest-point-on-ray miss distance
----------------------------------------------------------------
-- Given ray origin O, unit direction D, target point P:
--   t = (P - O) . D       -- parameter of closest point on the ray
--   if t < 0 then P is behind the shooter, no hit
--   closest_point = O + D*t
--   miss_distance = |P - closest_point|
local function miss_dist_to_point(ox, oy, oz, dx, dy, dz, px, py, pz)
    local rx, ry, rz = px - ox, py - oy, pz - oz
    local t = rx*dx + ry*dy + rz*dz
    if t < 0 then return nil, nil end
    local cpx = ox + dx * t
    local cpy = oy + dy * t
    local cpz = oz + dz * t
    local mx, my, mz = px - cpx, py - cpy, pz - cpz
    return math.sqrt(mx*mx + my*my + mz*mz), t
end

-- Returns: region("head"/"body"/nil), miss_dist, range_along_ray, head_d, body_d
local function classify_hit(shooter, victim_snap)
    if not (shooter.ai and shooter.px and victim_snap.px) then
        return nil, nil, nil, nil, nil
    end
    local v_zscale = 1 - (victim_snap.crouch or 0) * (1 - CROUCH_Z_SCALE)
    local head_z = victim_snap.pz + HEAD_CZ  * v_zscale
    local body_z = victim_snap.pz + TORSO_CZ * v_zscale

    -- Apply the same crouch scaling to the shooter's eye. Before this
    -- fix, a crouched shooter aiming horizontally at a victim's torso
    -- got their ray origin computed 25 cm too high — over 5-10 m the
    -- ray ended up crossing head height near the victim, and body
    -- shots from a crouched shooter were wrongly classified as
    -- headshots → falsely upgraded → through-OS kills the user
    -- complained about.
    local s_zscale = 1 - (shooter.crouch or 0) * (1 - CROUCH_Z_SCALE)
    local ox = shooter.px
    local oy = shooter.py
    local oz = shooter.pz + EYE_HEIGHT * s_zscale
    local dx, dy, dz = shooter.ai, shooter.aj, shooter.ak

    local head_d, head_t = miss_dist_to_point(ox, oy, oz, dx, dy, dz,
                                              victim_snap.px, victim_snap.py, head_z)
    local body_d, body_t = miss_dist_to_point(ox, oy, oz, dx, dy, dz,
                                              victim_snap.px, victim_snap.py, body_z)

    -- Pick the closer one
    if head_d and head_d <= HEAD_HIT_R then
        return "head", head_d, head_t, head_d, body_d
    elseif body_d and body_d <= BODY_HIT_R then
        return "body", body_d, body_t, head_d, body_d
    else
        local best_d = math.min(head_d or 1e9, body_d or 1e9)
        if best_d == 1e9 then best_d = nil end
        return nil, best_d, body_t or head_t, head_d, body_d
    end
end

local function fmt(n)
    if n == nil then return "nil" end
    return string.format("%.3f", n)
end

----------------------------------------------------------------
-- CALLBACKS
----------------------------------------------------------------
function OnScriptLoad()
    register_callback(cb["EVENT_TICK"],               "OnTick")
    register_callback(cb["EVENT_DAMAGE_APPLICATION"], "OnDamage")
    register_callback(cb["EVENT_LEAVE"],              "OnLeave")
    register_callback(cb["EVENT_GAME_START"],         "OnGameStart")
    register_callback(cb["EVENT_GAME_END"],           "OnGameEnd")
    load_derived_prefs()
    reset_match_counters()
    local override_count = 0
    for _ in pairs(interp_derived) do override_count = override_count + 1 end
    log_line(string.format("=== lagcomp_v3 v6 loaded (shadow=%s head_r=%.2f body_r=%.2f flush_every=%d/%dt shield_gate=on warp_gate=%.1fu/s interp_comp_default=%dt auto_detect=%s overrides=%d) ===",
        tostring(not APPLY_UPGRADES), HEAD_HIT_R, BODY_HIT_R,
        LOG_FLUSH_EVERY, LOG_FLUSH_TICKS, WARP_VELOCITY_UPS,
        INTERP_COMPENSATION_TICKS, tostring(INTERP_AUTO_DETECT),
        override_count))
    flush_logs()
end

function OnScriptUnload()
    log_line("=== lagcomp_v3 unloaded ===")
    flush_logs()
    save_derived_prefs()
end

function OnLeave(idx)
    history[idx] = nil
    rpos[idx]    = nil
end

function OnGameStart()
    reset_match_counters()
end

function OnGameEnd()
    -- Drain any per-shot lines from the match first so the summary
    -- always appears AFTER its match's events in the log.
    flush_logs()
    if match_total_dmg == 0 then
        log_line("MATCH_SUMMARY no damage events recorded")
        flush_logs()
        return
    end
    -- Build top-5 upgraded shooters (sorted descending).
    local top = {}
    for name, n in pairs(match_shooter_upgrades) do
        top[#top + 1] = {name = name, n = n}
    end
    table.sort(top, function(a, b) return a.n > b.n end)
    local parts = {}
    for i = 1, math.min(5, #top) do
        parts[#parts + 1] = string.format("%s=%d", top[i].name, top[i].n)
    end
    local top_str = table.concat(parts, " ")
    local rate = match_upgrades_applied / math.max(1, match_total_dmg) * 100
    log_line(string.format(
        "MATCH_SUMMARY dmg_events=%d upgrades_applied=%d skipped_ping=%d skipped_shield=%d skipped_warp=%d upgrade_rate=%.1f%% damage_added=%.0f top_upgraded={%s}",
        match_total_dmg, match_upgrades_applied,
        match_upgrades_skipped_ping, match_upgrades_skipped_shield,
        match_upgrades_skipped_warp,
        rate, match_damage_added, top_str))
    flush_logs()
end

function OnTick()
    tick_count = tick_count + 1
    -- Periodic flush so a quiet match (no upgrade firing the buffer cap)
    -- still gets its DMG lines on disk within 5s.
    if tick_count - last_flush_tick >= LOG_FLUSH_TICKS then
        flush_logs()
        last_flush_tick = tick_count
    end
    for i = 1, 16 do
        if player_present(i) then
            local s = snapshot(i)
            if s then push_snapshot(i, s) end
        end
    end
end

function OnDamage(victim, killer, meta_id, damage, hit_string, backtap)
    local v = tonumber(victim) or 0
    local k = tonumber(killer) or 0
    if v == 0 or k == 0 or k == v then return end

    local shooter = snapshot(k)
    local victim_now = snapshot(v)
    if not shooter or not victim_now then return end

    local rtt = shooter.ping or 0
    if rtt > MAX_PING_MS then
        log_line(string.format("SKIP shooter=%s ping=%d>cap=%d", csv_safe(shooter.name), rtt, MAX_PING_MS))
        return
    end

    -- Rewind = network RTT/2 + per-shooter learned interp compensation.
    -- New players get the global default until they accumulate enough samples
    -- via the auto-detect block at the end of this function.
    local shooter_hash = get_var(k, "$hash") or ""
    local net_ticks = math.floor(((rtt * 0.5) / 1000) * TICK_RATE + 0.5)
    local comp = effective_interp(shooter_hash ~= "" and shooter_hash or nil)
    local rewind_ticks = net_ticks + comp
    if rewind_ticks > HISTORY_TICKS then rewind_ticks = HISTORY_TICKS end
    if rewind_ticks < 0 then rewind_ticks = 0 end

    local v_past = get_historical(v, rewind_ticks)
    if not v_past or not v_past.px then
        log_line(string.format("NO_HIST shooter=%s victim=%s rewind=%dt",
            csv_safe(shooter.name), csv_safe(victim_now.name), rewind_ticks))
        return
    end

    -- Reached here = a real damage event we classified. Count it.
    match_total_dmg = match_total_dmg + 1

    -- Sanity: the historical victim shouldn't be at a bizarre Z relative to now
    local region, miss_d, range_t, head_d, body_d = classify_hit(shooter, v_past)
    local engine = (hit_string or ""):lower()
    local upgrade = (region == "head" and engine ~= "head" and engine ~= "")

    log_line(string.format(
        "DMG shooter=%s(%dms) victim=%s rewind=%dt engine=%s rewind=%s miss=%s range=%s head_d=%s body_d=%s upgrade=%s "..
        "S=(%s,%s,%s) aim=(%s,%s,%s) V=(%s,%s,%s) crouch=%s vshield=%s",
        csv_safe(shooter.name), rtt,
        csv_safe(victim_now.name), rewind_ticks,
        tostring(hit_string), tostring(region),
        fmt(miss_d), fmt(range_t), fmt(head_d), fmt(body_d),
        tostring(upgrade),
        fmt(shooter.px), fmt(shooter.py), fmt(shooter.pz),
        fmt(shooter.ai), fmt(shooter.aj), fmt(shooter.ak),
        fmt(v_past.px), fmt(v_past.py), fmt(v_past.pz),
        fmt(v_past.crouch), fmt(v_past.shield)
    ))

    -- AUTO-DETECT: classify this hit at each candidate offset and feed the
    -- per-shooter sample buckets. Runs BEFORE the upgrade gates so we keep
    -- learning even on shots that get shield/warp/ping-skipped.
    if INTERP_AUTO_DETECT and shooter_hash ~= ""
       and (engine == "head" or engine == "body") then
        local per_offset = {}
        for _, off in ipairs(INTERP_AUTO_CANDIDATES) do
            local rt = net_ticks + off
            if rt > HISTORY_TICKS then rt = HISTORY_TICKS end
            local snap = get_historical(v, rt)
            if snap and snap.px then
                per_offset[off] = classify_hit(shooter, snap)  -- "head"/"body"/nil
            end
        end
        update_interp_samples(shooter_hash, engine, per_offset)
    end

    if APPLY_UPGRADES and upgrade then
        -- High-ping caution: rewind reliability degrades with the time
        -- window. Log the would-be upgrade but pass the damage through
        -- unchanged so we don't credit phantom kills to laggy shooters.
        if rtt > UPGRADE_MAX_PING_MS then
            match_upgrades_skipped_ping = match_upgrades_skipped_ping + 1
            log_line(string.format(
                "  UPGRADE skipped: ping=%d > cap=%d (rewind too uncertain at this ping)",
                rtt, UPGRADE_MAX_PING_MS))
            return
        end
        -- Shield-aware gate: in Halo CE a headshot through an active shield
        -- (normal OR overshield) does NO bonus damage — the head multiplier
        -- only applies once the shield is fully depleted. If we boost a
        -- body→head upgrade while the victim still has shield up, we'd
        -- credit damage a real headshot would never have done — especially
        -- against overshield (3× shield), where every head bonus would be
        -- pure fabrication. Pass through the original body damage instead.
        -- Shield value is normalized: 0 = depleted, 1.0 = full, up to 3.0 = OS.
        local v_shield = v_past.shield or 0
        if v_shield > 0 then
            match_upgrades_skipped_shield = match_upgrades_skipped_shield + 1
            log_line(string.format(
                "  UPGRADE skipped: victim shield=%.2f at shot time (a real headshot wouldn't bonus through an active shield)",
                v_shield))
            return
        end
        -- Warp gate: explosion knockback, vehicle dismount, teleport, etc.
        -- produce wild between-tick position deltas. The rewind snapshot
        -- is technically valid (we captured *something*) but the victim's
        -- actual position when the shooter pulled the trigger is anyone's
        -- guess — both client and server are extrapolating differently.
        -- Refusing the upgrade prevents phantom headshots on warping
        -- targets, which is what the player complaints have been about.
        local v_vel = victim_warp_velocity(v, rewind_ticks)
        if v_vel and v_vel > WARP_VELOCITY_UPS then
            match_upgrades_skipped_warp = match_upgrades_skipped_warp + 1
            log_line(string.format(
                "  UPGRADE skipped: victim warping at %.1f u/s (>%.1f cap; likely dismount/explosion/teleport — position unreliable)",
                v_vel, WARP_VELOCITY_UPS))
            return
        end
        local d = damage or 0
        local mult = (d >= BIG_WEAPON_THRESHOLD) and HEADSHOT_MULT_BIG or HEADSHOT_MULT_SMALL
        local boosted = d * mult
        match_upgrades_applied = match_upgrades_applied + 1
        match_damage_added     = match_damage_added + (boosted - d)
        local sname = ascii_safe(shooter.name or "?")
        match_shooter_upgrades[sname] = (match_shooter_upgrades[sname] or 0) + 1
        log_line(string.format("  UPGRADE applied: damage %.2f -> %.2f (x%.1f, %s, %dms)",
            d, boosted, mult,
            (d >= BIG_WEAPON_THRESHOLD) and "big-weapon" or "small-weapon",
            rtt))
        -- SAPP EVENT_DAMAGE_APPLICATION:
        --   return false           → block damage entirely
        --   return true            → pass through unchanged
        --   return true, <new_dmg> → replace damage with this value
        return true, boosted
    end
end
