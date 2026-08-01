--[[
  ACS Forge Kit — Progress Desk (SEPARATE from Gear Desk)

  FROM ACS_unlocker.ct (everything it actually has for progress):
    1) Skill Points — [[[mainstruct+188]+0]+0x11C]  (== holder+0x11C)
    2) Gear ownership grants — Gear Desk only (122 unlock() hashes)
    3) Uplay save force — MemScan; NOT run here (crashes ByteEngine)

  EXTERNAL SOURCES (online research 2026-08-01) — gaps vs unlocker:
    Perks:
      Paul44 FearLess table v4.x — "Build Perks List" via AccomplishmentManager
      https://fearlessrevolution.com/viewtopic.php?t=12874
      Perks == Challenges/Accomplishments; edit progress counters, prefer set N-1 then finish in-game.
      CT not in Downloads yet — drop Paul44 ACS CT here to mine AOBs safely.
    Crafting PLAN / schematics:
      Same ownership list as gear; unlock flips a type/flag on the record (community dump: 010 → 015)
      Known schematic hash example: Throwing Knife Upgrade 3 = 43FDEAAA1D (LE in list)
      https://fearlessrevolution.com/viewtopic.php?t=8543
      NOT a separate "plans" table in public unlockers — still ownership-list RE.
    Experience & Skills / Level Up / Gear List:
      Paul44 table + SunBeam ACS.CT (local: Downloads\ACS.CT) — XP via GetExperience AOBs
    Map fog / Secrets of London:
      No public fog-unlock table found. ACS.CT MapBase = teleporter/markers only.
      Paul44 icon teleport can show icons; fog clear not published.

  NOT in unlocker CT:
    - Perk tree completion flags (need Paul44 / AccomplishmentManager)
    - Map fog / world unlock tables (no public CT)
    - Crafting PLAN unlocks (ownership-list type flag; few published hashes)
    - Gang upgrades (no public CT offsets found)

  Byte Engine: tables\ACS_ForgeKit\progress_editor.lua
]]

ACS_ForgeProgress = ACS_ForgeProgress or {}
ACS_Progress = ACS_Progress or {}

