-- HormonySettings.lua
-- Hormony API -- Settings UI
-- Persists configuration to Hormony_Config.json in the hormony working directory.
-- The runtime bridge script (HormonyBridge.lua) reads this config on start.

local SCRIPT_VERSION = "0.2.0"

function getClientInfo()
  return {
    name = SV:T("Hormony Settings"),
    author = "Wuyilingwei",
    versionNumber = 1,
    minEditorVersion = 65537
  }
end

function getTranslations(langCode)
  if langCode == "zh-cn" then
    return {
      {"Hormony Settings", "Hormony 设置"},
      {"Settings saved.", "设置已保存。"},
      {"Update Interval", "更新间隔"},
      {"Working Directory", "工作目录"},
      {"Reset to Default", "重置为默认"},
    }
  end
  return {}
end

-- ==========================================
-- Minimal JSON encode/decode (shared subset)
-- ==========================================
local json = {}

local function escape_str(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return s
end

function json.encode(val)
  local t = type(val)
  if t == "number" then
    if val == math.floor(val) and val < 2147483647 and val > -2147483647 then
      return tostring(math.floor(val))
    else
      return string.format("%.16g", val)
    end
  elseif t == "boolean" then
    return tostring(val)
  elseif t == "string" then
    return '"' .. escape_str(val) .. '"'
  elseif t == "table" then
    -- Check if array
    local is_array = true
    local max_k = 0
    for k, v in pairs(val) do
      if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
        is_array = false
        break
      end
      if k > max_k then max_k = k end
    end
    if is_array and max_k > 0 then
      local parts = {}
      for i = 1, max_k do
        if val[i] == nil then
          table.insert(parts, "null")
        else
          table.insert(parts, json.encode(val[i]))
        end
      end
      return "[" .. table.concat(parts, ",") .. "]"
    elseif next(val) == nil then
      return "{}"
    else
      local parts = {}
      for k, v in pairs(val) do
        if type(k) == "string" then
          table.insert(parts, '"' .. escape_str(k) .. '":' .. json.encode(v))
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  elseif val == nil then
    return "null"
  end
  return '"<unsupported>"'
end

local function parse_value(str, pos)
  while pos <= #str do
    local c = str:sub(pos, pos)
    if not c:match("%s") then break end
    pos = pos + 1
  end
  if pos > #str then return nil, pos end
  local c = str:sub(pos, pos)

  if c == '{' then
    local obj = {}
    pos = pos + 1
    while pos <= #str do
      while str:sub(pos, pos):match("%s") do pos = pos + 1 end
      if str:sub(pos, pos) == '}' then return obj, pos + 1 end
      local key
      key, pos = parse_value(str, pos)
      while str:sub(pos, pos):match("%s") do pos = pos + 1 end
      if str:sub(pos, pos) == ':' then pos = pos + 1 end
      local val
      val, pos = parse_value(str, pos)
      obj[key] = val
      while str:sub(pos, pos):match("%s") do pos = pos + 1 end
      if str:sub(pos, pos) == ',' then pos = pos + 1 end
    end
    return obj, pos
  elseif c == '[' then
    local arr = {}
    pos = pos + 1
    local i = 1
    while pos <= #str do
      while str:sub(pos, pos):match("%s") do pos = pos + 1 end
      if str:sub(pos, pos) == ']' then return arr, pos + 1 end
      local val
      val, pos = parse_value(str, pos)
      arr[i] = val
      i = i + 1
      while str:sub(pos, pos):match("%s") do pos = pos + 1 end
      if str:sub(pos, pos) == ',' then pos = pos + 1 end
    end
    return arr, pos
  elseif c == '"' then
    local s = ""
    pos = pos + 1
    while pos <= #str do
      local cc = str:sub(pos, pos)
      if cc == '"' then return s, pos + 1 end
      if cc == '\\' then
        pos = pos + 1
        local ec = str:sub(pos, pos)
        if ec == 'n' then s = s .. '\n'
        elseif ec == 'r' then s = s .. '\r'
        elseif ec == 't' then s = s .. '\t'
        else s = s .. ec end
      else
        s = s .. cc
      end
      pos = pos + 1
    end
    return s, pos
  elseif c:match("[%w%-%.]") then
    local s = ""
    while pos <= #str do
      local cc = str:sub(pos, pos)
      if not cc:match("[%w%-%.]") then break end
      s = s .. cc
      pos = pos + 1
    end
    if s == "true" then return true, pos end
    if s == "false" then return false, pos end
    if s == "null" then return nil, pos end
    return tonumber(s) or s, pos
  end
  return nil, pos + 1
end

function json.decode(str)
  local val, _ = parse_value(str, 1)
  return val
end

-- ==========================================
-- Resolve hormony working directory
-- ==========================================
local function resolveHormonyDir()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME")
  if home then
    home = home:gsub("\\", "/")
    if home:sub(-1) ~= "/" then home = home .. "/" end
    return home .. "Documents/Dreamtonics/Synthesizer V Studio/hormony/"
  end
  local ok, proj = pcall(function() return SV:getProject() end)
  if ok and proj then
    local svpPath = proj:getFileName()
    if svpPath and svpPath ~= "" then
      svpPath = svpPath:gsub("\\", "/")
      local dir = svpPath:match("^(.+/)")
      if dir then return dir .. "hormony/" end
    end
  end
  return "D:/hormony/"
end

local HORMONY_DIR = resolveHormonyDir()

-- ==========================================
-- Ensure directory exists
-- ==========================================
local function ensureHormonyDir()
  local testPath = HORMONY_DIR .. ".hormony_test"
  local f = io.open(testPath, "w")
  if f then
    f:write("")
    f:close()
    os.remove(testPath)
    return true
  end
  local ok = os.execute('mkdir "' .. HORMONY_DIR:gsub("/", "\\") .. '" 2>nul')
  if ok then
    f = io.open(testPath, "w")
    if f then
      f:write("")
      f:close()
      os.remove(testPath)
      return true
    end
  end
  return false
end

-- ==========================================
-- Config file read/write
-- ==========================================
local CONFIG_FILE_PATH = HORMONY_DIR .. "Hormony_Config.json"

-- Interval options (must match the runtime script)
local INTERVAL_OPTIONS = {
  { label = "15s",  ms = 15000 },
  { label = "5s",   ms = 5000 },
  { label = "3s",   ms = 3000 },
  { label = "1s",   ms = 1000 },
  { label = "0.5s", ms = 500 },
}

-- Default config values
local DEFAULT_CONFIG = {
  interval = 1000,        -- ms
  hormonyDir = HORMONY_DIR,
  scriptVersion = SCRIPT_VERSION,
}

local function readConfig()
  local f = io.open(CONFIG_FILE_PATH, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return nil end
  local ok, data = pcall(function() return json.decode(content) end)
  if ok and type(data) == "table" then return data end
  return nil
end

local function writeConfig(cfg)
  local dirOk = ensureHormonyDir()
  if not dirOk then return false end
  local f = io.open(CONFIG_FILE_PATH, "w")
  if not f then return false end
  f:write(json.encode(cfg))
  f:close()
  return true
end

-- ==========================================
-- Main: Settings UI
-- ==========================================
function main()
  local dirOk = ensureHormonyDir()
  if not dirOk then
    SV:showMessageBox("Error",
      "Cannot access hormony working directory:\n" .. HORMONY_DIR
      .. "\n\nPlease create this directory manually and try again.")
    SV:finish()
    return
  end

  -- Load existing config or use defaults
  local cfg = readConfig() or {}
  local currentInterval = cfg.interval or DEFAULT_CONFIG.interval
  local currentDir = cfg.hormonyDir or DEFAULT_CONFIG.hormonyDir

  -- Find the matching interval index for the ComboBox default
  local intervalDefault = 3  -- fallback to "1s" (index 3, 0-based)
  for idx, opt in ipairs(INTERVAL_OPTIONS) do
    if opt.ms == currentInterval then
      intervalDefault = idx - 1  -- 0-based
      break
    end
  end

  -- Build interval choice labels
  local intervalChoices = {}
  for _, opt in ipairs(INTERVAL_OPTIONS) do
    table.insert(intervalChoices, opt.label)
  end

  local form = {
    title = SV:T("Hormony Settings"),
    message = "Hormony v" .. SCRIPT_VERSION
      .. "\n\nConfigure the Hormony bridge runtime parameters."
      .. "\nThese settings are saved to Hormony_Config.json and read by the bridge script."
      .. "\n\nCurrent config file: " .. CONFIG_FILE_PATH
      .. "\n\n[i] Loop Mode uses read/write alternating: full cycle = 2 x interval."
      .. "\n    For large projects, use 3s or slower.",
    buttons = "OkCancel",
    widgets = {
      {
        name = "interval",
        type = "ComboBox",
        label = SV:T("Update Interval"),
        choices = intervalChoices,
        default = intervalDefault
      },
      {
        name = "hormonyDir",
        type = "TextBox",
        label = SV:T("Working Directory"),
        default = currentDir
      },
    }
  }

  local results = SV:showCustomDialog(form)
  if results.status then
    -- Read user choices
    local intervalIdx = results.answers.interval + 1  -- 0-based -> 1-based
    local newInterval = DEFAULT_CONFIG.interval
    if INTERVAL_OPTIONS[intervalIdx] then
      newInterval = INTERVAL_OPTIONS[intervalIdx].ms
    end

    local newDir = results.answers.hormonyDir or currentDir
    -- Normalize directory path
    newDir = newDir:gsub("\\", "/")
    if newDir:sub(-1) ~= "/" then newDir = newDir .. "/" end

    -- Build and save config
    local newCfg = {
      interval = newInterval,
      hormonyDir = newDir,
      scriptVersion = SCRIPT_VERSION,
    }

    local ok = writeConfig(newCfg)
    if ok then
      SV:showMessageBox(SV:T("Hormony Settings"), SV:T("Settings saved."))
    else
      SV:showMessageBox("Error", "Failed to write config file:\n" .. CONFIG_FILE_PATH)
    end
  end

  SV:finish()
end
