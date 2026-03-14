-- HarmonySettings.lua
-- Harmony API -- Settings UI
-- Persists configuration to Harmony_Config.json in the Harmony working directory.
-- The runtime bridge script (HarmonyBridge.lua) reads this config on start.

local SCRIPT_VERSION = "0.4.0"

function getClientInfo()
  return {
    name = SV:T("Harmony Settings"),
    author = "Wuyilingwei",
    versionNumber = 1,
    minEditorVersion = 65537
  }
end

function getTranslations(langCode)
  if langCode == "zh-cn" then
    return {
      {"Harmony Settings", "Harmony 设置"},
      {"Settings saved.", "设置已保存。"},
      {"Update Interval", "更新间隔"},
      {"Working Directory", "工作目录"},
      {"Work Mode", "工作模式"},
      {"Full (Export + Import)", "全工 (导出 + 导入)"},
      {"Export Only", "仅导出"},
      {"Import Only", "仅导入"},
      {"Clean Sessions", "清理会话"},
      {"Sessions cleaned.", "会话已清理。"},
      {"No sessions to clean.", "没有需要清理的会话。"},
      {"Cannot get system time. Session cleanup skipped.", "无法获取系统时间，跳过会话清理。"},
      {"Removed sessions: ", "已移除会话: "},
      {"Removed orphan file groups: ", "已移除孤立文件组: "},
      {"Configure the Harmony bridge runtime parameters.", "配置 Harmony 桥接运行参数。"},
      {"These settings are saved to Harmony_Config.json and read by the bridge script.", "这些设置保存在 Harmony_Config.json 中，由桥接脚本读取。"},
      {"Full mode uses read/write alternating: full cycle = 2 x interval. For large projects, use 3s or slower.", "全工模式使用读/写交替：完整周期 = 2 × 间隔。对于大型项目，建议使用 3 秒或更慢的间隔。"},
      {"Use Export Only / Import Only only if your external script requires it or you know exactly what you are doing. Default should be Full.", "仅在外部脚本需要时才使用「仅导出」/「仅导入」，\n    或者你清楚自己在做什么。默认应使用「全工」模式。"},
      {"Cannot access Harmony working directory:", "无法访问 Harmony 工作目录："},
      {"Please create this directory manually and try again.", "请手动创建该目录后重试。"},
      {"Failed to write config file:", "无法写入配置文件："},
      {"Error", "错误"},
      {"Config: ", "配置文件："},
      {"Sessions: ", "会话数："},
      {" session(s) in Harmony_Session.json", " 个会话记录于 Harmony_Session.json"},
      {"End Detection Silence", "结尾检测静默"},
      {"End Detection Silence: if no notes exist for this duration after the last note, the export range stops there.", "结尾检测静默：若最后一个音符之后超过此时长没有音符，则导出范围到此为止。"},
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

-- json.encode(val [, indent [, _depth]])
function json.encode(val, indent, _depth)
  indent = indent or 0
  _depth = _depth or 0
  local pretty = indent > 0
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
    local child_depth = _depth + 1
    local cur_indent = pretty and string.rep(" ", indent * _depth) or ""
    local child_indent = pretty and string.rep(" ", indent * child_depth) or ""
    local nl = pretty and "\n" or ""
    local sep = pretty and ",\n" or ","
    local kv_sep = pretty and ": " or ":"

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
          table.insert(parts, child_indent .. "null")
        else
          table.insert(parts, child_indent .. json.encode(val[i], indent, child_depth))
        end
      end
      return "[" .. nl .. table.concat(parts, sep) .. nl .. cur_indent .. "]"
    elseif next(val) == nil then
      return "[]"
    else
      local parts = {}
      for k, v in pairs(val) do
        if type(k) == "string" then
          table.insert(parts, child_indent .. '"' .. escape_str(k) .. '"' .. kv_sep .. json.encode(v, indent, child_depth))
        end
      end
      if #parts == 0 then return "{}" end
      return "{" .. nl .. table.concat(parts, sep) .. nl .. cur_indent .. "}"
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
-- Resolve Harmony working directory
-- ==========================================
local function resolveHarmonyDir()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME")
  if home then
    home = home:gsub("\\", "/")
    if home:sub(-1) ~= "/" then home = home .. "/" end
    return home .. "Documents/Dreamtonics/Synthesizer V Studio/Harmony/"
  end
  local ok, proj = pcall(function() return SV:getProject() end)
  if ok and proj then
    local svpPath = proj:getFileName()
    if svpPath and svpPath ~= "" then
      svpPath = svpPath:gsub("\\", "/")
      local dir = svpPath:match("^(.+/)")
      if dir then return dir .. "Harmony/" end
    end
  end
  return "D:/Harmony/"
end

local Harmony_DIR = resolveHarmonyDir()

-- ==========================================
-- Ensure directory exists
-- ==========================================
local function ensureHarmonyDir()
  local testPath = Harmony_DIR .. ".Harmony_test"
  local f = io.open(testPath, "w")
  if f then
    f:write("")
    f:close()
    os.remove(testPath)
    return true
  end
  local ok = os.execute('mkdir "' .. Harmony_DIR:gsub("/", "\\") .. '" 2>nul')
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
local CONFIG_FILE_PATH = Harmony_DIR .. "Harmony_Config.json"
local SESSION_FILE_PATH = Harmony_DIR .. "Harmony_Session.json"

-- Interval options (must match the runtime script)
local INTERVAL_OPTIONS = {
  { label = "15s",  ms = 15000 },
  { label = "5s",   ms = 5000 },
  { label = "3s",   ms = 3000 },
  { label = "1s",   ms = 1000 },
  { label = "0.5s", ms = 500 },
}

-- Work mode options
local WORK_MODE_OPTIONS = {
  { label = "Full (Export + Import)", value = "full" },
  { label = "Export Only",           value = "export" },
  { label = "Import Only",          value = "import" },
}

-- End detection silence options (seconds)
local END_DETECT_OPTIONS = {
  { label = "15s",  sec = 15 },
  { label = "30s",  sec = 30 },
  { label = "60s",  sec = 60 },
  { label = "120s", sec = 120 },
}

-- Default config values
local DEFAULT_CONFIG = {
  interval = 3000,
  HarmonyDir = Harmony_DIR,
  workMode = "full",
  scriptVersion = SCRIPT_VERSION,
  endDetectSec = 30,
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
  local dirOk = ensureHarmonyDir()
  if not dirOk then return false end
  local f = io.open(CONFIG_FILE_PATH, "w")
  if not f then return false end
  f:write(json.encode(cfg, 2))
  f:close()
  return true
end

-- ==========================================
-- Session cleanup
-- Rules:
--   1. state == "stopped" → remove session + delete bridge files
--   2. state == "running" and no heartbeat for > 60s → remove (dead process) + delete bridge files
--   3. After removing sessions, scan Harmony dir for *_out.json / *_in.json
--      not claimed by any surviving session → delete those orphan files
-- ==========================================
local function getTimestamp()
  local ok, t = pcall(os.time)
  if ok and t then return t end
  return 0
end

local function readSessionFile()
  local f = io.open(SESSION_FILE_PATH, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return {} end
  local ok, data = pcall(function() return json.decode(content) end)
  if ok and type(data) == "table" then return data end
  return {}
end

local function writeSessionFile(sessions)
  local f = io.open(SESSION_FILE_PATH, "w")
  if not f then return false end
  f:write(json.encode(sessions, 2))
  f:close()
  return true
end

-- Delete bridge files for a session
local function deleteBridgeFiles(s)
  if s.sessionId then
    local outPath = Harmony_DIR .. s.sessionId .. "_out.json"
    local inPath  = Harmony_DIR .. s.sessionId .. "_in.json"
    os.remove(outPath)
    os.remove(inPath)
  end
end

-- List all *_out.json and *_in.json files in Harmony dir
-- Returns a table of { uuid = true } for each uuid found
local function listBridgeFileUUIDs()
  local uuids = {}
  -- Use dir command to list files (Windows)
  local dirPath = Harmony_DIR:gsub("/", "\\")
  local cmd = 'dir /b "' .. dirPath .. '" 2>nul'
  local pipe = io.popen(cmd)
  if not pipe then return uuids end
  for line in pipe:lines() do
    -- Match {uuid}_out.json or {uuid}_in.json
    local uuid = line:match("^(.+)_out%.json$") or line:match("^(.+)_in%.json$")
    if uuid then
      uuids[uuid] = true
    end
  end
  pipe:close()
  return uuids
end

local function cleanSessions()
  local sessions = readSessionFile()
  local now = getTimestamp()
  if now == 0 then return -1, 0 end -- cannot get time

  -- Phase 1: clean sessions
  local cleaned = {}
  local removedSessions = 0
  for _, s in ipairs(sessions) do
    local dominated = false
    if s.state == "stopped" then
      dominated = true
    elseif s.state == "running" then
      local age = now - (s.timestamp or 0)
      if age > 60 then
        dominated = true
      end
    end
    if dominated then
      deleteBridgeFiles(s)
      removedSessions = removedSessions + 1
    else
      table.insert(cleaned, s)
    end
  end

  if removedSessions > 0 then
    writeSessionFile(cleaned)
  end

  -- Phase 2: scan for orphan bridge files not claimed by any surviving session
  local knownUUIDs = {}
  for _, s in ipairs(cleaned) do
    if s.sessionId then
      knownUUIDs[s.sessionId] = true
    end
  end

  local fileUUIDs = listBridgeFileUUIDs()
  local removedFiles = 0
  for uuid, _ in pairs(fileUUIDs) do
    if not knownUUIDs[uuid] then
      local outPath = Harmony_DIR .. uuid .. "_out.json"
      local inPath  = Harmony_DIR .. uuid .. "_in.json"
      os.remove(outPath)
      os.remove(inPath)
      removedFiles = removedFiles + 1
    end
  end

  return removedSessions, removedFiles
end

-- ==========================================
-- Main: Settings UI
-- ==========================================
function main()
  local dirOk = ensureHarmonyDir()
  if not dirOk then
    SV:showMessageBox(SV:T("Error"),
      SV:T("Cannot access Harmony working directory:") .. "\n" .. Harmony_DIR
      .. "\n\n" .. SV:T("Please create this directory manually and try again."))
    SV:finish()
    return
  end

  -- Load existing config or use defaults
  local cfg = readConfig() or {}
  local currentInterval = cfg.interval or DEFAULT_CONFIG.interval
  local currentDir = cfg.HarmonyDir or DEFAULT_CONFIG.HarmonyDir
  local currentWorkMode = cfg.workMode or DEFAULT_CONFIG.workMode
  local currentEndDetect = cfg.endDetectSec or DEFAULT_CONFIG.endDetectSec

  -- Find the matching interval index for the ComboBox default
  local intervalDefault = 3  -- fallback to "1s" (index 3, 0-based)
  for idx, opt in ipairs(INTERVAL_OPTIONS) do
    if opt.ms == currentInterval then
      intervalDefault = idx - 1
      break
    end
  end

  -- Find the matching work mode index
  local workModeDefault = 0  -- fallback to "full"
  for idx, opt in ipairs(WORK_MODE_OPTIONS) do
    if opt.value == currentWorkMode then
      workModeDefault = idx - 1
      break
    end
  end

  -- Build choice labels
  local intervalChoices = {}
  for _, opt in ipairs(INTERVAL_OPTIONS) do
    table.insert(intervalChoices, opt.label)
  end

  local workModeChoices = {}
  for _, opt in ipairs(WORK_MODE_OPTIONS) do
    table.insert(workModeChoices, SV:T(opt.label))
  end

  local endDetectDefault = 1
  for idx, opt in ipairs(END_DETECT_OPTIONS) do
    if opt.sec == currentEndDetect then
      endDetectDefault = idx - 1
      break
    end
  end

  local endDetectChoices = {}
  for _, opt in ipairs(END_DETECT_OPTIONS) do
    table.insert(endDetectChoices, opt.label)
  end

  -- Count current sessions for display
  local sessions = readSessionFile()
  local sessionInfo = #sessions .. SV:T(" session(s) in Harmony_Session.json")

  local form = {
    title = SV:T("Harmony Settings"),
    message = "Harmony API v" .. SCRIPT_VERSION
      .. "\n\n" .. SV:T("Configure the Harmony bridge runtime parameters.")
      .. "\n" .. SV:T("These settings are saved to Harmony_Config.json and read by the bridge script.")
      .. "\n\n" .. SV:T("Config: ") .. CONFIG_FILE_PATH
      .. "\n" .. SV:T("Sessions: ") .. sessionInfo
      .. "\n\n" .. SV:T("Full mode uses read/write alternating: full cycle = 2 x interval. For large projects, use 3s or slower.")
      .. "\n\n" .. SV:T("Use Export Only / Import Only only if your external script requires it or you know exactly what you are doing. Default should be Full.")
      .. "\n\n" .. SV:T("End Detection Silence: if no notes exist for this duration after the last note, the export range stops there."),
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
        name = "workMode",
        type = "ComboBox",
        label = SV:T("Work Mode"),
        choices = workModeChoices,
        default = workModeDefault
      },
      {
        name = "endDetectSec",
        type = "ComboBox",
        label = SV:T("End Detection Silence"),
        choices = endDetectChoices,
        default = endDetectDefault
      },
      {
        name = "HarmonyDir",
        type = "TextBox",
        label = SV:T("Working Directory"),
        default = currentDir
      },
      {
        name = "cleanSessions",
        type = "CheckBox",
        text = SV:T("Clean Sessions"),
        default = false
      },
    }
  }

  local results = SV:showCustomDialog(form)
  if results.status then
    -- Read user choices
    local intervalIdx = results.answers.interval + 1
    local newInterval = DEFAULT_CONFIG.interval
    if INTERVAL_OPTIONS[intervalIdx] then
      newInterval = INTERVAL_OPTIONS[intervalIdx].ms
    end

    local workModeIdx = results.answers.workMode + 1
    local newWorkMode = DEFAULT_CONFIG.workMode
    if WORK_MODE_OPTIONS[workModeIdx] then
      newWorkMode = WORK_MODE_OPTIONS[workModeIdx].value
    end

    local newDir = results.answers.HarmonyDir or currentDir
    newDir = newDir:gsub("\\", "/")
    if newDir:sub(-1) ~= "/" then newDir = newDir .. "/" end

    local endDetectIdx = results.answers.endDetectSec + 1
    local newEndDetect = DEFAULT_CONFIG.endDetectSec
    if END_DETECT_OPTIONS[endDetectIdx] then
      newEndDetect = END_DETECT_OPTIONS[endDetectIdx].sec
    end

    local newCfg = {
      interval = newInterval,
      HarmonyDir = newDir,
      workMode = newWorkMode,
      scriptVersion = SCRIPT_VERSION,
      endDetectSec = newEndDetect,
    }

    local ok = writeConfig(newCfg)
    if not ok then
      SV:showMessageBox(SV:T("Error"), SV:T("Failed to write config file:") .. "\n" .. CONFIG_FILE_PATH)
    end

    -- Clean sessions if requested
    if results.answers.cleanSessions then
      local removedSessions, removedFiles = cleanSessions()
      if removedSessions < 0 then
        SV:showMessageBox(SV:T("Clean Sessions"),
          SV:T("Cannot get system time. Session cleanup skipped."))
      elseif removedSessions == 0 and removedFiles == 0 then
        SV:showMessageBox(SV:T("Clean Sessions"), SV:T("No sessions to clean."))
      else
        local msg = SV:T("Sessions cleaned.")
        if removedSessions > 0 then
          msg = msg .. "\n" .. SV:T("Removed sessions: ") .. removedSessions
        end
        if removedFiles > 0 then
          msg = msg .. "\n" .. SV:T("Removed orphan file groups: ") .. removedFiles
        end
        SV:showMessageBox(SV:T("Clean Sessions"), msg)
      end
    end
  end

  SV:finish()
end
