--[[
  ACS Forge Kit — Hub Menu (CT + Byte Engine .bt)

  Same flow as the address-list scripts:
    [1] Boot Signatures
    [2] Input Pump
    [3] Inventory Desk
    [4] Gear Desk

  Works whether the table was opened as .CT or .bt.
  If address-list scripts are missing, Boot/Pump are run from ACS_ForgeKit.bt.
]]

local function safeShowForm(f)
  if not f then return end
  pcall(function() f.Visible = true end)
  if type(f.Show) == "function" then pcall(function() f.Show() end) end
  if type(f.BringToFront) == "function" then pcall(function() f.BringToFront() end) end
end

if ACS_ForgeHub and ACS_ForgeHub.form and (not ACS_ForgeHub.form.Destroyed) then
  pcall(function() ACS_ForgeHub.form.destroy() end)
  ACS_ForgeHub.form = nil
end

ACS_ForgeHub = ACS_ForgeHub or {}

local function kitDir()
  local candidates = {}
  candidates[#candidates + 1] = [[tables\ACS_ForgeKit\]]
  local base = (getCheatEngineDir and getCheatEngineDir()) or ""
  if base ~= "" then
    if not base:find("[\\/]$") then base = base .. "\\" end
    candidates[#candidates + 1] = base .. "tables\\ACS_ForgeKit\\"
  end
  candidates[#candidates + 1] = [[tables\ACS_ForgeKit\]]
  candidates[#candidates + 1] = [[tables\ACS_ForgeKit\]]
  for _, d in ipairs(candidates) do
    local f = io.open(d .. "forge_kit_menu.lua", "r")
    if f then f:close() return d end
  end
  return candidates[1]
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local src = f:read("*a")
  f:close()
  return src
end

local function runLuaFile(name)
  local path = kitDir() .. name
  local src = readFile(path)
  if not src then
    showMessage("Missing:\n" .. path)
    return false
  end
  local fn, err = load(src)
  -- #region agent log
  do
    local f = io.open([[debug-f9ebbe.log]], "a")
    if f then
      f:write(string.format(
        '{"sessionId":"f9ebbe","runId":"hub","hypothesisId":"H1","location":"forge_kit_menu.lua:runLuaFile","message":"load_result","data":{"name":"%s","ok":%s,"err":"%s"},"timestamp":%d}\n',
        tostring(name), fn and "true" or "false",
        tostring(err or ""):gsub('"', "'"):gsub("\n", " "),
        (os.time() or 0) * 1000))
      f:close()
    end
  end
  -- #endregion
  if not fn then showMessage(tostring(err)) return false end
  fn()
  return true
end

local function decodeJson(text)
  if json and json.decode then
    local ok, data = pcall(json.decode, text)
    if ok then return data end
  end
  if decodeJson then
    local ok, data = pcall(decodeJson, text)
    if ok then return data end
  end
  if jsonToTable then
    local ok, data = pcall(jsonToTable, text)
    if ok then return data end
  end
  return nil
end

local function scriptFromBt(desc)
  local path = kitDir() .. "ACS_ForgeKit.bt"
  local text = readFile(path)
  if not text then return nil end
  local data = decodeJson(text)
  if not data or type(data.Entries) ~= "table" then return nil end
  for _, e in ipairs(data.Entries) do
    if e.Description == desc and type(e.Script) == "string" and e.Script ~= "" then
      return e.Script
    end
  end
  -- partial match (first hit)
  for _, e in ipairs(data.Entries) do
    if type(e.Description) == "string" and e.Description:find(desc, 1, true)
       and type(e.Script) == "string" and e.Script ~= "" then
      return e.Script
    end
  end
  return nil
end

local function findRecord(desc)
  local al = getAddressList and getAddressList() or nil
  if not al then return nil end
  local best, bestLen = nil, -1
  for i = 0, (al.Count or 0) - 1 do
    local mr = al.getMemoryRecord(i)
    if mr and mr.Description and tostring(mr.Description):find(desc, 1, true) then
      local scr = ""
      pcall(function() scr = tostring(mr.Script or "") end)
      if #scr > bestLen then
        best, bestLen = mr, #scr
      end
    end
  end
  return best
end

-- #region agent log
local function dbgLog(hypothesisId, location, message, data)
  local payload = {
    sessionId = "f9ebbe",
    runId = "pump-ctxbag",
    hypothesisId = tostring(hypothesisId or ""),
    location = tostring(location or ""),
    message = tostring(message or ""),
    data = data or {},
    timestamp = (os.time() * 1000),
  }
  local okj, body = pcall(function()
    if json and json.encode then return json.encode(payload) end
    if encodeJson then return encodeJson(payload) end
    return nil
  end)
  if not okj or not body then
    local bits = {}
    for k, v in pairs(payload.data or {}) do
      bits[#bits + 1] = tostring(k) .. "=" .. tostring(v)
    end
    body = string.format(
      '{"sessionId":"f9ebbe","runId":"pump-ctxbag","hypothesisId":"%s","location":"%s","message":"%s","data":{%s},"timestamp":%d}',
      payload.hypothesisId, payload.location, payload.message:gsub('"', "'"),
      table.concat(bits, ","), payload.timestamp
    )
  end
  pcall(function()
    local f = io.open([[debug-f9ebbe.log]], "a")
    if f then f:write(body .. "\n"); f:close() end
  end)
  pcall(function()
    local f = io.open(kitDir() .. "debug-f9ebbe.log", "a")
    if f then f:write(body .. "\n"); f:close() end
  end)
end

local function scriptProbe(scr)
  if type(scr) ~= "string" then
    return { len = 0, bareCtxBag = false, bareCtxPtr = false, hasWorkerOff = false }
  end
  return {
    len = #scr,
    bareCtxBag = (scr:find("%[ctxBag%]") ~= nil) or (scr:find("mov%s+%w+,ctxBag") ~= nil),
    bareCtxPtr = (scr:find("%[ctxPtr%]") ~= nil) or (scr:find("mov%s+%w+,ctxPtr") ~= nil),
    hasWorkerOff = (scr:find("inputPumpWorker%+8A4", 1, true) ~= nil) or (scr:find("inputPumpWorker+8A4", 1, true) ~= nil),
  }
end
-- #endregion

local function enableScript(desc)
  -- #region agent log
  dbgLog("B", "forge_kit_menu.lua:enableScript", "enableScript enter", { desc = desc, kit = kitDir() })
  -- #endregion
  local mr = findRecord(desc)
  if mr then
    local alScr = ""
    pcall(function() alScr = tostring(mr.Script or "") end)
    -- #region agent log
    local alProbe = scriptProbe(alScr)
    dbgLog("A", "forge_kit_menu.lua:enableScript", "address-list script probe", alProbe)
    -- #endregion
    -- Prefer fresh disk .bt when address-list body still has bare ctxBag/ctxPtr operands
    if alProbe.bareCtxBag or alProbe.bareCtxPtr then
      -- #region agent log
      dbgLog("B", "forge_kit_menu.lua:enableScript", "skipping stale address-list AA", alProbe)
      -- #endregion
    else
      pcall(function() if mr.Active then mr.Active = false end end)
      local ok, err = pcall(function() mr.Active = true end)
      if ok and mr.Active then
        if BT and BT.rebindSymbols then pcall(BT.rebindSymbols) end
        -- #region agent log
        local sym = {}
        pcall(function() sym.inputPumpWorker = getAddress("inputPumpWorker") end)
        pcall(function() sym.ctxBag = getAddress("ctxBag") end)
        pcall(function() sym.actorBag = getAddress("actorBag") end)
        dbgLog("E", "forge_kit_menu.lua:enableScript", "enabled via address list", sym)
        -- #endregion
        return true, "address list"
      end
      err = tostring(err or "Active stayed false")
      -- #region agent log
      dbgLog("C", "forge_kit_menu.lua:enableScript", "address-list toggle failed", { err = err })
      -- #endregion
      print("[Hub] toggle failed for " .. desc .. ": " .. err .. " — trying direct AA from .bt")
    end
  else
    -- #region agent log
    dbgLog("B", "forge_kit_menu.lua:enableScript", "no address-list record", { desc = desc })
    -- #endregion
  end
  -- Prefer on-disk .bt script (always fresh) over stale address-list body
  local scr = scriptFromBt(desc)
  if not scr and BT and BT.loaded and BT.loaded.scriptText then
    for k, v in pairs(BT.loaded.scriptText) do
      if k == desc or (type(k) == "string" and k:find(desc, 1, true)) then
        scr = v
        break
      end
    end
  end
  -- #region agent log
  dbgLog("A", "forge_kit_menu.lua:enableScript", "disk .bt script probe", scriptProbe(scr))
  -- #endregion
  if scr and autoAssemble then
    local ok, err = pcall(autoAssemble, scr)
    if ok then
      if BT and BT.rebindSymbols then pcall(BT.rebindSymbols) end
      -- #region agent log
      local sym = {}
      pcall(function() sym.inputPumpWorker = getAddress("inputPumpWorker") end)
      pcall(function() sym.ctxBag = getAddress("ctxBag") end)
      pcall(function() sym.actorBag = getAddress("actorBag") end)
      dbgLog("E", "forge_kit_menu.lua:enableScript", "enabled via direct AA", sym)
      -- #endregion
      return true, "direct AA from .bt"
    end
    -- #region agent log
    dbgLog("C", "forge_kit_menu.lua:enableScript", "direct AA failed", { err = tostring(err) })
    -- #endregion
    return false, "autoAssemble failed: " .. tostring(err)
  end
  -- Last chance: load .bt into address list then retry record toggle
  local btPath = kitDir() .. "ACS_ForgeKit.bt"
  if BT and BT.loadFile and readFile(btPath) then
    local lok = pcall(BT.loadFile, btPath)
    if lok then
      mr = findRecord(desc)
      if mr then
        local ok2 = pcall(function() mr.Active = true end)
        if ok2 and mr.Active then
          if BT and BT.rebindSymbols then pcall(BT.rebindSymbols) end
          -- #region agent log
          dbgLog("E", "forge_kit_menu.lua:enableScript", "enabled via load.bt+AL", {})
          -- #endregion
          return true, "loaded .bt then address list"
        end
      end
      scr = scriptFromBt(desc)
      if scr and autoAssemble then
        local ok3, err3 = pcall(autoAssemble, scr)
        if ok3 then return true, "loaded .bt then direct AA" end
        -- #region agent log
        dbgLog("C", "forge_kit_menu.lua:enableScript", "load.bt then AA failed", { err = tostring(err3) })
        -- #endregion
        return false, "autoAssemble failed: " .. tostring(err3)
      end
    end
  end
  -- #region agent log
  dbgLog("D", "forge_kit_menu.lua:enableScript", "not found", { desc = desc })
  -- #endregion
  return false, "not found: " .. desc .. "\nLoad ACS_ForgeKit.bt first, then retry"
end

local function ensureTableHint()
  if findRecord("[1] Boot Signatures") or findRecord("[1] Boot") then return end
  local bt = kitDir() .. "ACS_ForgeKit.bt"
  if writeToClipboard then pcall(writeToClipboard, bt) end
end

local function isActive(desc)
  local mr = findRecord(desc)
  return mr and mr.Active
end

local function startKit()
  local notes = {}
  if not isActive("[1] Boot Signatures") then
    local ok, msg = enableScript("[1] Boot Signatures")
    notes[#notes + 1] = ok and "Boot OK" or ("Boot FAIL: " .. tostring(msg))
    if not ok then return false, table.concat(notes, " | ") end
  else
    notes[#notes + 1] = "Boot already on"
  end
  if not isActive("[2] Input Pump") then
    local ok, msg = enableScript("[2] Input Pump")
    notes[#notes + 1] = ok and "Pump OK" or ("Pump FAIL: " .. tostring(msg))
    if not ok then return false, table.concat(notes, " | ") end
  else
    notes[#notes + 1] = "Pump already on"
  end
  if BT and BT.rebindSymbols then pcall(BT.rebindSymbols) end
  return true, table.concat(notes, " | ")
end

local function build()
  local f = createForm(false)
  f.Caption = "ACS Forge Kit"
  f.Width = 440
  f.Height = 300
  f.Position = "poScreenCenter"

  local title = createLabel(f)
  title.Caption = "ACS Forge Kit"
  title.Left = 16
  title.Top = 12
  title.Font.Size = 16
  pcall(function() title.Font.Style = "fsBold" end)

  local status = createLabel(f)
  status.Left = 16
  status.Top = 48
  status.Width = 400
  status.Height = 40
  local function setStatus(s) status.Caption = s or "" end

  local y = 100
  local function addBtn(caption, w, fn)
    local b = createButton(f)
    b.Caption = caption
    b.Left = 16
    b.Top = y
    b.Width = w or 400
    b.Height = 32
    b.OnClick = function(...)
      local ok, err = pcall(fn, ...)
      if not ok then
        local msg = tostring(err)
        print("[Hub] " .. msg)
        setStatus("Error: " .. msg)
        pcall(showMessage, msg)
      end
    end
    y = y + 40
    return b
  end

  addBtn("START — Boot + Input Pump", 400, function()
    local ok, msg = startKit()
    setStatus(ok and ("Kit running — " .. msg) or msg)
    if not ok then showMessage(msg) end
  end)

  addBtn("Inventory Desk", 400, function()
    local ok, msg = startKit()
    if not ok then setStatus(msg) showMessage(msg) return end
    if runLuaFile("inventory_editor.lua") then
      setStatus("Inventory opened (" .. msg .. ")")
    end
  end)

  addBtn("Progress Desk (XP / Upgrades / Gang)", 400, function()
    local ok, msg = startKit()
    if not ok then setStatus(msg) showMessage(msg) return end
    if runLuaFile("progress_editor.lua") then
      setStatus("Progress Desk opened (" .. msg .. ")")
    end
  end)

  addBtn("Gear Desk", 400, function()
    local ok, msg = startKit()
    if not ok then setStatus(msg) showMessage(msg) return end
    if runLuaFile("gear_editor.lua") then
      setStatus("Gear opened (" .. msg .. ")")
    end
  end)

  addBtn("Max Skill+XP (Progress)", 400, function()
    local ok, msg = startKit()
    if not ok then setStatus(msg) showMessage(msg) return end
    if not runLuaFile("progress_editor.lua") then return end
    if type(ACS_Progress) ~= "table" or type(ACS_Progress.maxKnown) ~= "function" then
      showMessage("progress_editor missing maxKnown")
      return
    end
    local uok, info = ACS_Progress.maxKnown()
    setStatus((tostring(info or "")):gsub("\n", " | "):sub(1, 160))
    showMessage(tostring(info))
  end)

  addBtn("Reload table (.bt)", 400, function()
    local bt = kitDir() .. "ACS_ForgeKit.bt"
    local ok, err = true, nil
    if ACS_ForgeKit_LoadBT then
      ok, err = pcall(ACS_ForgeKit_LoadBT)
    elseif loadByteTable then
      ok, err = pcall(loadByteTable, bt, false)
    else
      showMessage("Missing loadByteTable — restart Byte Engine")
      return
    end
    if not ok then
      setStatus("Load failed: " .. tostring(err))
      return
    end
    setStatus("Table reloaded — press START if needed")
  end)

  ensureTableHint()
  setStatus("Starting Boot + Pump…")
  f.OnClose = function() return caHide end
  ACS_ForgeHub.form = f
  safeShowForm(f)
  if type(f.Show) == "function" then pcall(function() f.Show() end) end

  local t = createTimer(nil)
  t.Interval = 350
  t.OnTimer = function(timer)
    timer.destroy()
    local ok, msg = startKit()
    setStatus(ok and ("Kit running — " .. msg) or ("Press START — " .. tostring(msg)))
  end
end

build()
