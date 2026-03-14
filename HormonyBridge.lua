-- HormonyBridge.lua
-- Hormony API — JSON Loop Bridge
-- Pure runtime script: starts the loop on click, runs until SV stops scripts.
-- No UI dialogs. Reads config from Hormony_Config.json (written by HormonySettings.lua).
-- Supports work modes: full (export+import), export only, import only.

function getClientInfo()
  return {
    name = SV:T("Hormony Bridge"),
    author = "Wuyilingwei",
    versionNumber = 1,
    minEditorVersion = 65537
  }
end

function getTranslations(langCode)
  if langCode == "zh-cn" then
    return {
      {"Hormony Bridge", "Hormony 桥接"},
    }
  end
  return {}
end

-- ==========================================
-- 纯 Lua JSON 解析与序列化 (迷你版)
-- ==========================================
local json = {}

-- 标记表：用于区分空对象 {} 和空数组 []
-- Lua 中空表无法区分，需要额外标记
local EMPTY_OBJECT_MARKER = "__json_empty_object__"

-- 创建一个会被序列化为 {} 的空表
local function emptyObject()
  return { [EMPTY_OBJECT_MARKER] = true }
end

-- 创建一个会被序列化为 [] 的空表 (默认)
local function emptyArray()
  return {}
end

local function escape_str(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  -- 非 ASCII 字符转为 \uXXXX（官方 .svp 格式使用 Unicode 转义）
  s = s:gsub('[\xc0-\xff][\x80-\xbf]*', function(c)
    -- UTF-8 解码为 Unicode 码点
    local bytes = { string.byte(c, 1, #c) }
    local code
    if #bytes == 2 then
      code = (bytes[1] - 192) * 64 + (bytes[2] - 128)
    elseif #bytes == 3 then
      code = (bytes[1] - 224) * 4096 + (bytes[2] - 128) * 64 + (bytes[3] - 128)
    elseif #bytes == 4 then
      code = (bytes[1] - 240) * 262144 + (bytes[2] - 128) * 4096 + (bytes[3] - 128) * 64 + (bytes[4] - 128)
    else
      return c -- 无法解码，原样返回
    end
    if code and code <= 0xFFFF then
      return string.format("\\u%04x", code)
    elseif code then
      -- 代理对 (surrogate pair) 处理 BMP 之外的字符
      code = code - 0x10000
      local hi = 0xD800 + math.floor(code / 1024)
      local lo = 0xDC00 + (code % 1024)
      return string.format("\\u%04x\\u%04x", hi, lo)
    end
    return c
  end)
  return s
end

-- 浮点数包装：标记某个数值应当强制输出为浮点格式（带小数点）
-- Lua 中 0.0 == 0 为 true，无法区分整数和浮点，需要此标记
local FLOAT_MARKER = "__json_float__"
local function float(v)
  return { [FLOAT_MARKER] = v }
end

-- json.encode(val [, indent [, _depth]])
-- indent: 缩进空格数（nil 或 0 表示紧凑模式，>0 表示松散/pretty 模式）
-- _depth: 内部递归深度，外部调用时不要传
function json.encode(val, indent, _depth)
  indent = indent or 0
  _depth = _depth or 0
  local pretty = indent > 0
  local t = type(val)
  if t == "number" then
    -- 使用高精度格式化，%.16g 提供 16 位有效数字
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
    -- 检查是否为浮点数标记
    if val[FLOAT_MARKER] ~= nil then
      local fv = val[FLOAT_MARKER]
      local s = string.format("%.16g", fv)
      -- 确保有小数点（如 0.0 而非 0）
      if not s:find("%.") and not s:find("[eE]") then
        s = s .. ".0"
      end
      return s
    end
    
    -- 检查是否标记为空对象
    if val[EMPTY_OBJECT_MARKER] then
      return "{}"
    end
    
    local child_depth = _depth + 1
    local cur_indent = pretty and string.rep(" ", indent * _depth) or ""
    local child_indent = pretty and string.rep(" ", indent * child_depth) or ""
    local nl = pretty and "\n" or ""
    local sep = pretty and ",\n" or ","
    local kv_sep = pretty and ": " or ":"
    
    -- 检查是否为有序键表（通过 __key_order 元数据）
    local key_order = val["__key_order__"]
    if key_order then
      local parts = {}
      local used = { __key_order__ = true }
      for _, k in ipairs(key_order) do
        if val[k] ~= nil then
          table.insert(parts, child_indent .. '"' .. escape_str(k) .. '"' .. kv_sep .. json.encode(val[k], indent, child_depth))
          used[k] = true
        end
      end
      for k, v in pairs(val) do
        if type(k) == "string" and not used[k] then
          table.insert(parts, child_indent .. '"' .. escape_str(k) .. '"' .. kv_sep .. json.encode(v, indent, child_depth))
        end
      end
      if #parts == 0 then return "{}" end
      return "{" .. nl .. table.concat(parts, sep) .. nl .. cur_indent .. "}"
    end
    
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
      return "[]"  -- 默认空表为空数组
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
  else
    return '"<unsupported>"'
  end
end

-- 简易 JSON 解析（应对外部发来的合法 JSON）
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
        elseif ec == 'u' then
          -- \uXXXX Unicode escape
          local hex4 = str:sub(pos + 1, pos + 4)
          pos = pos + 4
          local code = tonumber(hex4, 16)
          if code then
            -- Check for surrogate pair
            if code >= 0xD800 and code <= 0xDBFF then
              -- High surrogate, expect \uXXXX low surrogate
              if str:sub(pos + 1, pos + 2) == "\\u" then
                local hex4lo = str:sub(pos + 3, pos + 6)
                local lo = tonumber(hex4lo, 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                  pos = pos + 6
                  code = 0x10000 + (code - 0xD800) * 1024 + (lo - 0xDC00)
                end
              end
            end
            -- Encode Unicode codepoint to UTF-8
            if code <= 0x7F then
              s = s .. string.char(code)
            elseif code <= 0x7FF then
              s = s .. string.char(192 + math.floor(code / 64), 128 + (code % 64))
            elseif code <= 0xFFFF then
              s = s .. string.char(224 + math.floor(code / 4096),
                                   128 + math.floor(code / 64) % 64,
                                   128 + (code % 64))
            elseif code <= 0x10FFFF then
              s = s .. string.char(240 + math.floor(code / 262144),
                                   128 + math.floor(code / 4096) % 64,
                                   128 + math.floor(code / 64) % 64,
                                   128 + (code % 64))
            end
          end
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
-- Global state & configuration
-- ==========================================
local isLoopModeActive = false
local loopInterval = 1000 -- default, overridden by Hormony_Config.json
local lastImportedContents = ""
local SCRIPT_VERSION = "0.3.0"

-- 结尾检测：超过此秒数没有音符则认定文件已结束
-- 可通过 Hormony_Config.json 的 endDetectSec 字段覆盖
local endDetectSec = 30

-- Dynamically resolve hormony working directory
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
local SESSION_FILE_PATH = HORMONY_DIR .. "Hormony_Session.json"
local CONFIG_FILE_PATH  = HORMONY_DIR .. "Hormony_Config.json"
local LOCK_FILE_PATH    = HORMONY_DIR .. "Hormony_Lock.json"
local currentSessionId = nil
local workMode = "full" -- "full", "export", "import"
local paramTypeNames = {
  "pitchDelta", "vibratoEnv", "loudness", "tension",
  "breathiness", "voicing", "gender", "toneShift"
}

-- Read config from Hormony_Config.json (written by HormonySettings.lua)
-- Returns a table with at least { interval, hormonyDir } or defaults
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

-- ==========================================
-- 工具函数：时间戳 与 UUIDv4
-- ==========================================

-- 获取 Unix 时间戳（秒），os.time 在 SV Lua 环境中可能不可用
local function getTimestamp()
  local ok, t = pcall(os.time)
  if ok and t then return t end
  -- 最终后备：返回 0（功能降级但不崩溃）
  return 0
end

-- 生成 UUIDv4（纯 Lua，使用 math.random）
-- 格式: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
local uuidSeeded = false
local function generateUUIDv4()
  if not uuidSeeded then
    -- 用时间戳 + os.clock 混合做种子
    local seed = getTimestamp()
    local okClock, clk = pcall(os.clock)
    if okClock and clk then
      seed = seed + math.floor(clk * 1000000)
    end
    math.randomseed(seed)
    uuidSeeded = true
  end

  local hex = "0123456789abcdef"
  local function rh() local i = math.random(1, 16); return hex:sub(i, i) end

  -- xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  local parts = {}
  for i = 1, 8 do parts[#parts+1] = rh() end
  parts[#parts+1] = "-"
  for i = 1, 4 do parts[#parts+1] = rh() end
  parts[#parts+1] = "-4"
  for i = 1, 3 do parts[#parts+1] = rh() end
  parts[#parts+1] = "-"
  -- y 位: 8, 9, a, b 中随机选一个
  local yChars = {"8","9","a","b"}
  parts[#parts+1] = yChars[math.random(1,4)]
  for i = 1, 3 do parts[#parts+1] = rh() end
  parts[#parts+1] = "-"
  for i = 1, 12 do parts[#parts+1] = rh() end

  return table.concat(parts)
end

-- ==========================================
-- hormony 工作目录与 bridge 路径
-- ==========================================

-- 确保 hormony 工作目录存在（自动创建）
-- 返回 true 表示目录可用，false 表示无法创建/写入
local function ensureHormonyDir()
  -- 先测试目录是否已可用
  local testPath = HORMONY_DIR .. ".hormony_test"
  local f = io.open(testPath, "w")
  if f then
    f:write("")
    f:close()
    os.remove(testPath)
    return true
  end
  -- 目录不存在，尝试自动创建
  local ok = os.execute('mkdir "' .. HORMONY_DIR:gsub("/", "\\") .. '" 2>nul')
  if ok then
    -- 再次验证
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

-- 根据 UUID 生成 bridge 文件路径
-- uuid: 会话 UUID
-- 返回两个路径: outPath (SV -> 外部), inPath (外部 -> SV)
local function getBridgePaths(uuid)
  local outPath = HORMONY_DIR .. uuid .. "_out.json"
  local inPath  = HORMONY_DIR .. uuid .. "_in.json"
  return outPath, inPath
end

-- ==========================================
-- Hormony_Session 管理
-- 文件位置: hormony/Hormony_Session.json
-- 格式: JSON 数组，每个元素为一个 session 记录
-- ==========================================

-- session 记录的标准字段顺序
local SESSION_KEY_ORDER = {
  "svVersion", "scriptVersion", "sessionId",
  "svpFilePath", "hormonyDir", "bridgeOutPath", "bridgeInPath",
  "timestamp", "state"
}

-- 为从 JSON 解析回来的 session 记录重新附加 __key_order__
local function ensureSessionOrdered(s)
  if s and type(s) == "table" and not s["__key_order__"] then
    s["__key_order__"] = SESSION_KEY_ORDER
  end
  return s
end

-- 读取 session 文件，返回 sessions 数组（可能为空）
local function readSessionFile()
  local f = io.open(SESSION_FILE_PATH, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return {} end
  local ok, data = pcall(function() return json.decode(content) end)
  if ok and type(data) == "table" then
    -- 为每条 session 记录重新附加字段顺序
    for _, s in ipairs(data) do
      ensureSessionOrdered(s)
    end
    return data
  end
  return {}
end

-- 写入 session 文件
local function writeSessionFile(sessions)
  local f = io.open(SESSION_FILE_PATH, "w")
  if not f then return false end
  f:write(json.encode(sessions, 2))
  f:close()
  return true
end

-- ==========================================
-- 锁文件：Hormony_Lock.json
-- 格式: { "sessionId": "uuid", "timestamp": 123456 }
-- 用于"同一编辑器只允许一个桥接实例"的开关检测
-- ==========================================

local function readLockFile()
  local f = io.open(LOCK_FILE_PATH, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return nil end
  local ok, data = pcall(function() return json.decode(content) end)
  if ok and type(data) == "table" then return data end
  return nil
end

local function writeLockFile(sessionId)
  local f = io.open(LOCK_FILE_PATH, "w")
  if not f then return false end
  f:write('{\n  "sessionId": "' .. sessionId .. '",\n  "timestamp": ' .. getTimestamp() .. '\n}')
  f:close()
  return true
end

local function deleteLockFile()
  os.remove(LOCK_FILE_PATH)
end

-- 检查锁文件是否属于自己的 session（用于 loopTick 判断是否继续）
local function lockBelongsToMe(sessionId)
  local lock = readLockFile()
  if not lock then return false end
  return lock.sessionId == sessionId
end

-- 清理过期 session
-- 规则:
--   state == "stopped" → 直接删除
--   state == "running" 且 timestamp 距今 > 60 秒 → 删除（说明进程已死）
local function cleanupSessions(sessions)
  local now = getTimestamp()
  if now == 0 then return sessions end  -- 无法获取时间，跳过清理

  local cleaned = {}
  for _, s in ipairs(sessions) do
    if s.state == "stopped" then
      -- 跳过（删除）：已停止的 session
    elseif s.state == "running" and (now - (s.timestamp or 0)) > 60 then
      -- 跳过（删除）：running 状态但超过 1 分钟没更新
    else
      table.insert(cleaned, s)
    end
  end
  return cleaned
end

-- 获取 SV 编辑器版本字符串
local function getSVVersion()
  local ok, info = pcall(function() return SV:getHostInfo() end)
  if ok and info then
    -- 优先使用 hostVersion 字符串（如 "1.11.2"）
    if info.hostVersion then
      return info.hostVersion
    end
    -- 回退：从 hostVersionNumber 解析
    local vn = info.hostVersionNumber
    if vn then
      return string.format("%d.%d.%d",
        math.floor(vn / 65536),
        math.floor(vn / 256) % 256,
        vn % 256)
    end
  end
  return "unknown"
end

-- 注册新 session（Loop Mode 启动时调用）
-- 返回 uuid, outPath, inPath
local function registerSession()
  local sessions = readSessionFile()
  sessions = cleanupSessions(sessions)

  local uuid = generateUUIDv4()
  local outPath, inPath = getBridgePaths(uuid)
  local projPath = SV:getProject():getFileName()

  local session = {
    __key_order__ = SESSION_KEY_ORDER,
    svVersion     = getSVVersion(),
    scriptVersion = SCRIPT_VERSION,
    sessionId     = uuid,
    svpFilePath   = projPath,
    hormonyDir    = HORMONY_DIR,
    bridgeOutPath = outPath,
    bridgeInPath  = inPath,
    timestamp     = getTimestamp(),
    state         = "running"
  }

  table.insert(sessions, session)
  writeSessionFile(sessions)
  return uuid, outPath, inPath
end

-- 更新当前 session 的时间戳（每次 loopTick 时调用）
local function updateSessionTimestamp(sessionId)
  if not sessionId then return end
  local sessions = readSessionFile()
  sessions = cleanupSessions(sessions)

  for _, s in ipairs(sessions) do
    if s.sessionId == sessionId then
      s.timestamp = getTimestamp()
      break
    end
  end
  writeSessionFile(sessions)
end

-- 更新当前 session 的 state（停止时调用）
local function updateSessionState(sessionId, newState)
  if not sessionId then return end
  local sessions = readSessionFile()

  for _, s in ipairs(sessions) do
    if s.sessionId == sessionId then
      s.state = newState
      s.timestamp = getTimestamp()
      break
    end
  end
  writeSessionFile(sessions)
end

-- ==========================================
-- 有序表构建辅助：创建带 __key_order__ 的有序对象
-- ==========================================
local function ordered(key_order, tbl)
  tbl["__key_order__"] = key_order
  return tbl
end

-- ==========================================
-- 核心功能 1: 提取编辑器模型数据
-- ==========================================

-- 构建单个音符数据（与官方 .svp 字段顺序一致）
local function buildNoteData(note)
  local hasAttrs, attrs = pcall(function() return note:getAttributes() end)
  if not hasAttrs or type(attrs) ~= "table" then attrs = {} end
  -- getAttributes() 返回的是包含 tF0Left/dF0Vbr 等的表
  -- 官方格式把它们分为 attributes 和 systemAttributes 两部分
  -- 这里通过 API 只能拿到合并后的属性表

  -- 官方 note.attributes 中常见的用户属性
  local userAttrs = ordered(
    {"evenSyllableDuration"},
    { evenSyllableDuration = (attrs.evenSyllableDuration == nil) and true or attrs.evenSyllableDuration }
  )

  -- 官方 note.systemAttributes 中的系统属性
  -- 所有系统属性值都是浮点数，需要用 float() 包装
  local tF0OffsetVal = attrs.tF0Offset or 0.0
  local tF0LeftVal   = attrs.tF0Left   or 0.1000000014901161
  local tF0RightVal  = attrs.tF0Right  or 0.1000000014901161
  local dF0LeftVal   = attrs.dF0Left   or 0.0
  local dF0RightVal  = attrs.dF0Right  or 0.0
  local dF0VbrVal    = attrs.dF0Vbr    or 0.0

  local sysAttrs = ordered(
    {"tF0Offset", "tF0Left", "tF0Right", "dF0Left", "dF0Right", "dF0Vbr", "evenSyllableDuration"},
    {
      tF0Offset  = float(tF0OffsetVal == 0 and -0.0 or tF0OffsetVal),
      tF0Left    = float(tF0LeftVal),
      tF0Right   = float(tF0RightVal),
      dF0Left    = float(dF0LeftVal),
      dF0Right   = float(dF0RightVal),
      dF0Vbr     = float(dF0VbrVal),
      evenSyllableDuration = (attrs.evenSyllableDuration == nil) and true or attrs.evenSyllableDuration
    }
  )

  -- 默认 pitchTakes / timbreTakes
  local defaultTakes = ordered(
    {"activeTakeId", "takes"},
    {
      activeTakeId = 0,
      takes = {
        ordered({"id", "expr", "liked"}, { id = 0, expr = float(0.0), liked = false })
      }
    }
  )
  local defaultTimbreTakes = ordered(
    {"activeTakeId", "takes"},
    {
      activeTakeId = 0,
      takes = {
        ordered({"id", "expr", "liked"}, { id = 0, expr = float(0.0), liked = false })
      }
    }
  )

  -- 读取音符的音乐类型
  local musicalType = "singing"
  local hasMusicalType, mt = pcall(function() return note:getMusicalType() end)
  if hasMusicalType and mt then
    if mt == "rap" then musicalType = "rap" end
  end

  -- 读取 accent
  local accent = ""
  local hasRapAccent, ra = pcall(function() return note:getRapAccent() end)
  if hasRapAccent and ra and ra ~= "" then
    accent = ra
  end

  -- 读取 detune
  local detune = 0
  local hasDetune, dt = pcall(function() return note:getDetune() end)
  if hasDetune and dt then
    detune = dt
  end

  return ordered(
    {"musicalType", "onset", "duration", "lyrics", "phonemes", "accent",
     "pitch", "detune", "instantMode", "attributes", "systemAttributes",
     "pitchTakes", "timbreTakes"},
    {
      musicalType = musicalType,
      onset       = note:getOnset(),
      duration    = note:getDuration(),
      lyrics      = note:getLyrics(),
      phonemes    = note:getPhonemes(),
      accent      = accent,
      pitch       = note:getPitch(),
      detune      = 0,
      instantMode = true,
      attributes       = userAttrs,
      systemAttributes = sysAttrs,
      pitchTakes       = defaultTakes,
      timbreTakes      = defaultTimbreTakes
    }
  )
end

-- 计算组内音符覆盖的 blick 范围，用于参数段获取
-- 返回 rangeMin, rangeMax（blick 单位）
-- rangeMin: 第一个音符 onset 前 1 拍（允许前置参数数据）
-- rangeMax: 最后一个音符 end + endDetectSec 对应的 blick 余量
local BLICK_PER_BEAT = 705600000

local function computeNoteRange(group)
  local numNotes = group:getNumNotes()
  if numNotes == 0 then
    return -BLICK_PER_BEAT, BLICK_PER_BEAT
  end

  local firstNote = group:getNote(1)
  local lastNote = group:getNote(numNotes)
  local rangeMin = firstNote:getOnset() - BLICK_PER_BEAT

  local lastEnd = lastNote:getOnset() + lastNote:getDuration()

  -- endDetectSec → blick: 保守估计使用 50 BPM（最慢常见曲速）
  -- 1 秒 @ 50 BPM = 50/60 拍 = 0.833.. 拍
  local gapBlicks = math.floor(endDetectSec * (50 / 60) * BLICK_PER_BEAT)
  local rangeMax = lastEnd + gapBlicks

  return rangeMin, rangeMax
end

-- 分段获取参数点：将大范围拆成多个段，逐段 getPoints 后拼接
-- 每段覆盖 SEGMENT_BEATS 拍，避免单次 API 调用处理过大范围
local SEGMENT_BEATS = 200
local SEGMENT_BLICKS = SEGMENT_BEATS * BLICK_PER_BEAT

local function getPointsSegmented(pAM, rangeMin, rangeMax)
  local allPoints = {}
  local segStart = rangeMin
  while segStart < rangeMax do
    local segEnd = segStart + SEGMENT_BLICKS
    if segEnd > rangeMax then segEnd = rangeMax end
    local points = pAM:getPoints(segStart, segEnd)
    for _, pt in ipairs(points) do
      table.insert(allPoints, pt)
    end
    segStart = segEnd
  end
  return allPoints
end

local function buildParametersData(group)
  local paramsData = ordered(
    {"pitchDelta", "vibratoEnv", "loudness", "tension",
     "breathiness", "voicing", "gender", "toneShift"},
    {}
  )

  local rangeMin, rangeMax = computeNoteRange(group)

  for _, paramType in ipairs(paramTypeNames) do
    local pAM = group:getParameter(paramType)
    local flattenedPoints = {}
    if pAM then
      local points = getPointsSegmented(pAM, rangeMin, rangeMax)
      for _, pt in ipairs(points) do
        table.insert(flattenedPoints, pt[1])
        table.insert(flattenedPoints, float(pt[2]))
      end
    end
    paramsData[paramType] = ordered(
      {"mode", "points"},
      { mode = "cubic", points = flattenedPoints }
    )
  end

  return paramsData
end

-- ==========================================
-- 从 .svp 文件读取补充数据（API 无法获取的字段）
-- 受限于脚本 API，声库信息(database)通过读取源 .svp 文件实现
-- systemPitchDelta 由引擎在加载时自动重新计算，导出时留空
-- ==========================================
local svpFileCache = nil  -- 缓存已解析的 .svp 数据，避免重复读取
local svpLoadError = ""   -- 记录读取失败原因，用于提示

local function loadSvpFile()
  if svpFileCache then return svpFileCache end

  local project = SV:getProject()
  if not project then
    svpLoadError = "project is nil"
    return nil
  end

  local svpPath = project:getFileName()
  if svpPath == "" then
    svpLoadError = "工程未保存，请先 Ctrl+S 保存工程"
    return nil
  end

  local f = io.open(svpPath, "r")
  if not f then
    svpLoadError = "无法打开 .svp 文件（可能是中文路径问题）:\n" .. svpPath
    return nil
  end

  local content = f:read("*a")
  f:close()

  if not content or content == "" then
    svpLoadError = ".svp 文件内容为空"
    return nil
  end

  local ok, data = pcall(function() return json.decode(content) end)
  if not ok or type(data) ~= "table" then
    svpLoadError = ".svp JSON 解析失败"
    return nil
  end

  svpLoadError = ""  -- 成功
  svpFileCache = data
  return data
end

-- 从 .svp 数据中查找指定轨道的 mainRef.database
-- trackIndex: 1-based 轨道索引
local function getSvpDatabase(trackIndex)
  local svp = loadSvpFile()
  if not svp or not svp.tracks then return nil end

  local track = svp.tracks[trackIndex]
  if not track or not track.mainRef then return nil end

  return track.mainRef.database
end

-- 从 .svp 数据中查找指定轨道的 mainRef.systemPitchDelta
local function getSvpSystemPitchDelta(trackIndex)
  local svp = loadSvpFile()
  if not svp or not svp.tracks then return nil end

  local track = svp.tracks[trackIndex]
  if not track or not track.mainRef then return nil end

  return track.mainRef.systemPitchDelta
end

-- 从 .svp 数据中读取顶层 version 字段
local function getSvpVersion()
  local svp = loadSvpFile()
  if svp and svp.version then return svp.version end
  return 153  -- 默认值
end

-- 从 .svp 数据中读取指定轨道字段
-- trackIndex: 1-based
-- field: 字段名 (如 "renderEnabled", "dispOrder")
-- default: 默认值
local function getSvpTrackField(trackIndex, field, default)
  local svp = loadSvpFile()
  if not svp or not svp.tracks then return default end
  local track = svp.tracks[trackIndex]
  if not track then return default end
  if track[field] ~= nil then return track[field] end
  return default
end

-- 从 .svp 数据中读取指定轨道的 mixer 字段
local function getSvpMixerField(trackIndex, field, default)
  local svp = loadSvpFile()
  if not svp or not svp.tracks then return default end
  local track = svp.tracks[trackIndex]
  if not track or not track.mixer then return default end
  if track.mixer[field] ~= nil then return track.mixer[field] end
  return default
end

-- 从 .svp 数据中读取 renderConfig
local function getSvpRenderConfig()
  local svp = loadSvpFile()
  if svp and svp.renderConfig then return svp.renderConfig end
  return nil
end

-- 构建 mainRef 数据
-- trackIndex: 1-based，用于从 .svp 文件读取 database / systemPitchDelta
local function buildMainRefData(groupRef, groupUUID, trackIndex)
  -- systemPitchDelta: 从 .svp 文件读取（引擎在加载时会自动重新计算）
  local sysPitchDelta = getSvpSystemPitchDelta(trackIndex)
  if not sysPitchDelta then
    sysPitchDelta = ordered({"mode", "points"}, { mode = "cubic", points = {} })
  else
    -- 从 .svp 读到的是普通 table，需要包装为 ordered + float
    local rawPoints = sysPitchDelta.points or (type(sysPitchDelta) == "table" and sysPitchDelta["points"]) or {}
    local wrappedPoints = {}
    for pi = 1, #rawPoints, 2 do
      table.insert(wrappedPoints, rawPoints[pi])       -- blick position (integer)
      table.insert(wrappedPoints, float(rawPoints[pi + 1] or 0))  -- delta value (float)
    end
    sysPitchDelta = ordered({"mode", "points"}, {
      mode = sysPitchDelta.mode or "cubic",
      points = wrappedPoints
    })
  end

  -- voice 信息：尝试从 groupRef:getVoice() 获取
  local voiceData = ordered(
    {"tF0Left", "vocalModeInherited", "vocalModePreset", "vocalModeParams"},
    {
      tF0Left = float(0.07000000029802322),
      vocalModeInherited = true,
      vocalModePreset = "",
      vocalModeParams = emptyObject()
    }
  )

  local hasGetVoice, voiceProps = pcall(function() return groupRef:getVoice() end)
  if hasGetVoice and voiceProps then
    if voiceProps.tF0Left then voiceData.tF0Left = float(voiceProps.tF0Left) end
    if voiceProps.vocalModeInherited ~= nil then voiceData.vocalModeInherited = voiceProps.vocalModeInherited end
    if voiceProps.vocalModePreset then voiceData.vocalModePreset = voiceProps.vocalModePreset end
    if voiceProps.vocalModeParams then voiceData.vocalModeParams = voiceProps.vocalModeParams end
  end

  -- database 信息：从 .svp 源文件读取（API 不提供此信息）
  local dbData = getSvpDatabase(trackIndex)
  if dbData then
    -- 从 .svp 读到的是普通 table，需要包装为 ordered
    dbData = ordered(
      {"name", "language", "phoneset", "languageOverride", "phonesetOverride", "backendType", "version"},
      {
        name              = dbData.name or "",
        language          = dbData.language or "",
        phoneset          = dbData.phoneset or "",
        languageOverride  = dbData.languageOverride or "",
        phonesetOverride  = dbData.phonesetOverride or "",
        backendType       = dbData.backendType or "",
        version           = dbData.version or ""
      }
    )
  else
    dbData = ordered(
      {"name", "language", "phoneset", "languageOverride", "phonesetOverride", "backendType", "version"},
      {
        name = "", language = "", phoneset = "",
        languageOverride = "", phonesetOverride = "",
        backendType = "", version = ""
      }
    )
  end

  local defaultRefTakes = ordered(
    {"activeTakeId", "takes"},
    {
      activeTakeId = 0,
      takes = {
        ordered({"id", "expr", "liked"}, { id = 0, expr = float(0.0), liked = false })
      }
    }
  )
  local defaultRefTimbreTakes = ordered(
    {"activeTakeId", "takes"},
    {
      activeTakeId = 0,
      takes = {
        ordered({"id", "expr", "liked"}, { id = 0, expr = float(0.0), liked = false })
      }
    }
  )

  return ordered(
    {"groupID", "blickAbsoluteBegin", "blickAbsoluteEnd", "blickOffset",
     "pitchOffset", "isInstrumental", "systemPitchDelta",
     "database", "dictionary", "voice", "pitchTakes", "timbreTakes"},
    {
      groupID            = groupUUID,
      blickAbsoluteBegin = 0,
      blickAbsoluteEnd   = -1,
      blickOffset        = groupRef:getTimeOffset(),
      pitchOffset        = groupRef:getPitchOffset(),
      isInstrumental     = (function()
        local ok, val = pcall(function() return groupRef:isInstrumental() end)
        return ok and val or false
      end)(),
      systemPitchDelta   = sysPitchDelta,
      database           = dbData,
      dictionary         = "",
      voice              = voiceData,
      pitchTakes         = defaultRefTakes,
      timbreTakes        = defaultRefTimbreTakes
    }
  )
end

local function buildOfficialLikeFromModel()
  local project = SV:getProject()
  if not project then return nil end

  -- 获取拍号（使用 pcall 防止 API 不存在时崩溃）
  local timeAxis = project:getTimeAxis()
  local meterList = {}
  local hasMeterAPI, meterMarks = pcall(function() return timeAxis:getAllMeasureMarks() end)
  if hasMeterAPI and type(meterMarks) == "table" and #meterMarks > 0 then
    for _, mark in ipairs(meterMarks) do
      table.insert(meterList, ordered(
        {"index", "numerator", "denominator"},
        { index = mark.position or 0, numerator = mark.numerator or 4, denominator = mark.denominator or 4 }
      ))
    end
  else
    table.insert(meterList, ordered(
      {"index", "numerator", "denominator"},
      { index = 0, numerator = 4, denominator = 4 }
    ))
  end

  -- 获取曲速（使用 pcall 防止 API 不存在时崩溃）
  local tempoList = {}
  local hasTempoAPI, tempoMarks = pcall(function() return timeAxis:getAllTempoMarks() end)
  if hasTempoAPI and type(tempoMarks) == "table" and #tempoMarks > 0 then
    for _, mark in ipairs(tempoMarks) do
      table.insert(tempoList, ordered(
        {"position", "bpm"},
        { position = mark.position or 0, bpm = float(mark.bpm or 120.0) }
      ))
    end
  else
    table.insert(tempoList, ordered(
      {"position", "bpm"},
      { position = 0, bpm = float(120.0) }
    ))
  end

  -- 构建轨道
  local tracksList = {}
  local numTracks = project:getNumTracks()
  for i = 1, numTracks do
    local track = project:getTrack(i)

    -- 从 mixer API 读取实际值 (getMixer 需要 2.1.1+)
    local mixGain = float(0.0)
    local mixPan = float(0.0)
    local mixMute = false
    local mixSolo = false
    local hasMixer, mixer = pcall(function() return track:getMixer() end)
    if hasMixer and mixer then
      local hasGain, g = pcall(function() return mixer:getGainDecibel() end)
      if hasGain and g then mixGain = float(g) end
      local hasPan, p = pcall(function() return mixer:getPan() end)
      if hasPan and p then mixPan = float(p) end
      local hasMute, m = pcall(function() return mixer:isMuted() end)
      if hasMute and m ~= nil then mixMute = m end
      local hasSolo, s = pcall(function() return mixer:isSolo() end)
      if hasSolo and s ~= nil then mixSolo = s end
    end

    local mixerData = ordered(
      {"gainDecibel", "pan", "mute", "solo", "display"},
      { gainDecibel = mixGain, pan = mixPan, mute = mixMute, solo = mixSolo,
        display = getSvpMixerField(i, "display", true) }
    )

    local trackData = ordered(
      {"name", "dispColor", "dispOrder", "renderEnabled", "mixer",
       "mainGroup", "mainRef", "groups"},
      {
        name          = track:getName(),
        dispColor     = (function()
          local ok, c = pcall(function() return track:getDisplayColor() end)
          return ok and c or "ff7db235"
        end)(),
        dispOrder     = getSvpTrackField(i, "dispOrder", i - 1),
        renderEnabled = getSvpTrackField(i, "renderEnabled", false),
        mixer         = mixerData,
        groups        = {}
      }
    )

    local numGroups = track:getNumGroups()
    if numGroups > 0 then
      for j = 1, numGroups do
        local groupRef = track:getGroupReference(j)
        local group = groupRef:getTarget()

        -- 构建音符列表
        local notesList = {}
        local numNotes = group:getNumNotes()
        for k = 1, numNotes do
          table.insert(notesList, buildNoteData(group:getNote(k)))
        end

        -- 构建组数据
        local groupData = ordered(
          {"name", "uuid", "parameters", "vocalModes", "notes"},
          {
            name       = group:getName(),
            uuid       = group:getUUID(),
            parameters = buildParametersData(group),
            vocalModes = emptyObject(),
            notes      = notesList
          }
        )

        if j == 1 then
          trackData.mainGroup = groupData
          trackData.mainRef   = buildMainRefData(groupRef, group:getUUID(), i)
        else
          table.insert(trackData.groups, groupData)
        end
      end
    end

    table.insert(tracksList, trackData)
  end

  -- renderConfig
  -- 优先从 .svp 源文件读取，否则从工程文件名推断默认值
  local svpRenderCfg = getSvpRenderConfig()
  local renderCfg
  if svpRenderCfg then
    renderCfg = ordered(
      {"destination", "filename", "numChannels", "aspirationFormat",
       "bitDepth", "sampleRate", "exportMixDown", "exportPitch"},
      {
        destination      = svpRenderCfg.destination or "",
        filename         = svpRenderCfg.filename or "",
        numChannels      = svpRenderCfg.numChannels or 1,
        aspirationFormat = svpRenderCfg.aspirationFormat or "noAspiration",
        bitDepth         = svpRenderCfg.bitDepth or 16,
        sampleRate       = svpRenderCfg.sampleRate or 44100,
        exportMixDown    = (function() if svpRenderCfg.exportMixDown ~= nil then return svpRenderCfg.exportMixDown else return true end end)(),
        exportPitch      = (function() if svpRenderCfg.exportPitch ~= nil then return svpRenderCfg.exportPitch else return false end end)()
      }
    )
  else
    -- 回退：从工程文件名提取默认导出名
    local projFileName = project:getFileName()
    local renderFilename = ""
    if projFileName ~= "" then
      renderFilename = projFileName:match("([^/\\]+)$") or ""
      renderFilename = renderFilename:match("(.+)%.") or renderFilename
    end
    renderCfg = ordered(
      {"destination", "filename", "numChannels", "aspirationFormat",
       "bitDepth", "sampleRate", "exportMixDown", "exportPitch"},
      {
        destination      = "",
        filename         = renderFilename,
        numChannels      = 1,
        aspirationFormat = "noAspiration",
        bitDepth         = 16,
        sampleRate       = 44100,
        exportMixDown    = true,
        exportPitch      = false
      }
    )
  end

  -- 顶层结构
  local snap = ordered(
    {"version", "time", "library", "tracks", "renderConfig"},
    {
      version = getSvpVersion(),
      time    = ordered(
        {"meter", "tempo"},
        { meter = meterList, tempo = tempoList }
      ),
      library = {},
      tracks  = tracksList,
      renderConfig = renderCfg
    }
  )

  return snap
end

-- ==========================================
-- 异步分阶段导出管线（Phased Export Pipeline）
-- 将 buildOfficialLikeFromModel + json.encode + file write 分散到多个 timer tick
-- 每个 tick 只处理一个阶段，避免长时间阻塞 SV 主线程
--
-- 阶段:
--   "idle"    → 无待处理任务
--   "meta"    → 构建 time/tempo/renderConfig（轻量）
--   "track"   → 每 tick 构建一个轨道（音符 + 参数）
--   "encode"  → json.encode（可能较重）
--   "write"   → 写入文件
-- ==========================================
local exportAsync = {
  phase = "idle",
  path = "",
  trackIndex = 0,
  numTracks = 0,
  snap = nil,
  tracksList = nil,
  jsonStr = nil,
}

local function exportPhaseReset()
  exportAsync.phase = "idle"
  exportAsync.snap = nil
  exportAsync.tracksList = nil
  exportAsync.jsonStr = nil
end

-- 构建顶层元数据（time, tempo, renderConfig）
-- 从 buildOfficialLikeFromModel 中拆出的轻量部分
local function exportPhaseMeta()
  local project = SV:getProject()
  if not project then
    exportPhaseReset()
    return
  end

  local timeAxis = project:getTimeAxis()
  local meterList = {}
  local hasMeterAPI, meterMarks = pcall(function() return timeAxis:getAllMeasureMarks() end)
  if hasMeterAPI and type(meterMarks) == "table" and #meterMarks > 0 then
    for _, mark in ipairs(meterMarks) do
      table.insert(meterList, ordered(
        {"index", "numerator", "denominator"},
        { index = mark.position or 0, numerator = mark.numerator or 4, denominator = mark.denominator or 4 }
      ))
    end
  else
    table.insert(meterList, ordered(
      {"index", "numerator", "denominator"},
      { index = 0, numerator = 4, denominator = 4 }
    ))
  end

  local tempoList = {}
  local hasTempoAPI, tempoMarks = pcall(function() return timeAxis:getAllTempoMarks() end)
  if hasTempoAPI and type(tempoMarks) == "table" and #tempoMarks > 0 then
    for _, mark in ipairs(tempoMarks) do
      table.insert(tempoList, ordered(
        {"position", "bpm"},
        { position = mark.position or 0, bpm = float(mark.bpm or 120.0) }
      ))
    end
  else
    table.insert(tempoList, ordered(
      {"position", "bpm"},
      { position = 0, bpm = float(120.0) }
    ))
  end

  local svpRenderCfg = getSvpRenderConfig()
  local renderCfg
  if svpRenderCfg then
    renderCfg = ordered(
      {"destination", "filename", "numChannels", "aspirationFormat",
       "bitDepth", "sampleRate", "exportMixDown", "exportPitch"},
      {
        destination      = svpRenderCfg.destination or "",
        filename         = svpRenderCfg.filename or "",
        numChannels      = svpRenderCfg.numChannels or 1,
        aspirationFormat = svpRenderCfg.aspirationFormat or "noAspiration",
        bitDepth         = svpRenderCfg.bitDepth or 16,
        sampleRate       = svpRenderCfg.sampleRate or 44100,
        exportMixDown    = (function() if svpRenderCfg.exportMixDown ~= nil then return svpRenderCfg.exportMixDown else return true end end)(),
        exportPitch      = (function() if svpRenderCfg.exportPitch ~= nil then return svpRenderCfg.exportPitch else return false end end)()
      }
    )
  else
    local projFileName = project:getFileName()
    local renderFilename = ""
    if projFileName ~= "" then
      renderFilename = projFileName:match("([^/\\]+)$") or ""
      renderFilename = renderFilename:match("(.+)%.") or renderFilename
    end
    renderCfg = ordered(
      {"destination", "filename", "numChannels", "aspirationFormat",
       "bitDepth", "sampleRate", "exportMixDown", "exportPitch"},
      {
        destination      = "",
        filename         = renderFilename,
        numChannels      = 1,
        aspirationFormat = "noAspiration",
        bitDepth         = 16,
        sampleRate       = 44100,
        exportMixDown    = true,
        exportPitch      = false
      }
    )
  end

  exportAsync.numTracks = project:getNumTracks()
  exportAsync.tracksList = {}
  exportAsync.snap = ordered(
    {"version", "time", "library", "tracks", "renderConfig"},
    {
      version = getSvpVersion(),
      time    = ordered(
        {"meter", "tempo"},
        { meter = meterList, tempo = tempoList }
      ),
      library = {},
      tracks  = nil,  -- 后续阶段填充
      renderConfig = renderCfg
    }
  )

  exportAsync.trackIndex = 1
  exportAsync.phase = "track"
end

-- 构建单个轨道数据（每 tick 处理一个轨道）
local function exportPhaseTrack()
  local project = SV:getProject()
  if not project then
    exportPhaseReset()
    return
  end

  local i = exportAsync.trackIndex
  if i > exportAsync.numTracks then
    exportAsync.snap.tracks = exportAsync.tracksList
    exportAsync.phase = "encode"
    return
  end

  local track = project:getTrack(i)

  local mixGain = float(0.0)
  local mixPan = float(0.0)
  local mixMute = false
  local mixSolo = false
  local hasMixer, mixer = pcall(function() return track:getMixer() end)
  if hasMixer and mixer then
    local hasGain, g = pcall(function() return mixer:getGainDecibel() end)
    if hasGain and g then mixGain = float(g) end
    local hasPan, p = pcall(function() return mixer:getPan() end)
    if hasPan and p then mixPan = float(p) end
    local hasMute, m = pcall(function() return mixer:isMuted() end)
    if hasMute and m ~= nil then mixMute = m end
    local hasSolo, s = pcall(function() return mixer:isSolo() end)
    if hasSolo and s ~= nil then mixSolo = s end
  end

  local mixerData = ordered(
    {"gainDecibel", "pan", "mute", "solo", "display"},
    { gainDecibel = mixGain, pan = mixPan, mute = mixMute, solo = mixSolo,
      display = getSvpMixerField(i, "display", true) }
  )

  local trackData = ordered(
    {"name", "dispColor", "dispOrder", "renderEnabled", "mixer",
     "mainGroup", "mainRef", "groups"},
    {
      name          = track:getName(),
      dispColor     = (function()
        local ok, c = pcall(function() return track:getDisplayColor() end)
        return ok and c or "ff7db235"
      end)(),
      dispOrder     = getSvpTrackField(i, "dispOrder", i - 1),
      renderEnabled = getSvpTrackField(i, "renderEnabled", false),
      mixer         = mixerData,
      groups        = {}
    }
  )

  local numGroups = track:getNumGroups()
  if numGroups > 0 then
    for j = 1, numGroups do
      local groupRef = track:getGroupReference(j)
      local group = groupRef:getTarget()

      local notesList = {}
      local numNotes = group:getNumNotes()
      for k = 1, numNotes do
        table.insert(notesList, buildNoteData(group:getNote(k)))
      end

      local groupData = ordered(
        {"name", "uuid", "parameters", "vocalModes", "notes"},
        {
          name       = group:getName(),
          uuid       = group:getUUID(),
          parameters = buildParametersData(group),
          vocalModes = emptyObject(),
          notes      = notesList
        }
      )

      if j == 1 then
        trackData.mainGroup = groupData
        trackData.mainRef   = buildMainRefData(groupRef, group:getUUID(), i)
      else
        table.insert(trackData.groups, groupData)
      end
    end
  end

  table.insert(exportAsync.tracksList, trackData)
  exportAsync.trackIndex = i + 1
end

-- JSON 序列化阶段
local function exportPhaseEncode()
  if not exportAsync.snap then
    exportPhaseReset()
    return
  end
  exportAsync.jsonStr = json.encode(exportAsync.snap, 2)
  exportAsync.snap = nil
  exportAsync.tracksList = nil
  exportAsync.phase = "write"
end

-- 文件写入阶段
local function exportPhaseWrite()
  if not exportAsync.jsonStr then
    exportPhaseReset()
    return
  end
  local file, err = io.open(exportAsync.path, "w")
  if file then
    file:write(exportAsync.jsonStr)
    file:close()
  end
  exportPhaseReset()
end

-- 推进一个导出阶段，由 loopTick 每 tick 调用
-- 返回 true 表示本轮导出仍在进行中
local function exportTickStep()
  local phase = exportAsync.phase
  if phase == "idle" then
    return false
  elseif phase == "meta" then
    exportPhaseMeta()
    return true
  elseif phase == "track" then
    exportPhaseTrack()
    return true
  elseif phase == "encode" then
    exportPhaseEncode()
    return true
  elseif phase == "write" then
    exportPhaseWrite()
    return false
  end
  return false
end

-- 启动异步导出（设置初始状态，后续由 loopTick 驱动）
local function startAsyncExport(path, skipSvpReload)
  if not skipSvpReload then
    svpFileCache = nil
  end
  exportAsync.path = path
  exportAsync.phase = "meta"
end

-- 同步导出（首次启动 / 非 loop 场景使用，保持向后兼容）
local function exportProjectModel(path, skipSvpReload)
  if not skipSvpReload then
    svpFileCache = nil
  end
  local model = buildOfficialLikeFromModel()
  if not model then return false end

  local jsonStr = json.encode(model, 2)

  local file, err = io.open(path, "w")
  if file then
    file:write(jsonStr)
    file:close()
    return true
  else
    return false
  end
end

-- ==========================================
-- 核心功能 2: 应用外部 JSON 到编辑器模型（字段级 diff）
-- 只修改实际发生变化的字段，避免全量覆盖
-- ==========================================

-- 比较两个 flat points 数组是否相同 [x1,y1,x2,y2,...]
local function pointsEqual(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  if #a ~= #b then return false end
  for i = 1, #a do
    -- 浮点数比较：使用足够小的 epsilon
    if type(a[i]) == "number" and type(b[i]) == "number" then
      if math.abs(a[i] - b[i]) > 1e-9 then return false end
    elseif a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- 对单个音符进行字段级 diff 更新
-- note: SV Note 对象
-- newData: 从 JSON 解析的音符数据表
-- oldData: 上次导入时的音符数据（用于检测变化）
local function diffUpdateNote(note, newData, oldData)
  -- onset + duration: 比较后按需更新
  local newOnset = newData.onset
  local newDuration = newData.duration
  if newOnset and newDuration then
    if not oldData or newOnset ~= oldData.onset or newDuration ~= oldData.duration then
      note:setTimeRange(newOnset, newDuration)
    end
  elseif newOnset and (not oldData or newOnset ~= oldData.onset) then
    note:setOnset(newOnset)
  elseif newDuration and (not oldData or newDuration ~= oldData.duration) then
    note:setDuration(newDuration)
  end

  -- pitch
  if newData.pitch and (not oldData or newData.pitch ~= oldData.pitch) then
    note:setPitch(newData.pitch)
  end

  -- lyrics
  if newData.lyrics and (not oldData or newData.lyrics ~= oldData.lyrics) then
    note:setLyrics(newData.lyrics)
  end

  -- phonemes
  if newData.phonemes ~= nil and (not oldData or newData.phonemes ~= oldData.phonemes) then
    note:setPhonemes(newData.phonemes or "")
  end

  -- attributes (tF0Left, dF0Vbr, evenSyllableDuration 等)
  -- 使用 setAttributes 进行部分更新，只传入变化的字段
  if newData.systemAttributes then
    local attrDiff = {}
    local hasDiff = false
    local oldSys = oldData and oldData.systemAttributes or {}

    local sysFields = {"tF0Offset", "tF0Left", "tF0Right", "dF0Left", "dF0Right", "dF0Vbr"}
    for _, field in ipairs(sysFields) do
      local newVal = newData.systemAttributes[field]
      if newVal ~= nil then
        local oldVal = oldSys[field]
        if oldVal == nil or math.abs(newVal - oldVal) > 1e-9 then
          attrDiff[field] = newVal
          hasDiff = true
        end
      end
    end

    -- evenSyllableDuration (boolean)
    local newESD = newData.systemAttributes.evenSyllableDuration
    if newESD ~= nil and (oldSys.evenSyllableDuration == nil or newESD ~= oldSys.evenSyllableDuration) then
      attrDiff.evenSyllableDuration = newESD
      hasDiff = true
    end

    if hasDiff then
      pcall(function() note:setAttributes(attrDiff) end)
    end
  end
end

-- 对单个组的参数曲线进行 diff 更新
-- group: SV NoteGroup 对象
-- newParams: 新的 parameters 数据表
-- oldParams: 上次导入时的 parameters 数据表
local function diffUpdateParameters(group, newParams, oldParams)
  if not newParams then return end
  
  for _, paramType in ipairs(paramTypeNames) do
    local newParamData = newParams[paramType]
    if newParamData and newParamData.points then
      local newPoints = newParamData.points
      local oldPoints = oldParams and oldParams[paramType] and oldParams[paramType].points or {}
      
      -- 只在 points 数组有差异时才更新
      if not pointsEqual(newPoints, oldPoints) then
        local pAM = group:getParameter(paramType)
        if pAM then
          pAM:removeAll()
          for pt_i = 1, #newPoints, 2 do
            local blick = newPoints[pt_i]
            local val = newPoints[pt_i + 1]
            if blick and val then
              pAM:add(blick, val)
            end
          end
        end
      end
    end
  end
end

-- 缓存上次成功导入的解析后数据，用于字段级比较
local lastImportedData = nil
local importFirstFailTime = nil  -- 首次连续失败的时间戳，nil 表示无故障

local function applyProjectModel(snap)
  local project = SV:getProject()
  if not project then return end
  
  if not snap.tracks or type(snap.tracks) ~= "table" then return end
  
  -- 创建新的 undo 记录，使用户可以 Ctrl+Z 撤销本次导入
  project:newUndoRecord()
  
  local oldTracks = lastImportedData and lastImportedData.tracks or {}
  local currentTrackCount = project:getNumTracks()
  local importTrackCount = #snap.tracks
  
  for i = 1, importTrackCount do
    local trackData = snap.tracks[i]
    local oldTrackData = oldTracks[i]
    local track
    
    if i <= currentTrackCount then
      track = project:getTrack(i)
    else
      -- 新增轨道
      track = SV:create("Track")
      project:addTrack(track)
    end
    
    -- 轨道名称
    if trackData.name and (not oldTrackData or trackData.name ~= oldTrackData.name) then
      track:setName(trackData.name)
    end
    
    -- 辅助函数：对一个已知的 group 对象应用 groupData 中的音符和参数
    local function applyGroupData(group, groupData, oldGroupData)
      local newNotes = groupData.notes or {}
      local oldNotes = oldGroupData and oldGroupData.notes or {}
      local currentNoteCount = group:getNumNotes()
      local newNoteCount = #newNotes

      -- 逐音符字段级 diff
      local minCount = math.min(currentNoteCount, newNoteCount)
      for k = 1, minCount do
        local note = group:getNote(k)
        local oldNoteData = oldNotes[k]
        diffUpdateNote(note, newNotes[k], oldNoteData)
      end

      -- 新增音符（JSON 中有、当前工程中没有）
      if newNoteCount > currentNoteCount then
        for k = currentNoteCount + 1, newNoteCount do
          local noteData = newNotes[k]
          local newNote = SV:create("Note")
          newNote:setTimeRange(noteData.onset or 0, noteData.duration or 1)
          newNote:setPitch(noteData.pitch or 60)
          newNote:setLyrics(noteData.lyrics or "la")
          if noteData.phonemes and noteData.phonemes ~= "" then
            newNote:setPhonemes(noteData.phonemes)
          end
          if noteData.systemAttributes then
            pcall(function() newNote:setAttributes(noteData.systemAttributes) end)
          end
          group:addNote(newNote)
        end
      end

      -- 删除多余音符（当前工程中有、JSON 中没有）
      if currentNoteCount > newNoteCount then
        for k = currentNoteCount, newNoteCount + 1, -1 do
          group:removeNote(k)
        end
      end

      -- 参数曲线 diff
      local oldParams = oldGroupData and oldGroupData.parameters
      diffUpdateParameters(group, groupData.parameters, oldParams)
    end

    -- 更新 mainGroup
    if trackData.mainGroup and track:getNumGroups() > 0 then
      local groupRef = track:getGroupReference(1)
      local group = groupRef:getTarget()
      local oldMainGroup = oldTrackData and oldTrackData.mainGroup
      applyGroupData(group, trackData.mainGroup, oldMainGroup)
    end

    -- 更新 groups（额外组，j >= 2）
    local newGroups = trackData.groups or {}
    local oldGroups = oldTrackData and oldTrackData.groups or {}
    local currentNumGroups = track:getNumGroups()

    for j = 1, #newGroups do
      local groupData = newGroups[j]
      local oldGroupData = oldGroups[j]
      local svGroupRef = nil

      -- 优先按 UUID 在当前轨道中查找对应的 GroupReference（跳过 j=1 的 mainGroup）
      if groupData.uuid and groupData.uuid ~= "" then
        for gi = 2, currentNumGroups do
          local ref = track:getGroupReference(gi)
          local tgt = ref:getTarget()
          if tgt:getUUID() == groupData.uuid then
            svGroupRef = ref
            break
          end
        end
      end

      -- UUID 未匹配时，按位置对应（gi = j+1，因为 j=1 对应 mainGroup）
      if not svGroupRef then
        local gi = j + 1
        if gi <= currentNumGroups then
          svGroupRef = track:getGroupReference(gi)
        end
      end

      if svGroupRef then
        local group = svGroupRef:getTarget()
        applyGroupData(group, groupData, oldGroupData)
      end
    end
  end
  
  -- 缓存本次导入的数据用于下次 diff
  lastImportedData = snap
end

local IMPORT_FAIL_TOLERANCE_SEC = 60

local function importFromFile(path)
  local file, err = io.open(path, "r")
  if not file then
    if not importFirstFailTime then
      importFirstFailTime = getTimestamp()
    end
    local elapsed = getTimestamp() - importFirstFailTime
    if elapsed < IMPORT_FAIL_TOLERANCE_SEC then
      return false, "File temporarily unavailable, waiting."
    end
    importFirstFailTime = nil
    return false, string.format("Cannot open %s (failed for >%ds)", path, IMPORT_FAIL_TOLERANCE_SEC)
  end
  
  local jsonStr = file:read("*a")
  file:close()
  
  if not jsonStr or jsonStr == "" then
    if not importFirstFailTime then
      importFirstFailTime = getTimestamp()
    end
    local elapsed = getTimestamp() - importFirstFailTime
    if elapsed < IMPORT_FAIL_TOLERANCE_SEC then
      return false, "File empty, waiting."
    end
    importFirstFailTime = nil
    return false, "File remained empty for >" .. IMPORT_FAIL_TOLERANCE_SEC .. "s."
  end
  
  importFirstFailTime = nil
  
  if jsonStr == lastImportedContents then
    return false, "File not changed by external."
  end
  
  local ok, snap = pcall(function() return json.decode(jsonStr) end)
  if not ok or type(snap) ~= "table" then
    return false, "JSON decode failed."
  end
  
  applyProjectModel(snap)
  lastImportedContents = jsonStr
  return true, "Import Success"
end

-- ==========================================
-- Loop engine (dual-file + read/write alternating)
-- {uuid}_out.json: SV continuously writes current project data
-- {uuid}_in.json:  SV monitors for external changes, applies diffs
-- All files in hormony/ working directory
--
-- Work modes:
--   "full"   -> alternating export/import (odd tick export, even tick import)
--   "export" -> export only (every tick)
--   "import" -> import only (every tick)
-- Full read/write cycle in "full" mode = 2 x loopInterval
-- ==========================================
local loopOutPath = ""
local loopInPath  = ""

local loopTickCount = 0

local function loopTick()
  if not isLoopModeActive then return end

  if not lockBelongsToMe(currentSessionId) then
    isLoopModeActive = false
    updateSessionState(currentSessionId, "stopped")
    SV:finish()
    return
  end

  loopTickCount = loopTickCount + 1

  if workMode == "import" then
    importFromFile(loopInPath)
  else
    startAsyncExport(loopOutPath, true)
    while exportTickStep() do end
    if workMode == "full" then
      importFromFile(loopInPath)
    end
  end

  if loopTickCount % 20 == 0 then
    updateSessionTimestamp(currentSessionId)
  end

  SV:setTimeout(loopInterval, loopTick)
end

-- ==========================================
-- Main: 开关切换（点击启动/停止桥接）
-- ==========================================
function main()
  -- Ensure hormony working directory is accessible
  local dirOk = ensureHormonyDir()
  if not dirOk then
    SV:showMessageBox("Error",
      "Cannot access hormony working directory:\n" .. HORMONY_DIR
      .. "\n\nPlease create this directory manually or run Hormony Settings first.")
    SV:finish()
    return
  end

  -- Load config from Hormony_Config.json (written by HormonySettings.lua)
  local cfg = readConfig()
  if cfg then
    if cfg.interval and type(cfg.interval) == "number" then
      loopInterval = cfg.interval
    end
    if cfg.hormonyDir and type(cfg.hormonyDir) == "string" and cfg.hormonyDir ~= "" then
      HORMONY_DIR    = cfg.hormonyDir
      SESSION_FILE_PATH = HORMONY_DIR .. "Hormony_Session.json"
      CONFIG_FILE_PATH  = HORMONY_DIR .. "Hormony_Config.json"
      LOCK_FILE_PATH    = HORMONY_DIR .. "Hormony_Lock.json"
    end
    if cfg.workMode and (cfg.workMode == "full" or cfg.workMode == "export" or cfg.workMode == "import") then
      workMode = cfg.workMode
    end
    if cfg.endDetectSec and type(cfg.endDetectSec) == "number" and cfg.endDetectSec > 0 then
      endDetectSec = cfg.endDetectSec
    end
  end

  -- 检查锁文件：若存在且 timestamp 距今 < 120s，说明有实例正在运行 → 发送停止信号
  local lock = readLockFile()
  if lock and lock.sessionId and lock.timestamp then
    local age = getTimestamp() - (lock.timestamp or 0)
    if age < 120 then
      -- 删除锁文件 = 停止信号，运行中的 loopTick 检测到后会自行退出
      deleteLockFile()
      SV:finish()
      return
    end
    -- 锁文件过期（可能是崩溃遗留），继续启动
  end

  -- Pre-load .svp file for database/systemPitchDelta
  svpFileCache = nil
  svpLoadError = ""
  loadSvpFile()

  -- Register session (generates UUID and bridge file paths)
  local uuid, outPath, inPath = registerSession()
  currentSessionId = uuid

  -- 写入锁文件，标记本实例为当前运行的桥接
  writeLockFile(uuid)

  -- Initial export to {uuid}_out.json
  if workMode ~= "import" then
    exportProjectModel(outPath)
  end

  -- Create {uuid}_in.json with current project data (establishes diff baseline)
  if workMode ~= "export" then
    svpFileCache = nil  -- rebuild for clean model
    local initModel = buildOfficialLikeFromModel()
    if initModel then
      local initJson = json.encode(initModel, 2)
      local f = io.open(inPath, "w")
      if f then
        f:write(initJson)
        f:close()
      end
      lastImportedContents = initJson
      lastImportedData = json.decode(initJson)
    end
  end

  -- Start loop (silent, no popups)
  isLoopModeActive = true
  loopOutPath = outPath
  loopInPath  = inPath
  loopTickCount = 0
  loopTick()
end
