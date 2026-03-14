-- SVPJsonLoopIOBridge.lua
-- 官方 JSON 双缓冲环路 IO 桥接
-- 核心目标：为 Synthesizer V Studio 创建一个 JSON 格式的环路 IO 桥接脚本
-- 使用 SV 编辑器对象模型作为唯一数据源，完全兼容官方 .svp 中的 JSON 结构

function getClientInfo()
  return {
    name = SV:T("JSON Loop IO Bridge"),
    category = "IO",
    author = "User",
    versionNumber = 1,
    minEditorVersion = 65537
  }
end

function getTranslations(langCode)
  if langCode == "zh-cn" then
    return {
      {"JSON Loop IO Bridge", "JSON 环路 IO 桥接"},
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
local loopInterval = 1000 -- 每 1000 毫秒循环一次
local externalFileContents = ""
local fallbackBridgeFilePath = "C:/sv_bridge_fallback.json" 
local paramTypeNames = {
  "pitchDelta", "vibratoEnv", "loudness", "tension",
  "breathiness", "voicing", "gender", "toneShift"
}

-- 获取安全的读写路径，处理中文路径问题
local function getSafeBridgePath()
  -- 尝试获取当前工程路径
  local projPath = SV:getProject():getFileName()
  local targetPath = "D:/sv_bridge.json"
  
  if projPath ~= "" then
    -- 如果工程已保存，将 bridge 生成在工程同目录
    targetPath = projPath:match("(.*[/\\])") .. "sv_bridge.json"
  end
  
  -- 测试写权限，如果失败可能是包含无法处理的中文路径
  local f = io.open(targetPath, "w")
  if f then
    f:close()
    return targetPath
  else
    return fallbackBridgeFilePath
  end
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

local function loadSvpFile()
  if svpFileCache then return svpFileCache end

  local project = SV:getProject()
  if not project then return nil end

  local svpPath = project:getFileName()
  if svpPath == "" then return nil end  -- 工程未保存

  local f = io.open(svpPath, "r")
  if not f then return nil end

  local content = f:read("*a")
  f:close()

  if not content or content == "" then return nil end

  local ok, data = pcall(function() return json.decode(content) end)
  if not ok or type(data) ~= "table" then return nil end

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
      { gainDecibel = mixGain, pan = mixPan, mute = mixMute, solo = mixSolo, display = true }
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
        dispOrder     = i - 1,
        renderEnabled = false,
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
  -- 从工程文件名提取默认导出名
  local projFileName = project:getFileName()
  local renderFilename = ""
  if projFileName ~= "" then
    -- 提取不含路径和扩展名的文件名
    renderFilename = projFileName:match("([^/\\]+)$") or ""
    renderFilename = renderFilename:match("(.+)%.") or renderFilename
  end

  local renderCfg = ordered(
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

  -- 顶层结构
  local snap = ordered(
    {"version", "time", "library", "tracks", "renderConfig"},
    {
      version = 153,
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
    externalFileContents = jsonStr
    return true
  else
    return false
  end
end

-- ==========================================
-- 核心功能 2: 应用外部 JSON 到编辑器模型
-- ==========================================
local function applyProjectModel(snap)
  local project = SV:getProject()
  if not project then return end
  
  if snap.tracks and type(snap.tracks) == "table" then
    local currentTrackCount = project:getNumTracks()
    local importTrackCount = #snap.tracks
    
    for i = 1, importTrackCount do
      local trackData = snap.tracks[i]
      local track
      if i <= currentTrackCount then
        track = project:getTrack(i)
      else
        track = SV:create("Track")
        project:addTrack(track)
      end
      
      if trackData.name then track:setName(trackData.name) end
      
      -- 更新 Main Group 的音符
      if trackData.mainGroup and trackData.mainGroup.notes then
        -- 为简化，找到第一个组并重建音符
        if track:getNumGroups() > 0 then
          local groupRef = track:getGroupReference(1)
          local group = groupRef:getTarget()
          
          -- 清空原有音符
          local count = group:getNumNotes()
          for k = count, 1, -1 do
            group:removeNote(k)
          end
          
          -- 添加新音符
          for _, noteData in ipairs(trackData.mainGroup.notes) do
            local newNote = SV:create("Note")
            newNote:setTimeRange(noteData.onset, noteData.duration)
            newNote:setPitch(noteData.pitch)
            newNote:setLyrics(noteData.lyrics)
            if noteData.phonemes and noteData.phonemes ~= "" then
              newNote:setPhonemes(noteData.phonemes)
            end
            -- 可以附加其他 attributes 但为防止未知属性崩掉这里简化
            group:addNote(newNote)
          end
          
          -- 同步参数曲线
          for _, paramType in ipairs(paramTypeNames) do
            if trackData.mainGroup.parameters and trackData.mainGroup.parameters[paramType] then
               local pAM = group:getParameter(paramType)
               if pAM then
                 pAM:removeAll() -- 清除此参数所有旧点
                 local points = trackData.mainGroup.parameters[paramType].points
                 if points then
                   -- points 是一维数组 [x1, y1, x2, y2...]
                   for pt_i = 1, #points, 2 do
                     local blick = points[pt_i]
                     local val = points[pt_i+1]
                     if blick and val then
                       pAM:add(blick, val)
                     end
                   end
                 end
               end
            end
          end
        end
      end
    end
  end
end

local function importFromFile(path)
  local file, err = io.open(path, "r")
  if not file then return false, string.format("Cannot open %s", path) end
  
  local jsonStr = file:read("*a")
  file:close()
  
  if jsonStr == externalFileContents then
    -- 文件没发生过实质性颠覆改变，忽略
    return false, "File not changed by external."
  end
  
  local snap = json.decode(jsonStr)
  if type(snap) == "table" then
    applyProjectModel(snap)
    -- 更新内容防止死循环反弹
    externalFileContents = jsonStr
    return true, "Import Success"
  else
    return false, "JSON decode failed."
  end
end

-- ==========================================
-- 环路功能
-- ==========================================
local function loopTick()
  if not isLoopModeActive then return end
  
  local bridgePath = getSafeBridgePath()
  
  -- 1. 尝试导入 (只在文件发生外部更改时才有效响应)
  local imported, msg = importFromFile(bridgePath)
  
  -- 2. 如果存在成功导入，说明外部写入了，我们在编辑器应用完毕后应当再把现在干净的格式导出
  -- 或者即使没导入，也许编辑器内部自己有改变，我们就覆盖外面的文件
  exportProjectModel(bridgePath)
  
  SV:setTimeout(loopInterval, loopTick)
end

function main()
  local safePath = getSafeBridgePath()

  local form = {
    title = SV:T("Select Operation Mode"),
    message = "Target File: " .. safePath,
    buttons = "OkCancel",
    widgets = {
      {
        name = "mode",
        type = "ComboBox",
        label = SV:T("Select Operation Mode"),
        choices = {SV:T("Export to JSON"), SV:T("Import from JSON"), SV:T("Start Loop Mode")},
        default = 0
      }
    }
  }

  local results = SV:showCustomDialog(form)
  if results.status then
    local mode = results.answers.mode
    if mode == 0 then
      if exportProjectModel(safePath) then
        local hints = "Export successful!\n" .. safePath
        local svpPath = SV:getProject():getFileName()
        if svpPath == "" then
          hints = hints .. "\n\n[!] 工程未保存，database（声库）和 systemPitchDelta（自动音高曲线）为空。"
          hints = hints .. "\n    请先保存工程（Ctrl+S）再导出以获取完整数据。"
        else
          hints = hints .. "\n\n[i] database（声库信息）已从 .svp 源文件读取。"
          hints = hints .. "\n    如果更改了声库，请先保存工程再导出。"
          hints = hints .. "\n[i] systemPitchDelta（自动音高曲线）已从 .svp 源文件读取。"
          hints = hints .. "\n    此数据由引擎自动生成，导入后会重新计算。"
        end
        SV:showMessageBox("Success", hints)
      else
        SV:showMessageBox("Error", "Export failed for path:\n" .. safePath)
      end
    elseif mode == 1 then
      local ok, err_msg = importFromFile(safePath)
      if ok then
        SV:showMessageBox("Success", "Import successful!")
      else
        SV:showMessageBox("Info", "Import Info:\n" .. err_msg)
      end
    elseif mode == 2 then
      isLoopModeActive = true
      SV:showMessageBox("Info", "Loop Mode started.\nPress 'Stop Scripts' in Synthesizer V to kill it.\nBridging to: " .. safePath)
      loopTick()
    end
  end
  
  if not isLoopModeActive then
    SV:finish()
  end
end
