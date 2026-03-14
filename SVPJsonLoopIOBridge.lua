-- SVPJsonLoopIOBridge.lua
-- Hormony API — JSON 双缓冲环路桥接
-- 核心目标：为 Synthesizer V Studio 创建一个 JSON 格式的环路桥接脚本
-- 使用 SV 编辑器对象模型作为唯一数据源，完全兼容官方 .svp 中的 JSON 结构

function getClientInfo()
  return {
    name = SV:T("Hormony API"),
    author = "User",
    versionNumber = 1,
    minEditorVersion = 65537
  }
end

function getTranslations(langCode)
  if langCode == "zh-cn" then
    return {
      {"Hormony API", "Hormony API"},
      {"Select Operation Mode", "选择操作模式"},
      {"Export to JSON", "导出工程为 JSON"},
      {"Import from JSON", "从 JSON 导入"},
      {"Start Loop Mode", "启动环路模式 (导出 + 监听导入)"}
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

function json.encode(val)
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
    
    -- 检查是否为有序键表（通过 __key_order 元数据）
    local key_order = val["__key_order__"]
    if key_order then
      local parts = {}
      local used = { __key_order__ = true }
      for _, k in ipairs(key_order) do
        if val[k] ~= nil then
          table.insert(parts, '"' .. escape_str(k) .. '":' .. json.encode(val[k]))
          used[k] = true
        end
      end
      for k, v in pairs(val) do
        if type(k) == "string" and not used[k] then
          table.insert(parts, '"' .. escape_str(k) .. '":' .. json.encode(v))
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
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
          table.insert(parts, "null")
        else
          table.insert(parts, json.encode(val[i]))
        end
      end
      return "[" .. table.concat(parts, ",") .. "]"
    elseif next(val) == nil then
      return "[]"  -- 默认空表为空数组
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
-- 全局状态与配置
-- ==========================================
local isLoopModeActive = false
local loopInterval = 1000 -- 每 1000 毫秒循环一次（默认，可通过 UI 修改）
local lastImportedContents = ""  -- 缓存 {uuid}_in.json 的上次内容，用于检测外部更改
local HORMONY_DIR = "C:/Users/User/Documents/Dreamtonics/Synthesizer V Studio/hormony/"
local SCRIPT_VERSION = "0.1.2"
local SESSION_FILE_PATH = HORMONY_DIR .. "Hormony_Session.json"
local currentSessionId = nil  -- 当前会话的 UUID
local paramTypeNames = {
  "pitchDelta", "vibratoEnv", "loudness", "tension",
  "breathiness", "voicing", "gender", "toneShift"
}

-- 更新频率选项（毫秒）
local INTERVAL_OPTIONS = {
  { label = "15s",  ms = 15000 },
  { label = "5s",   ms = 5000 },
  { label = "3s",   ms = 3000 },
  { label = "1s",   ms = 1000 },
  { label = "0.5s", ms = 500 },
}

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
  f:write(json.encode(sessions))
  f:close()
  return true
end

-- 清理过期 session
-- 规则:
--   state == "running" 且 timestamp 距今 > 60 秒 → 删除（说明进程已死）
--   其他 state 且 timestamp 距今 > 3600 秒 (60min) → 删除
local function cleanupSessions(sessions)
  local now = getTimestamp()
  if now == 0 then return sessions end  -- 无法获取时间，跳过清理

  local cleaned = {}
  for _, s in ipairs(sessions) do
    local age = now - (s.timestamp or 0)
    if s.state == "running" and age > 60 then
      -- 跳过（删除）：running 状态但超过 1 分钟没更新
    elseif s.state ~= "running" and age > 3600 then
      -- 跳过（删除）：非 running 状态超过 60 分钟
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

-- 构建参数数据
local function buildParametersData(group)
  local paramsData = ordered(
    {"pitchDelta", "vibratoEnv", "loudness", "tension",
     "breathiness", "voicing", "gender", "toneShift"},
    {}
  )

  for _, paramType in ipairs(paramTypeNames) do
    local pAM = group:getParameter(paramType)
    local flattenedPoints = {}
    if pAM then
      local points = pAM:getPoints(-10000000, 100000000)
      for _, pt in ipairs(points) do
        -- 位置为整数，值为浮点数
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

local function exportProjectModel(path)
  svpFileCache = nil  -- 每次导出时清空缓存，重新读取 .svp 文件
  local model = buildOfficialLikeFromModel()
  if not model then return false end
  
  local jsonStr = json.encode(model)
  
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
    
    -- 更新 mainGroup
    if trackData.mainGroup and track:getNumGroups() > 0 then
      local groupRef = track:getGroupReference(1)
      local group = groupRef:getTarget()
      local newNotes = trackData.mainGroup.notes or {}
      local oldNotes = oldTrackData and oldTrackData.mainGroup and oldTrackData.mainGroup.notes or {}
      local currentNoteCount = group:getNumNotes()
      local newNoteCount = #newNotes
      
      -- 逐音符字段级 diff
      local minCount = math.min(currentNoteCount, newNoteCount)
      for k = 1, minCount do
        local note = group:getNote(k)
        local oldNoteData = oldNotes[k]  -- 可能为 nil（首次导入时）
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
      local oldParams = oldTrackData and oldTrackData.mainGroup and oldTrackData.mainGroup.parameters
      diffUpdateParameters(group, trackData.mainGroup.parameters, oldParams)
    end
  end
  
  -- 缓存本次导入的数据用于下次 diff
  lastImportedData = snap
end

local function importFromFile(path)
  local file, err = io.open(path, "r")
  if not file then return false, string.format("Cannot open %s", path) end
  
  local jsonStr = file:read("*a")
  file:close()
  
  if jsonStr == lastImportedContents then
    -- 文件没发生过实质性颠覆改变，忽略
    return false, "File not changed by external."
  end
  
  local snap = json.decode(jsonStr)
  if type(snap) == "table" then
    applyProjectModel(snap)
    -- 更新内容防止死循环反弹
    lastImportedContents = jsonStr
    return true, "Import Success"
  else
    return false, "JSON decode failed."
  end
end

-- ==========================================
-- 环路功能（双文件架构）
-- {uuid}_out.json: SV 持续将当前工程数据写入此文件
-- {uuid}_in.json:  SV 监控此文件，检测到外部更改时应用到工程
-- 所有文件位于 hormony/ 工作目录下
-- ==========================================
local loopOutPath = ""  -- 缓存路径，避免每 tick 重新计算
local loopInPath  = ""

local loopTickCount = 0  -- 计数器：用于降低 session 更新频率

local function loopTick()
  if not isLoopModeActive then return end
  
  -- 1. 检查 {uuid}_in.json 是否被外部工具修改，如有则导入
  importFromFile(loopInPath)
  
  -- 2. 持续将当前 SV 工程状态写入 {uuid}_out.json
  exportProjectModel(loopOutPath)
  
  -- 3. 定期更新 session 时间戳（每 10 个 tick 更新一次，减少磁盘 IO）
  loopTickCount = loopTickCount + 1
  if loopTickCount % 10 == 0 then
    updateSessionTimestamp(currentSessionId)
  end
  
  SV:setTimeout(loopInterval, loopTick)
end

function main()
  -- 确保 hormony 工作目录可用
  local dirOk = ensureHormonyDir()
  local dirHint = ""
  if not dirOk then
    dirHint = "\n\n[!] 无法访问 hormony 工作目录: " .. HORMONY_DIR
      .. "\n    请手动创建此目录后重试。"
  end

  -- 预先尝试加载 .svp 文件，生成提示信息
  svpFileCache = nil
  svpLoadError = ""
  local svpData = loadSvpFile()
  local svpHint = ""
  if not svpData then
    svpHint = "\n\n[!] " .. svpLoadError
    svpHint = svpHint .. "\n    database（声库）和 systemPitchDelta（自动音高曲线）将为空。"
  else
    svpHint = "\n\n[i] 受限于脚本 API，database 和 systemPitchDelta 将从 .svp 源文件读取。"
    svpHint = svpHint .. "\n    更改声库后请先保存工程（Ctrl+S）再导出。"
  end

  -- 构建频率选项标签
  local intervalChoices = {}
  for _, opt in ipairs(INTERVAL_OPTIONS) do
    table.insert(intervalChoices, opt.label)
  end

  local form = {
    title = SV:T("Select Operation Mode"),
    message = "Hormony v" .. SCRIPT_VERSION
      .. "\nWorking directory: " .. HORMONY_DIR
      .. "\nSession file: " .. SESSION_FILE_PATH
      .. dirHint
      .. svpHint
      .. "\n\n[!] 大工程使用较高刷新频率（如 0.5s、1s）可能导致性能下降。"
      .. "\n    建议大工程使用 3s 或更低的频率。",
    buttons = "OkCancel",
    widgets = {
      {
        name = "mode",
        type = "ComboBox",
        label = SV:T("Select Operation Mode"),
        choices = {SV:T("Start Loop Mode"), SV:T("Export to JSON"), SV:T("Import from JSON")},
        default = 0
      },
      {
        name = "interval",
        type = "ComboBox",
        label = "Update Interval",
        choices = intervalChoices,
        default = 3  -- 默认 1s
      }
    }
  }

  local results = SV:showCustomDialog(form)
  if results.status then
    local mode = results.answers.mode
    -- 读取用户选择的更新频率
    local intervalIdx = results.answers.interval + 1  -- 0-based → 1-based
    if INTERVAL_OPTIONS[intervalIdx] then
      loopInterval = INTERVAL_OPTIONS[intervalIdx].ms
    end

    if mode == 0 then
      -- Loop Mode (default)
      if not dirOk then
        SV:showMessageBox("Error", "hormony 工作目录不可用，无法启动 Loop Mode。\n" .. HORMONY_DIR)
        SV:finish()
        return
      end

      -- 1. 注册 session（生成 UUID 和 bridge 文件路径）
      local uuid, outPath, inPath = registerSession()
      currentSessionId = uuid

      -- 2. 导出当前工程到 {uuid}_out.json
      exportProjectModel(outPath)
      
      -- 3. 创建 {uuid}_in.json（用同样的当前工程数据初始化）
      --    同时建立 diff 基线：lastImportedContents 和 lastImportedData
      svpFileCache = nil  -- 重新构建以获取干净的模型
      local initModel = buildOfficialLikeFromModel()
      if initModel then
        local initJson = json.encode(initModel)
        local f = io.open(inPath, "w")
        if f then
          f:write(initJson)
          f:close()
        end
        -- 设置 diff 基线
        lastImportedContents = initJson
        -- 解析一份干净的数据副本作为 diff 参照
        lastImportedData = json.decode(initJson)
      end
      
      -- 4. 启动循环
      isLoopModeActive = true
      loopOutPath = outPath
      loopInPath  = inPath
      loopTickCount = 0
      SV:showMessageBox("Info",
        "Loop Mode started.\n"
        .. "Press 'Stop Scripts' in Synthesizer V to kill it.\n\n"
        .. "Session ID: " .. uuid .. "\n"
        .. "Update interval: " .. INTERVAL_OPTIONS[intervalIdx].label .. "\n\n"
        .. "OUT (SV -> External):\n" .. outPath .. "\n\n"
        .. "IN  (External -> SV):\n" .. inPath)
      loopTick()
    elseif mode == 1 then
      -- One-shot Export: 使用一次性 UUID 命名
      if not dirOk then
        SV:showMessageBox("Error", "hormony 工作目录不可用。\n" .. HORMONY_DIR)
        SV:finish()
        return
      end
      local uuid = generateUUIDv4()
      local outPath = HORMONY_DIR .. uuid .. "_out.json"
      if exportProjectModel(outPath) then
        SV:showMessageBox("Success", "Export successful!\n" .. outPath)
      else
        SV:showMessageBox("Error", "Export failed for path:\n" .. outPath)
      end
    elseif mode == 2 then
      -- One-shot Import: 让用户知道需要指定文件
      -- 从 hormony 目录中读取最新的 *_in.json
      if not dirOk then
        SV:showMessageBox("Error", "hormony 工作目录不可用。\n" .. HORMONY_DIR)
        SV:finish()
        return
      end
      -- 提示用户输入要导入的文件名
      local importPath = SV:showInputBox("Import", "请输入 hormony 目录下要导入的文件名\n（如 xxxxxxxx_in.json）:", "")
      if importPath and importPath ~= "" then
        local fullPath = HORMONY_DIR .. importPath
        local ok, err_msg = importFromFile(fullPath)
        if ok then
          SV:showMessageBox("Success", "Import successful!\n" .. fullPath)
        else
          SV:showMessageBox("Info", "Import Info:\n" .. err_msg)
        end
      end
    end
  end
  
  if not isLoopModeActive then
    -- 脚本结束时，如果有 session 则标记为 stopped
    if currentSessionId then
      updateSessionState(currentSessionId, "stopped")
    end
    SV:finish()
  end
end
