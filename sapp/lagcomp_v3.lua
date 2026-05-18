-- lagcomp_v3.lua  —  server-side lag compensation for Halo Custom Edition
-- SAPP 10.2.1 CE
--
-- Phase 1 (shadow mode): snapshot every tick, on every damage event
-- rewind the victim by shooter.ping/2 and re-classify the hit using a
-- closest-point-on-aim-ray miss-distance test. Log the decision.
-- Don't modify game state. Once the log shows sensible head/body calls
-- against real fights, flip APPLY_UPGRADES = true for Phase 2.
--
-- Verified biped offsets (lagcomp_diag 2026-05-17):
--   pos    biped + 0x5C / 0x60 / 0x64   (float×3, world coords, FEET position)
--   aim    biped + 0x230 / 0x234 / 0x238 (float×3, normalized world-space dir)
--   crouch biped + 0x50C                 (float, 0.0 standing → 1.0 crouched)
--   ping   player_static + 0xDC          (int, ms)

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
local TICK_RATE       = 30
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

local function csv_safe(s)
    s = tostring(s or "")
    return s:gsub(",", " "):gsub("\n", " "):gsub("\r", "")
end

local function log_line(s)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. " [" .. SERVER_NAME .. "] " .. s .. "\n")
        f:close()
    end
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
    local zscale = 1 - (victim_snap.crouch or 0) * (1 - CROUCH_Z_SCALE)
    local head_z = victim_snap.pz + HEAD_CZ  * zscale
    local body_z = victim_snap.pz + TORSO_CZ * zscale

    local ox = shooter.px
    local oy = shooter.py
    local oz = shooter.pz + EYE_HEIGHT
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
    log_line(string.format("=== lagcomp_v3 v2 loaded (shadow=%s head_r=%.2f body_r=%.2f) ===",
        tostring(not APPLY_UPGRADES), HEAD_HIT_R, BODY_HIT_R))
end

function OnScriptUnload()
    log_line("=== lagcomp_v3 unloaded ===")
end

function OnLeave(idx)
    history[idx] = nil
    rpos[idx]    = nil
end

function OnTick()
    tick_count = tick_count + 1
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

    local rewind_ticks = math.floor(((rtt * 0.5) / 1000) * TICK_RATE + 0.5)
    if rewind_ticks > HISTORY_TICKS then rewind_ticks = HISTORY_TICKS end
    if rewind_ticks < 0 then rewind_ticks = 0 end

    local v_past = get_historical(v, rewind_ticks)
    if not v_past or not v_past.px then
        log_line(string.format("NO_HIST shooter=%s victim=%s rewind=%dt",
            csv_safe(shooter.name), csv_safe(victim_now.name), rewind_ticks))
        return
    end

    -- Sanity: the historical victim shouldn't be at a bizarre Z relative to now
    local region, miss_d, range_t, head_d, body_d = classify_hit(shooter, v_past)
    local engine = (hit_string or ""):lower()
    local upgrade = (region == "head" and engine ~= "head" and engine ~= "")

    log_line(string.format(
        "DMG shooter=%s(%dms) victim=%s rewind=%dt engine=%s rewind=%s miss=%s range=%s head_d=%s body_d=%s upgrade=%s "..
        "S=(%s,%s,%s) aim=(%s,%s,%s) V=(%s,%s,%s) crouch=%s",
        csv_safe(shooter.name), rtt,
        csv_safe(victim_now.name), rewind_ticks,
        tostring(hit_string), tostring(region),
        fmt(miss_d), fmt(range_t), fmt(head_d), fmt(body_d),
        tostring(upgrade),
        fmt(shooter.px), fmt(shooter.py), fmt(shooter.pz),
        fmt(shooter.ai), fmt(shooter.aj), fmt(shooter.ak),
        fmt(v_past.px), fmt(v_past.py), fmt(v_past.pz),
        fmt(v_past.crouch)
    ))

    if APPLY_UPGRADES and upgrade then
        local d = damage or 0
        local mult = (d >= BIG_WEAPON_THRESHOLD) and HEADSHOT_MULT_BIG or HEADSHOT_MULT_SMALL
        local boosted = d * mult
        log_line(string.format("  UPGRADE applied: damage %.2f -> %.2f (x%.1f, %s)",
            d, boosted, mult,
            (d >= BIG_WEAPON_THRESHOLD) and "big-weapon" or "small-weapon"))
        -- SAPP EVENT_DAMAGE_APPLICATION:
        --   return false           → block damage entirely
        --   return true            → pass through unchanged
        --   return true, <new_dmg> → replace damage with this value
        return true, boosted
    end
end