-- #region agent log
local function agent_log(hid, loc, msg, data)
  local ok, payload = pcall(function()
    local parts = {
      string.format(
        '"sessionId":"f9ebbe","runId":"progress","hypothesisId":"%s","location":"%s","message":"%s","timestamp":%d',
        tostring(hid), tostring(loc), tostring(msg):gsub('"', "'"), (os.time() or 0) * 1000)
    }
    if type(data) == "table" then
      local bits = {}
      for k, v in pairs(data) do
        local vv = v
        if type(v) == "number" then vv = string.format("%.0f", v)
        elseif type(v) == "boolean" then vv = v and "true" or "false"
        else vv = '"' .. tostring(v):gsub('"', "'") .. '"' end
        bits[#bits + 1] = string.format('"%s":%s', tostring(k), vv)
      end
      parts[#parts + 1] = ',"data":{' .. table.concat(bits, ",") .. "}"
    end
    return "{" .. table.concat(parts, "") .. "}\n"
  end)
  if not ok or not payload then return end
  for _, p in ipairs({
    [[debug-f9ebbe.log]],
    [[debug-f9ebbe.log]],
  }) do
    local f = io.open(p, "a")
    if f then f:write(payload); f:close() end
  end
end
agent_log("P", "progress_editor.lua:load", "loaded", {})
-- #endregion

local MOD = "ACS.exe"
local GET_PEXP_AOB = "48 83 EC 28 48 8B 0D ?? ?? ?? ?? 48 83 C1 30 E8 ?? ?? ?? ?? 84 C0 0F 94 C0 48 83 C4 28 C3"
local GET_EXP_AOB  = "40 57 48 83 EC 20 48 8B FA 48 8D 91 68 01 00 00"
local MANAGER_AOB  = "45 33 F6 48 8D 05 ?? ?? ?? ?? 48 89 06 48 8D 05 ?? ?? ?? ?? 48 8D 8E 88 00 00 00"

local function gamePtr(p)
  return type(p) == "number" and p > 0x10000 and p < 0x800000000000
end

local function rq(a)
  if not gamePtr(a) then return nil end
  local ok, v = pcall(readQword, a)
  if ok and gamePtr(v) then return v end
  return nil
end

local function ri(a)
  local ok, v = pcall(readInteger, a)
  if ok then return v end
  return nil
end

local function ru16(a)
  local ok, v = pcall(readSmallInteger, a)
  if ok then return v end
  return nil
end

local function spaceHex(compact)
  local s = tostring(compact or ""):gsub("%s+", ""):upper()
  local out, i = {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "?" then
      out[#out + 1] = "??"; i = i + 1
      if s:sub(i, i) == "?" then i = i + 1 end
    else
      out[#out + 1] = s:sub(i, i + 1); i = i + 2
    end
  end
  return table.concat(out, " ")
end

local function toAddr(v)
  if type(v) == "number" and v > 0 then return math.floor(v) end
  if type(v) == "string" and v ~= "" then
    local hex = v:match("^0[xX](%x+)$") or (v:match("^%x+$") and v)
    if hex and not v:match("^%d+$") then return tonumber(hex, 16) end
    return tonumber(v, 16) or tonumber(v)
  end
  return nil
end

local function scanModuleAob(pattern)
  -- HARD DISABLE: AOB/MemScan from Progress Desk crashes ByteEngine (0xC0000005).
  -- #region agent log
  agent_log("P", "scanModuleAob", "blocked", {pat = tostring(pattern or ""):sub(1, 40)})
  -- #endregion
  return nil
end

local function ripRelQword(instr)
  -- unused helper kept for scans; mov rcx,[rip+d] length 7
  local disp = ri(instr + 3)
  if not disp then return nil end
  if disp >= 0x80000000 then disp = disp - 0x100000000 end
  local abs = instr + 7 + disp
  return rq(abs), abs
end

------------------------------------------------------------------
-- Resolve mainstruct / gear holder (NO MemScan / AOB — those AV ByteEngine)
------------------------------------------------------------------

local function rootLooksLive(root)
  if not gamePtr(root) then return false end
  local mid150, midBC = nil, nil
  pcall(function() mid150 = readQword(root + 0x150) end)
  pcall(function() midBC = readQword(root + 0xBC) end)
  if gamePtr(mid150) or gamePtr(midBC) then return true end
  return false
end

local function bindHolder(root)
  local holder, mid = nil, nil
  pcall(function() mid = readQword(root + 0x150) end)
  if gamePtr(mid) then pcall(function() holder = readQword(mid) end) end
  if not gamePtr(holder) then
    pcall(function() mid = readQword(root + 0xBC) end)
    if gamePtr(mid) then pcall(function() holder = readQword(mid) end) end
  end
  if gamePtr(holder) then ACS_Progress.holder = holder end
  return gamePtr(holder)
end

function ACS_Progress.resolveMainstruct()
  -- 1) Live Gear Desk bind only (Gear Desk already did the unsafe AOB/MemScan).
  if ACS_Gear and rootLooksLive(ACS_Gear.root) then
    ACS_Progress.root = ACS_Gear.root
    bindHolder(ACS_Progress.root)
    if gamePtr(ACS_Gear.holder) then ACS_Progress.holder = ACS_Gear.holder end
    -- #region agent log
    agent_log("P", "resolveMainstruct", "from_gear_live", {
      root = ACS_Progress.root, holder = ACS_Progress.holder or 0,
    })
    -- #endregion
    return true, "ok"
  end

  -- 2) Existing Progress root if still live
  if rootLooksLive(ACS_Progress.root) then
    bindHolder(ACS_Progress.root)
    -- #region agent log
    agent_log("P", "resolveMainstruct", "live_ok", {
      root = ACS_Progress.root, holder = ACS_Progress.holder or 0,
    })
    -- #endregion
    return true, "ok"
  end

  -- 3) Symbols only — never MemScan from this desk (0xC0000005 in ByteEngine).
  local function addrOf(name)
    local a = 0
    pcall(function()
      if getAddressSafe then a = getAddressSafe(name) or 0 end
      if (not a or a == 0) and getAddress then a = getAddress(name) or 0 end
    end)
    return math.floor(tonumber(a) or 0)
  end
  local root = addrOf("acsGearRoot")
  if not rootLooksLive(root) then root = addrOf("mainstruct") end
  if rootLooksLive(root) then
    ACS_Progress.root = root
    bindHolder(root)
    -- #region agent log
    agent_log("P", "resolveMainstruct", "from_symbol_live", {
      root = root, holder = ACS_Progress.holder or 0,
    })
    -- #endregion
    return true, "ok"
  end

  -- #region agent log
  agent_log("P", "resolveMainstruct", "need_gear_desk", {
    staleRoot = addrOf("mainstruct"), gearRoot = ACS_Gear and (ACS_Gear.root or 0) or 0,
  })
  -- #endregion
  return false, "Open Gear Desk → Retry Resolve first (Progress never MemScans — it crashes ByteEngine)"
end

------------------------------------------------------------------
-- Skill points (separate list: single value row)
------------------------------------------------------------------

function ACS_Progress.getSkillPoints()
  if not ACS_Progress.holder then ACS_Progress.resolveMainstruct() end
  if not ACS_Progress.holder then return nil end
  return ri(ACS_Progress.holder + 0x11C)
end

function ACS_Progress.setSkillPoints(n)
  n = math.floor(tonumber(n) or 0)
  if n < 0 then n = 0 end
  if n > 999999 then n = 999999 end
  if not ACS_Progress.holder then
    local ok, err = ACS_Progress.resolveMainstruct()
    if not ok then return false, err end
  end
  local before = ACS_Progress.getSkillPoints()
  local wOk = pcall(writeInteger, ACS_Progress.holder + 0x11C, n)
  local after = ACS_Progress.getSkillPoints()
  -- #region agent log
  agent_log("P", "setSkillPoints", "done", {before = before or -1, after = after or -1, want = n, wOk = wOk and true or false})
  -- #endregion
  return wOk, after
end

------------------------------------------------------------------
-- Experience (player+0x168)
------------------------------------------------------------------

function ACS_Progress.resolvePlayer()
  -- NEVER AOBScan/MemScan here — ByteEngine 0xC0000005.
  local sym = 0
  pcall(function()
    if getAddressSafe then sym = getAddressSafe("acsExperience") or 0 end
    if (not sym or sym == 0) and getAddress then sym = getAddress("acsExperience") or 0 end
  end)
  if sym ~= 0 and gamePtr(sym) then
    ACS_Progress.xpAddr = sym
    ACS_Progress.player = sym - 0x168
    -- #region agent log
    agent_log("P", "resolvePlayer", "sym_acsExperience", {xpAddr = sym, xp = ri(sym) or -1})
    -- #endregion
    return true, ri(sym)
  end

  local candidates = {}
  local actor = 0
  pcall(function()
    if getAddressSafe then actor = getAddressSafe("actorBag") or 0 end
    if (not actor or actor == 0) and getAddress then actor = getAddress("actorBag") or 0 end
  end)
  if actor ~= 0 then
    candidates[#candidates + 1] = actor
    local d = rq(actor)
    if d then candidates[#candidates + 1] = d end
  end
  if ACS_Progress.root and rootLooksLive(ACS_Progress.root) then
    for _, off in ipairs({ 0xE0, 0x100, 0x120, 0x140, 0x180, 0x1A0 }) do
      local mid = nil
      pcall(function() mid = readQword(ACS_Progress.root + off) end)
      if gamePtr(mid) then
        candidates[#candidates + 1] = mid
        local h = nil
        pcall(function() h = readQword(mid) end)
        if gamePtr(h) then candidates[#candidates + 1] = h end
      end
    end
  end
  for _, p in ipairs(candidates) do
    local xp = ri(p + 0x168)
    if xp and xp >= 0 and xp < 50000000 then
      ACS_Progress.player = p
      ACS_Progress.xpAddr = p + 0x168
      -- #region agent log
      agent_log("P", "resolvePlayer", "heuristic", {player = p, xp = xp})
      -- #endregion
      pcall(unregisterSymbol, "acsPlayer"); pcall(registerSymbol, "acsPlayer", p)
      pcall(unregisterSymbol, "acsExperience"); pcall(registerSymbol, "acsExperience", ACS_Progress.xpAddr)
      return true, xp
    end
  end

  -- #region agent log
  agent_log("P", "resolvePlayer", "fail", {reason = "no safe xp pointer"})
  -- #endregion
  return false, "XP not bound — optional; Skill Points still work after Gear Desk resolve"
end

function ACS_Progress.getExperience()
  if not ACS_Progress.xpAddr then
    local ok = ACS_Progress.resolvePlayer()
    if not ok then return nil end
  end
  return ri(ACS_Progress.xpAddr)
end

function ACS_Progress.setExperience(n)
  n = math.floor(tonumber(n) or 0)
  if n < 0 then n = 0 end
  if n > 99999999 then n = 99999999 end
  if not ACS_Progress.xpAddr then
    local ok, err = ACS_Progress.resolvePlayer()
    if not ok then return false, err end
  end
  local before = ACS_Progress.getExperience()
  local wOk = pcall(writeInteger, ACS_Progress.xpAddr, n)
  local after = ACS_Progress.getExperience()
  -- #region agent log
  agent_log("P", "setExperience", "done", {before = before or -1, after = after or -1, want = n, wOk = wOk and true or false})
  -- #endregion
  return wOk, after
end

------------------------------------------------------------------
-- Snapshot / diff for Crafting / Gang / Perks (separate stores)
------------------------------------------------------------------

ACS_Progress.snapshots = ACS_Progress.snapshots or {}

local SNAP_DIR = [[forge_extract\]]

local function dumpU32Block(base, nbytes)
  local out = {}
  if not gamePtr(base) then return out end
  local n = math.floor((nbytes or 0x200) / 4)
  for i = 0, n - 1 do
    local v = ri(base + i * 4)
    out[i * 4] = v or 0
  end
  return out
end

local function dumpHolderInts(holder, tag)
  local out = {}
  if not gamePtr(holder) then return out end
  for off = 0, 0x200, 4 do
    local v = ri(holder + off)
    if v and v ~= 0 then out[#out + 1] = { off = off, v = v } end
  end
  -- #region agent log
  agent_log("P", "snapshot", tag, {holder = holder, n = #out})
  -- #endregion
  return out
end

local function persistSnap(label, snap)
  pcall(function()
    local path = SNAP_DIR .. "progress_snap_" .. label .. ".lua.txt"
    local f = io.open(path, "w")
    if not f then return end
    f:write(string.format("label=%s root=%X skill=%s xp=%s sides=%d rootWords=%d\n",
      label, snap.root or 0, tostring(snap.skill), tostring(snap.xp),
      #(snap.sides or {}), snap.rootWords and (function()
        local n = 0; for _ in pairs(snap.rootWords) do n = n + 1 end; return n
      end)() or 0))
    for _, s in ipairs(snap.sides or {}) do
      f:write(string.format("  off=0x%X holder=%X list=%X count=%s cap=%s\n",
        s.off, s.holder or 0, s.list or 0, tostring(s.count), tostring(s.cap)))
    end
    -- compact changed-prone ints from rootWords (non-zero only)
    if snap.rootWords then
      local keys = {}
      for off, _ in pairs(snap.rootWords) do keys[#keys + 1] = off end
      table.sort(keys)
      for _, off in ipairs(keys) do
        local v = snap.rootWords[off]
        if v and v ~= 0 then
          f:write(string.format("  root+%X = %d (0x%X)\n", off, v, v % 0x100000000))
        end
      end
    end
    f:close()
  end)
end

local function loadSnapFromDisk(label)
  local path = SNAP_DIR .. "progress_snap_" .. label .. ".lua.txt"
  local f = io.open(path, "r")
  if not f then return nil end
  local snap = { label = label, sides = {}, rootWords = {}, skill = nil, xp = nil, root = 0 }
  for line in f:lines() do
    local lab, root, skill, xp, sides = line:match("^label=([^%s]+) root=(%x+) skill=([^%s]+) xp=([^%s]+) sides=(%d+)")
    if lab then
      snap.root = tonumber(root, 16) or 0
      if skill ~= "nil" then snap.skill = tonumber(skill) end
      if xp ~= "nil" then snap.xp = tonumber(xp) end
    else
      local off, holder, list, count, cap = line:match("^%s+off=0x(%x+) holder=(%x+) list=(%x+) count=([^%s]+) cap=([^%s]+)")
      if off then
        snap.sides[#snap.sides + 1] = {
          off = tonumber(off, 16), holder = tonumber(holder, 16), list = tonumber(list, 16),
          count = tonumber(count) or -1, cap = tonumber(cap) or -1,
        }
      else
        local roff, v = line:match("^%s+root%+(%x+) = (%-?%d+)")
        if roff then snap.rootWords[tonumber(roff, 16)] = tonumber(v) end
      end
    end
  end
  f:close()
  return snap
end

function ACS_Progress.snapshot(label)
  label = tostring(label or "snap"):gsub("[^%w_]+", "_")
  local okMain, mainErr = ACS_Progress.resolveMainstruct()
  local root = math.floor(tonumber(ACS_Progress.root) or 0)
  local snap = {
    label = label,
    t = os.time() or 0,
    root = root,
    skill = ACS_Progress.getSkillPoints(),
    xp = ACS_Progress.getExperience(),
    sides = {},
    rootWords = {},
    holderWords = {},
  }

  -- #region agent log
  agent_log("P", "snapshot", "begin", {
    label = label, root = root, mainOk = okMain and true or false, mainErr = tostring(mainErr or ""),
  })
  -- #endregion

  if gamePtr(root) then
    -- Full dword fingerprint of mainstruct (catches gang/perk flag writes).
    snap.rootWords = dumpU32Block(root, 0x400)
    for off = 0x40, 0x3F8, 8 do
      local mid = nil
      pcall(function() mid = readQword(root + off) end)
      if gamePtr(mid) then
        local h = nil
        pcall(function() h = readQword(mid) end)
        if not gamePtr(h) then h = mid end
        if gamePtr(h) then
          local list, count, cap = nil, nil, nil
          pcall(function() list = readQword(h + 0x40) end)
          count = ru16(h + 0x4A)
          cap = ru16(h + 0x48)
          snap.sides[#snap.sides + 1] = {
            off = off, mid = mid, holder = h, list = list or 0,
            count = count or -1, cap = cap or -1,
          }
          -- Also fingerprint holder header ints (upgrade counters often live here).
          local hw = dumpU32Block(h, 0x200)
          snap.holderWords[off] = hw
        end
      end
    end
  end
  if gamePtr(ACS_Progress.holder) then
    snap.holderInts = dumpHolderInts(ACS_Progress.holder, label .. "_holder")
  end

  ACS_Progress.snapshots[label] = snap
  persistSnap(label, snap)

  local sideN = #(snap.sides or {})
  local wordN = 0
  for _ in pairs(snap.rootWords or {}) do wordN = wordN + 1 end
  -- #region agent log
  agent_log("P", "snapshot", "saved", {
    label = label, sides = sideN, words = wordN,
    skill = snap.skill or -1, xp = snap.xp or -1, root = root,
  })
  -- #endregion
  return snap
end

function ACS_Progress.diff(aName, bName)
  local a = ACS_Progress.snapshots[aName] or loadSnapFromDisk(aName)
  local b = ACS_Progress.snapshots[bName] or loadSnapFromDisk(bName)
  if not a or not b then
    return nil, "need two snapshots (BEFORE then AFTER). missing=" ..
      tostring(not a and aName or "") .. "/" .. tostring(not b and bName or "")
  end
  ACS_Progress.snapshots[aName] = a
  ACS_Progress.snapshots[bName] = b

  local changes = {}
  if a.skill ~= b.skill then changes[#changes + 1] = string.format("skill %s -> %s", tostring(a.skill), tostring(b.skill)) end
  if a.xp ~= b.xp then changes[#changes + 1] = string.format("xp %s -> %s", tostring(a.xp), tostring(b.xp)) end

  local mapA = {}
  for _, s in ipairs(a.sides or {}) do mapA[s.off] = s end
  for _, s in ipairs(b.sides or {}) do
    local prev = mapA[s.off]
    if not prev then
      changes[#changes + 1] = string.format("NEW side off 0x%X count=%s", s.off, tostring(s.count))
    elseif prev.count ~= s.count or prev.list ~= s.list or prev.holder ~= s.holder then
      changes[#changes + 1] = string.format(
        "off 0x%X count %s->%s list %X->%X holder %X->%X",
        s.off, tostring(prev.count), tostring(s.count),
        prev.list or 0, s.list or 0, prev.holder or 0, s.holder or 0)
    end
  end

  -- Diff mainstruct dword fingerprint
  local wa, wb = a.rootWords or {}, b.rootWords or {}
  local keys = {}
  local seen = {}
  for off, _ in pairs(wa) do if not seen[off] then seen[off] = true; keys[#keys + 1] = off end end
  for off, _ in pairs(wb) do if not seen[off] then seen[off] = true; keys[#keys + 1] = off end end
  table.sort(keys)
  local rootDiffs = 0
  for _, off in ipairs(keys) do
    local va, vb = wa[off] or 0, wb[off] or 0
    if va ~= vb then
      rootDiffs = rootDiffs + 1
      if #changes < 40 then
        changes[#changes + 1] = string.format("mainstruct+0x%X  %d -> %d", off, va, vb)
      end
    end
  end

  -- Diff holder word blocks
  for off, hwB in pairs(b.holderWords or {}) do
    local hwA = (a.holderWords or {})[off] or {}
    for hoff, vb in pairs(hwB) do
      local va = hwA[hoff] or 0
      if va ~= vb and #changes < 60 then
        changes[#changes + 1] = string.format("holder@root+0x%X +0x%X  %d -> %d", off, hoff, va, vb)
      end
    end
  end

  -- #region agent log
  agent_log("P", "diff", "done", {n = #changes, rootDiffs = rootDiffs, a = aName, b = bName})
  -- #endregion
  return changes, nil, rootDiffs
end

------------------------------------------------------------------
-- Per-category row models (SEPARATE lists)
------------------------------------------------------------------

local CATS = {
  "Skill Points (unlocker)",
  "Experience (ACS.CT)",
  "Crafting Plans",
  "Gang Upgrades",
  "Perks / Map Fog",
}

local function rowsFor(cat)
  if cat:find("Skill", 1, true) then
    local v = ACS_Progress.getSkillPoints()
    local addr = ACS_Progress.holder and (ACS_Progress.holder + 0x11C) or 0
    return {
      { name = "Skill points  [[[mainstruct+188]+0]+0x11C]", kind = "skill", value = v, addr = addr },
      { name = "(from ACS_unlocker.ct — only progress value in that table)", kind = "hint" },
    }
  end
  if cat:find("Experience", 1, true) then
    local v = ACS_Progress.getExperience()
    return {
      { name = "Experience  (ACS.CT — NOT in unlocker)", kind = "xp", value = v, addr = ACS_Progress.xpAddr or 0 },
    }
  end
  if cat:find("Crafting", 1, true) then
    return {
      { name = "NOT in ACS_unlocker.ct", kind = "hint" },
      { name = "Unlocker only grants gear hashes + skill points + Uplay save patch", kind = "hint" },
      { name = "Crafting PLAN unlocks need separate RE (stash mats != plans)", kind = "hint" },
    }
  end
  if cat:find("Gang", 1, true) then
    return {
      { name = "NOT in ACS_unlocker.ct", kind = "hint" },
      { name = "No gang / borough upgrade offsets in that table", kind = "hint" },
    }
  end
  if cat:find("Perks", 1, true) then
    return {
      { name = "NOT in ACS_unlocker.ct", kind = "hint" },
      { name = "No perk-tree or map-fog tables in unlocker", kind = "hint" },
      { name = "ACS.CT has MapBase teleporter markers only — not fog unlock", kind = "hint" },
    }
  end
  return {}
end

------------------------------------------------------------------
-- Max-all known progress values (not gear)
------------------------------------------------------------------

function ACS_Progress.maxKnown()
  local lines = {}
  local ok1, sk = ACS_Progress.setSkillPoints(999)
  lines[#lines + 1] = ok1 and ("Skill points → " .. tostring(sk) .. "  (unlocker [[[mainstruct+188]+0]+11C])")
    or ("Skill points FAIL: " .. tostring(sk))
  local ok2, xp = ACS_Progress.setExperience(9999999)
  lines[#lines + 1] = ok2 and ("Experience → " .. tostring(xp) .. "  (ACS.CT path, not unlocker)")
    or ("Experience FAIL: " .. tostring(xp))
  lines[#lines + 1] = "Crafting / Gang / Perks / Map fog: NOT in ACS_unlocker.ct — nothing to max from that table."
  -- #region agent log
  agent_log("P", "maxKnown", "done", {skill = sk or -1, xp = xp or -1})
  -- #endregion
  return true, table.concat(lines, "\n")
end

------------------------------------------------------------------
-- GUI
------------------------------------------------------------------

local function safeClick(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      print("[Progress Desk] " .. tostring(err))
      pcall(showMessage, "Progress Desk error:\n" .. tostring(err))
    end
  end
end

local function buildForm()
  local f = createForm(false)
  f.Caption = "ACS Forge — Progress Desk (unlocker: skill only)"
  f.Width = 680
  f.Height = 520
  pcall(function() f.Position = "poScreenCenter" end)

  local title = createLabel(f)
  title.Caption = "Progress  —  unlocker = skill points; craft/gang/perk/map NOT in that CT"
  title.Left = 16
  title.Top = 12
  pcall(function() title.Font.Size = 12 end)

  local status = createLabel(f)
  status.Left = 16
  status.Top = 40
  status.Width = 640
  status.Height = 36
  local function setStatus(s) status.Caption = "Status: " .. (s or "") end

  local catBox = createComboBox(f)
  catBox.Left = 16
  catBox.Top = 84
  catBox.Width = 220
  for _, c in ipairs(CATS) do pcall(function() catBox.Items.add(c) end) end
  pcall(function() catBox.ItemIndex = 0 end)

  local list = createListBox(f)
  list.Left = 16
  list.Top = 120
  list.Width = 640
  list.Height = 260

  local rows = {}
  local function currentCat()
    local i = tonumber(catBox.ItemIndex) or 0
    return CATS[i + 1] or CATS[1]
  end

  local function refill()
    pcall(function() list.Items.clear() end)
    rows = rowsFor(currentCat())
    for _, r in ipairs(rows) do
      local line = r.name
      if r.value ~= nil then
        line = string.format("%s   = %s   @%X", r.name, tostring(r.value), r.addr or 0)
      end
      pcall(function() list.Items.add(line) end)
    end
    setStatus(currentCat() .. " — " .. #rows .. " rows")
  end
  catBox.OnChange = safeClick(refill)

  local function doResolve()
    setStatus("Resolving…")
    local ok1, e1 = ACS_Progress.resolveMainstruct()
    local ok2, e2 = ACS_Progress.resolvePlayer()
    -- #region agent log
    agent_log("P", "ui", "resolve", {
      main = ok1 and true or false, player = ok2 and true or false,
      root = ACS_Progress.root or 0, holder = ACS_Progress.holder or 0,
      skill = ACS_Progress.getSkillPoints() or -1,
      xp = ACS_Progress.getExperience() or -1,
    })
    -- #endregion
    setStatus(string.format("root=%X live=%s skill=%s xp=%s | %s",
      ACS_Progress.root or 0,
      (function()
        local r = ACS_Progress.root
        if not r then return "no" end
        local m = nil; pcall(function() m = readQword(r + 0x150) end)
        return gamePtr(m) and "yes" or "STALE"
      end)(),
      tostring(ACS_Progress.getSkillPoints()), tostring(ACS_Progress.getExperience()),
      ok1 and "main=ok" or tostring(e1)))
    refill()
  end

  local btnResolve = createButton(f)
  btnResolve.Caption = "Resolve"
  btnResolve.Left = 250
  btnResolve.Top = 82
  btnResolve.Width = 90
  btnResolve.OnClick = safeClick(doResolve)

  local btnMax = createButton(f)
  btnMax.Caption = "Max Skill+XP"
  btnMax.Left = 350
  btnMax.Top = 82
  btnMax.Width = 110
  btnMax.OnClick = safeClick(function()
    local ok, info = ACS_Progress.maxKnown()
    setStatus((tostring(info or "")):gsub("\n", " | "))
    showMessage(tostring(info))
    refill()
  end)

  local btnSet = createButton(f)
  btnSet.Caption = "Set Selected"
  btnSet.Left = 16
  btnSet.Top = 400
  btnSet.Width = 110
  btnSet.OnClick = safeClick(function()
    local i = tonumber(list.ItemIndex) or -1
    local r = rows[i + 1]
    if not r or r.kind == "hint" then showMessage("Select Skill Points or Experience row") return end
    local cur = tostring(r.value or 0)
    local s = inputQuery and inputQuery("Set value", r.name, cur) or cur
    local n = tonumber(s)
    if not n then showMessage("bad number") return end
    if r.kind == "skill" then
      local ok, v = ACS_Progress.setSkillPoints(n)
      setStatus(ok and ("skill=" .. tostring(v)) or tostring(v))
    elseif r.kind == "xp" then
      local ok, v = ACS_Progress.setExperience(n)
      setStatus(ok and ("xp=" .. tostring(v)) or tostring(v))
    end
    refill()
  end)

  local btnBefore = createButton(f)
  btnBefore.Caption = "Snapshot BEFORE"
  btnBefore.Left = 140
  btnBefore.Top = 400
  btnBefore.Width = 130
  btnBefore.OnClick = safeClick(function()
    local tag = "before_" .. (currentCat():gsub("%s+", "_"))
    local snap = ACS_Progress.snapshot(tag)
    local sides = snap and #(snap.sides or {}) or 0
    local words = 0
    if snap and snap.rootWords then for _ in pairs(snap.rootWords) do words = words + 1 end end
    -- #region agent log
    agent_log("P", "ui", "before_click", {tag = tag, sides = sides, words = words, root = snap and snap.root or 0})
    -- #endregion
    if not snap or (snap.root or 0) == 0 or sides == 0 then
      local msg = string.format(
        "BEFORE weak: root=%X sides=%d words=%d\nmainstruct was stale/empty — click Resolve (must show live=yes), then BEFORE again.",
        snap and (snap.root or 0) or 0, sides, words)
      setStatus(msg:gsub("\n", " | "))
      showMessage(msg)
      return
    end
    local msg = string.format(
      "BEFORE saved: %s\nroot=%X  sides=%d  dwords=%d\n\nNow change ONE upgrade/perk in-game, then Snapshot AFTER.",
      tag, snap.root or 0, sides, words)
    setStatus(string.format("BEFORE %s root=%X sides=%d words=%d", tag, snap.root or 0, sides, words))
    showMessage(msg)
  end)

  local btnAfter = createButton(f)
  btnAfter.Caption = "Snapshot AFTER"
  btnAfter.Left = 280
  btnAfter.Top = 400
  btnAfter.Width = 130
  btnAfter.OnClick = safeClick(function()
    local catKey = currentCat():gsub("%s+", "_")
    local before = "before_" .. catKey
    local after = "after_" .. catKey
    local snap = ACS_Progress.snapshot(after)
    local sides = snap and #(snap.sides or {}) or 0
    -- #region agent log
    agent_log("P", "ui", "after_click", {tag = after, sides = sides, root = snap and snap.root or 0})
    -- #endregion
    local changes, err, rootDiffs = ACS_Progress.diff(before, after)
    if not changes then
      showMessage(tostring(err) .. "\n(Take Snapshot BEFORE first on the same category)")
      return
    end
    local msg
    if #changes == 0 then
      msg = string.format(
        "AFTER saved (sides=%d) but 0 diffs vs BEFORE.\nDid anything change in-game between the two clicks?\nrootDiffs=%s",
        sides, tostring(rootDiffs or 0))
    else
      msg = string.format("Diff (%d changes, rootDiffs=%s):\n%s",
        #changes, tostring(rootDiffs or 0), table.concat(changes, "\n"))
    end
    setStatus(msg:gsub("\n", " | "):sub(1, 180))
    showMessage(msg)
  end)

  local tip = createLabel(f)
  tip.Caption = "SAFE: open Gear Desk → Resolve first, then Progress. Progress never MemScans (crashes BE)."
  tip.Left = 16
  tip.Top = 448
  tip.Width = 640

  f.OnClose = function() return caHide end
  ACS_ForgeProgress.form = f
  pcall(function() f.Visible = true end)
  if type(f.Show) == "function" then pcall(function() f.Show() end) end

  -- auto resolve
  if type(createTimer) == "function" then
    local t = createTimer(f)
    if t then
      t.Interval = 120
      local fired = false
      t.OnTimer = function(tm)
        if fired then
          pcall(function() tm.Enabled = false end)
          return
        end
        fired = true
        pcall(function() tm.Enabled = false end)
        pcall(function() if type(tm.destroy) == "function" then tm.destroy() end end)
        pcall(doResolve)
      end
      pcall(function() t.Enabled = true end)
    end
  else
    pcall(doResolve)
  end
end

if ACS_ForgeProgress.form then
  pcall(function()
    if not ACS_ForgeProgress.form.Destroyed then ACS_ForgeProgress.form.destroy() end
  end)
end
buildForm()
