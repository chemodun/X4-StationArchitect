-- Station Auto Builder - places a bill of modules through the vanilla build menu's own editor,
-- one module every two frames, so the player watches the plan grow and keeps undo, save plan and Apply.
-- Design, engine facts and the test plan: claude/mod-station_auto_builder.md.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C = ffi.C

ffi.cdef [[
  typedef uint64_t UniverseID;
  typedef struct {
    float x;
    float y;
    float z;
    float yaw;
    float pitch;
    float roll;
  } UIPosRot;
  typedef struct {
    size_t idx;
    const char* macroid;
    UniverseID componentid;
    UIPosRot offset;
    const char* connectionid;
    size_t predecessoridx;
    const char* predecessorconnectionid;
    bool isfixed;
    uint32_t bookmarknum;
  } UIConstructionPlanEntry2;

  void AddFloatingSequenceToConstructionPlan(UniverseID holomapid);
  void AddMacroToConstructionMap(UniverseID holomapid, const char* macroname, bool startdragging);
  void GenerateModuleLoadout(UILoadout* result, UniverseID holomapid, size_t cp_idx, UniverseID defensibleid, float level);
  void GenerateModuleLoadoutCounts(UILoadoutCounts* result, UniverseID holomapid, size_t cp_idx, UniverseID defensibleid, float level);
  size_t GetBuildMapConstructionPlan2(UniverseID holomapid, UniverseID defensibleid, bool usestoredplan, UIConstructionPlanEntry2* result, uint32_t resultlen);
  size_t GetNumBuildMapConstructionPlan(UniverseID holomapid, bool usestoredplan);
  size_t GetNumUpgradeSlots(UniverseID destructibleid, const char* macroname, const char* upgradetypename);
  UniverseID GetPlayerID(void);
  void RemoveFloatingSequenceFromConstructionPlan(UniverseID holomapid);
  void UpdateConstructionMapItemLoadout(UniverseID holomapid, size_t itemidx, UniverseID defensibleid, UILoadout uiloadout);
]]

local MENU_NAME = "StationConfigurationMenu"

local sab = {
  configBlackboard = "$StationAutoBuilderConfig",
  sizesBlackboard = "$StationAutoBuilderBBox",
  playerId = nil,
  cfg = {},
  debugLevel = "none",
  menu = nil,
  -- the active run; nil between runs
  run = nil,
  -- macro -> { maxX, maxY, maxZ, cX, cY, cZ } from MD; macros asked this session
  sizes = {},
  sizesAsked = {},
  -- "entry macro|station connection|module macro|module connection" the engine refused to snap
  incompatible = {},
}

-- *** logging ***

local function format(fmt, ...)
  if select("#", ...) > 0 then fmt = string.format(fmt, ...) end
  return "StationAutoBuilder: " .. fmt
end

function sab.Error(fmt, ...) UIError(format(fmt, ...)) end
function sab.Debug(fmt, ...) if sab.debugLevel ~= "none" then UIDebug(format(fmt, ...)) end end
function sab.Trace(fmt, ...) if sab.debugLevel == "trace" then UITrace(format(fmt, ...)) end end

-- *** config ***

function sab.ReadConfig()
  sab.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  if sab.playerId == 0 then return end
  local cfg = GetNPCBlackboard(sab.playerId, sab.configBlackboard)
  sab.cfg = (type(cfg) == "table") and cfg or {}
  sab.debugLevel = tostring(sab.cfg.debugLevel or "none")
end

-- *** module sizes ***
-- Lua has no macro bounding box; the MD cue BBox answers a per-macro signal into the player's blackboard,
-- half-extents about a centre, metres. MD does not run while paused, so the asking is at menu open.

function sab.ReadSizes()
  local sizes = sab.playerId ~= 0 and GetNPCBlackboard(sab.playerId, sab.sizesBlackboard) or nil
  sab.sizes = (type(sizes) == "table") and sizes or {}
  return sab.sizes
end

function sab.RequestSizes()
  local menu = sab.menu
  if not (menu and menu.modules) or sab.playerId == 0 then return end
  local sizes = sab.ReadSizes()
  local asked = 0
  for _, macros in pairs(menu.modules) do
    for _, macro in ipairs(macros) do
      if not sizes[macro] and not sab.sizesAsked[macro] then
        sab.sizesAsked[macro] = true
        SignalObject(sab.playerId, "StationAutoBuilder.BBox", macro)
        asked = asked + 1
      end
    end
  end
  if asked > 0 then sab.Debug("asked MD for %d module sizes", asked) end
end

-- *** plan read-back ***

-- The plan as the map holds it: one entry per module, map order.
function sab.ReadPlan()
  local menu = sab.menu
  local n = C.GetNumBuildMapConstructionPlan(menu.holomap, false)
  local plan = {}
  if n == 0 then return plan end
  local buf = ffi.new("UIConstructionPlanEntry2[?]", n)
  n = C.GetBuildMapConstructionPlan2(menu.holomap, menu.container, false, buf, n)
  for i = 0, tonumber(n) - 1 do
    local e = buf[i]
    plan[#plan + 1] = {
      idx = tonumber(e.idx),
      macro = ffi.string(e.macroid),
      component = ConvertStringTo64Bit(tostring(e.componentid)),
      offset = { x = e.offset.x, y = e.offset.y, z = e.offset.z, yaw = e.offset.yaw, pitch = e.offset.pitch, roll = e.offset.roll },
      connection = ffi.string(e.connectionid),
      predecessorIdx = tonumber(e.predecessoridx),
      predecessorConnection = ffi.string(e.predecessorconnectionid),
      isFixed = e.isfixed,
    }
  end
  return plan
end

-- The default loadout the vanilla drop handler gives a new module (onRenderTargetMouseUp); nothing when the
-- menu's default loadout is "none" (-1) or the macro has no macro-type upgrade slot.
local function applyDefaultLoadout(added)
  local menu = sab.menu
  if menu.defaultLoadout == nil or menu.defaultLoadout == -1 then return end
  for _, upgradetype in ipairs(Helper.upgradetypes) do
    if upgradetype.supertype == "macro" and C.GetNumUpgradeSlots(added.component, added.macro, upgradetype.type) > 0 then
      local loadout = Helper.getLoadoutHelper(C.GenerateModuleLoadout, C.GenerateModuleLoadoutCounts, menu.holomap, added.idx, menu.container, menu.defaultLoadout)
      local upgradeplan = Helper.convertLoadout(added.component, added.macro, loadout, nil)
      Helper.callLoadoutFunction(upgradeplan, nil, function(uiloadout) return C.UpdateConstructionMapItemLoadout(menu.holomap, added.idx, menu.container, uiloadout) end)
      sab.Trace("entry %d %s: default loadout %s applied", added.idx, added.macro, tostring(menu.defaultLoadout))
      return
    end
  end
end

-- *** engine access ***
-- What the exported map API withholds: the editor object behind the holomap, its floating module's
-- transform and snap result, and the editor's own update that runs the snap search. Two exported
-- wrappers are the anchors; their bytes are verified before any address read out of them is used,
-- and a mismatch disables the route (fail closed). Offsets: GOG 9.00, see the claude file.

local P = "uint8_t*"
local function u32(p) return ffi.cast("uint32_t*", p)[0] end
local function i32(p) return ffi.cast("int32_t*", p)[0] end
local function u64(p) return ffi.cast("uint64_t*", p)[0] end

-- AddFloatingSequenceToConstructionPlan(holomapid): registry global, resolver, holomap kind 0x3a via vfunc
-- 0x11e0, editor at holomap +0x2c0 checked by vfunc 0x18(2), tail jump to the drop; false = rel32 masked
---@type (integer|false)[]
local DROP = { 0x48, 0x89, 0x5c, 0x24, 0x08, 0x57, 0x48, 0x83, 0xec, 0x20, 0x48, 0x8b, 0xf9, 0x48, 0x8b, 0xd1,
  0x48, 0x8b, 0x0d, false, false, false, false, 0x41, 0xb8, 0x04, 0x00, 0x00, 0x00, 0xe8, false, false,
  false, false, 0x48, 0x8b, 0xd8, 0x48, 0x85, 0xc0, 0x74, 0x4f, 0x48, 0x8b, 0x00, 0xba, 0x3a, 0x00,
  0x00, 0x00, 0x48, 0x8b, 0xcb, 0xff, 0x90, 0xe0, 0x11, 0x00, 0x00, 0x33, 0xc9, 0x84, 0xc0, 0x48,
  0x0f, 0x44, 0xd9, 0x48, 0x85, 0xdb, 0x74, 0x31, 0x48, 0x8b, 0x8b, 0xc0, 0x02, 0x00, 0x00, 0x48,
  0x85, 0xc9, 0x74, 0x34, 0x48, 0x8b, 0x01, 0xba, 0x02, 0x00, 0x00, 0x00, 0xff, 0x50, 0x18, 0x84,
  0xc0, 0x74, 0x25, 0x48, 0x8b, 0x8b, 0xc0, 0x02, 0x00, 0x00, 0x48, 0x8b, 0x5c, 0x24, 0x30, 0x48,
  0x83, 0xc4, 0x20, 0x5f, 0xe9, false, false, false, false, 0x48, 0x8b, 0xd7, 0x48, 0x8d, 0x0d, false,
  false, false, false, 0xe8, false, false, false, false, 0x48, 0x8b, 0x5c, 0x24, 0x30, 0x48, 0x83, 0xc4,
  0x20, 0x5f, 0xc3 }
-- ResetConstructionMapModuleRotation(holomapid, cp_idx): same resolve, the plan vector at editor +0x300,
-- then the reset routine with the entry pointer
---@type (integer|false)[]
local RESET = { 0x48, 0x89, 0x5c, 0x24, 0x08, 0x48, 0x89, 0x6c, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57,
  0x48, 0x83, 0xec, 0x20, 0x48, 0x8b, 0xf2, 0x48, 0x8b, 0xf9, 0x48, 0x8b, 0xd1, 0x41, 0xb8, 0x04,
  0x00, 0x00, 0x00, 0x48, 0x8b, 0x0d, false, false, false, false, 0xe8, false, false, false, false, 0x48,
  0x8b, 0xd8, 0x48, 0x85, 0xc0, 0x0f, 0x84, 0xa7, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x00, 0xba, 0x3a,
  0x00, 0x00, 0x00, 0x48, 0x8b, 0xcb, 0xff, 0x90, 0xe0, 0x11, 0x00, 0x00, 0x33, 0xed, 0x84, 0xc0,
  0x48, 0x0f, 0x44, 0xdd, 0x48, 0x85, 0xdb, 0x0f, 0x84, 0x85, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x8b,
  0xc0, 0x02, 0x00, 0x00, 0x48, 0x85, 0xc9, 0x0f, 0x84, 0x84, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x01,
  0x8d, 0x55, 0x02, 0xff, 0x50, 0x18, 0x84, 0xc0, 0x74, 0x77, 0x48, 0x8b, 0x83, 0xc0, 0x02, 0x00,
  0x00, 0x48, 0x8b, 0xb8, 0x00, 0x03, 0x00, 0x00, 0x48, 0x85, 0xff, 0x74, 0x64, 0xba, 0xff, 0xff,
  0xff, 0xff, 0x48, 0x8b, 0xcf, 0xe8, false, false, false, false, 0x48, 0x3b, 0xf0, 0x73, 0x52, 0x48,
  0x8b, 0x0f, 0x48, 0x8b, 0x47, 0x08, 0x48, 0x2b, 0xc1, 0x48, 0xc1, 0xf8, 0x03, 0x48, 0x3b, 0xf0,
  0x73, 0x04, 0x48, 0x8b, 0x2c, 0xf1, 0x48, 0x8b, 0x8b, 0xc0, 0x02, 0x00, 0x00, 0x48, 0x85, 0xc9,
  0x74, 0x2f, 0x48, 0x8b, 0x01, 0xba, 0x02, 0x00, 0x00, 0x00, 0xff, 0x50, 0x18, 0x84, 0xc0, 0x74,
  0x20, 0x48, 0x8b, 0x8b, 0xc0, 0x02, 0x00, 0x00, 0x48, 0x8b, 0xd5, 0xe8, false, false, false, false,
  0xeb, 0x0f, 0x48, 0x8b, 0xd7, 0x48, 0x8d, 0x0d, false, false, false, false, 0xe8, false, false, false,
  false, 0x48, 0x8b, 0x5c, 0x24, 0x30, 0x48, 0x8b, 0x6c, 0x24, 0x38, 0x48, 0x8b, 0x74, 0x24, 0x40,
  0x48, 0x83, 0xc4, 0x20, 0x5f, 0xc3 }
-- inside the reset routine, +0x163: identity rows into +0x440..+0x460, then update(editor, 0, zero ray)
---@type (integer|false)[]
local UPDATE = { 0x4c, 0x8d, 0x05, false, false, false, false, 0x0f, 0x11, 0x87, 0x40, 0x04, 0x00, 0x00, 0x33, 0xd2,
  0x0f, 0x28, 0x0d, false, false, false, false, 0x48, 0x8b, 0xcf, 0x0f, 0x11, 0x8f, 0x50, 0x04, 0x00,
  0x00, 0x0f, 0x28, 0x05, false, false, false, false, 0x0f, 0x11, 0x87, 0x60, 0x04, 0x00, 0x00, 0xe8,
  false, false, false, false }
local UPDATE_AT = 0x163
-- inside the update, +0x266: module defaults of the first floating macro, then its connection vector +0x900/+0x908
---@type (integer|false)[]
local DEFAULTS = { 0x48, 0x8b, 0x9d, 0xa8, 0x02, 0x00, 0x00, 0x48, 0x8b, 0xcb, 0xe8, false, false, false, false,
  0x48, 0x8b, 0x88, 0x08, 0x09, 0x00, 0x00, 0x48, 0x89, 0x4c, 0x24, 0x70, 0x48, 0x8b, 0x80, 0x00, 0x09, 0x00,
  0x00 }
local DEFAULTS_AT = 0x266

-- nil: not located yet, false: unavailable, table: located
---@type table|false|nil
local engine
local zeroRay = ffi.new("float[32]")

local function matchBytes(p, bytes)
  for k = 1, #bytes do
    if bytes[k] and p[k - 1] ~= bytes[k] then return false end
  end
  return true
end

-- The exe image and its .text / .data ranges as RVAs.
local function mapImage(anchor)
  if ffi.os ~= "Windows" then return nil, "not the Windows build" end
  local a = anchor - anchor % 0x10000
  local base
  for _ = 1, 4096 do
    local p = ffi.cast(P, a)
    if p[0] == 0x4d and p[1] == 0x5a and u32(p + i32(p + 0x3c)) == 0x4550 then
      base = p
      break
    end
    a = a - 0x10000
  end
  if not base then return nil, "image base not found" end
  local pe = base + i32(base + 0x3c)
  local opt = pe + 24
  local img = { base = base, sec = {}, id = string.format("%x-%x", u32(pe + 8), u32(opt + 56)) }
  local s = opt + ffi.cast("uint16_t*", pe + 20)[0]
  for i = 0, ffi.cast("uint16_t*", pe + 6)[0] - 1 do
    local h = s + i * 40
    local n = {}
    for k = 0, 7 do
      if h[k] ~= 0 then n[#n + 1] = string.char(h[k]) end
    end
    local from, vsize, raw = u32(h + 12), u32(h + 8), u32(h + 16)
    img.sec[table.concat(n)] = { from = from, to = from + math.min(vsize, raw), vto = from + vsize }
  end
  if not (img.sec[".text"] and img.sec[".data"]) then return nil, "image sections missing" end
  return img
end

local function inText(img, rva, len)
  local t = img.sec[".text"]
  return rva >= t.from and rva + len <= t.to
end

-- target RVA of a rip-relative rel32 operand stored at rva
local function rel32(img, rva)
  return rva + 4 + i32(img.base + rva)
end

---@return table|false, string?
local function detect()
  local dropAnchor = ffi.cast("uintptr_t", C.AddFloatingSequenceToConstructionPlan)
  local resetAnchor = ffi.cast("uintptr_t", C.ResetConstructionMapModuleRotation)
  local img, why = mapImage(dropAnchor)
  if not img then return false, why end
  local base = ffi.cast("uintptr_t", img.base)
  local drop, reset = tonumber(dropAnchor - base), tonumber(resetAnchor - base)
  if not (inText(img, drop, #DROP) and matchBytes(img.base + drop, DROP)) then return false, "drop wrapper mismatch" end
  if not (inText(img, reset, #RESET) and matchBytes(img.base + reset, RESET)) then return false, "rotation reset wrapper mismatch" end
  local registry, resolver = rel32(img, drop + 0x13), rel32(img, drop + 0x1e)
  if registry ~= rel32(img, reset + 0x26) or resolver ~= rel32(img, reset + 0x2b) then return false, "wrappers disagree" end
  local d = img.sec[".data"]
  if registry < d.from or registry + 8 > d.vto then return false, "registry outside .data" end
  local routine = rel32(img, reset + 0xdc)
  local at = routine + UPDATE_AT
  if not (inText(img, at, #UPDATE) and matchBytes(img.base + at, UPDATE)) then return false, "update call mismatch" end
  local update = rel32(img, at + #UPDATE - 4)
  at = update + DEFAULTS_AT
  if not (inText(img, at, #DEFAULTS) and matchBytes(img.base + at, DEFAULTS)) then return false, "defaults call mismatch" end
  local defaults = rel32(img, at + 11)
  if not (inText(img, resolver, 16) and inText(img, update, 16) and inText(img, defaults, 16)) then return false, "target outside .text" end
  sab.Debug("engine located (%s): resolver 0x%x registry 0x%x update 0x%x defaults 0x%x", img.id, resolver, registry, update, defaults)
  return {
    resolve = ffi.cast("void*(*)(void*, uint64_t, uint32_t)", img.base + resolver),
    registry = ffi.cast("void**", img.base + registry),
    update = ffi.cast("void(*)(void*, uint8_t, const float*)", img.base + update),
    defaults = ffi.cast("void*(*)(void*)", img.base + defaults),
  }
end

local function locate()
  local ok, result, reason = pcall(detect)
  if not ok then
    result, reason = false, "error: " .. tostring(result)
  end
  engine = result
  if engine == false then sab.Error("engine access unavailable (%s)", tostring(reason)) end
end

local function vfunc(obj, offset, sig)
  local vt = ffi.cast("uint8_t**", obj)[0]
  return ffi.cast(sig, ffi.cast("void**", vt + offset)[0])
end

-- The station editor behind the menu's holomap, or nil.
function sab.Editor()
  if engine == nil then locate() end
  local menu = sab.menu
  if not (engine and menu and menu.holomap ~= 0) then return nil end
  local holo = engine.resolve(engine.registry[0], menu.holomap, 4)
  if holo == nil then return nil end
  if vfunc(holo, 0x11e0, "uint8_t(*)(void*, int32_t)")(holo, 0x3a) == 0 then return nil end
  local editor = ffi.cast("uint8_t**", ffi.cast(P, holo) + 0x2c0)[0]
  if editor == nil then return nil end
  if vfunc(editor, 0x18, "uint8_t(*)(void*, int32_t)")(editor, 2) == 0 then return nil end
  return editor
end

-- MSVC std::string at p
local function stdString(p)
  local size, cap = tonumber(u64(p + 0x10)), tonumber(u64(p + 0x18))
  if size > 1024 then return nil end
  return ffi.string(cap > 15 and ffi.cast("const char**", p)[0] or ffi.cast("const char*", p), size)
end

-- 4x4 float transform at p: translation then three rotation rows
local function readTransform(p)
  local f = ffi.cast("float*", p)
  return { x = f[0], y = f[1], z = f[2],
    rows = { { f[4], f[5], f[6] }, { f[8], f[9], f[10] }, { f[12], f[13], f[14] } } }
end

function sab.ReadFloating(editor)
  return readTransform(editor + 0x430)
end

-- pos = { x, y, z } in the plan's frame; rows = three { x, y, z } or nil to keep the rotation
function sab.WriteFloating(editor, pos, rows)
  local f = ffi.cast("float*", editor + 0x430)
  f[0], f[1], f[2] = pos.x, pos.y, pos.z
  if rows then
    for r = 1, 3 do
      f[r * 4], f[r * 4 + 1], f[r * 4 + 2] = rows[r][1], rows[r][2], rows[r][3]
    end
  end
end

-- Plan entries as the editor holds them: macro and transform, built ones included.
function sab.EntryPose(editor, idx)
  local vec = ffi.cast("uint8_t**", editor + 0x300)[0]
  if vec == nil then return nil end
  local first, last = ffi.cast("uint8_t**", vec)[0], ffi.cast("uint8_t**", vec + 8)[0]
  local n = tonumber((ffi.cast("uintptr_t", last) - ffi.cast("uintptr_t", first)) / 8)
  if idx < 0 or idx >= n then return nil end
  local e = ffi.cast("uint8_t**", first)[idx]
  if e == nil then return nil end
  local macro = ffi.cast("uint8_t**", e + 8)[0]
  local pose = readTransform(e + 0x30)
  pose.macro = macro ~= nil and stdString(macro + 0x20) or nil
  pose.macroPtr = macro
  pose.count = n
  return pose
end

-- The macro of the first floating entry, or nil.
function sab.FloatingMacro(editor)
  local vec = ffi.cast("uint8_t**", editor + 0x3c0)[0]
  if vec == nil then return nil end
  local first, last = ffi.cast("uint8_t**", vec)[0], ffi.cast("uint8_t**", vec + 8)[0]
  if first == nil or first == last then return nil end
  local e = ffi.cast("uint8_t**", first)[0]
  if e == nil then return nil end
  return ffi.cast("uint8_t**", e + 8)[0]
end

-- A macro's snap connections from its module defaults: name, position and direction in the macro's frame.
function sab.Connections(macro)
  local list = {}
  if macro == nil then return list end
  local d = ffi.cast(P, engine.defaults(macro))
  if d == nil then return list end
  local first, last = ffi.cast("uint8_t**", d + 0x900)[0], ffi.cast("uint8_t**", d + 0x908)[0]
  if first == nil then return list end
  local n = tonumber((ffi.cast("uintptr_t", last) - ffi.cast("uintptr_t", first)) / 8)
  if n < 0 or n > 256 then return list end
  for i = 0, n - 1 do
    local c = ffi.cast("uint8_t**", first)[i]
    if c ~= nil then
      local m = ffi.cast("uint8_t**", c + 0xa0)[0]
      if m == nil then m = c + 0x60 end
      local t = readTransform(m)
      list[#list + 1] = { name = stdString(c + 0x10), pos = { t.x, t.y, t.z }, dir = t.rows[3], rows = t.rows }
    end
  end
  return list
end

-- *** pose math ***
-- The engine's transforms are row-major: world = local.x * row1 + local.y * row2 + local.z * row3 + translation.

local function rotate(v, rows)
  return { v[1] * rows[1][1] + v[2] * rows[2][1] + v[3] * rows[3][1],
    v[1] * rows[1][2] + v[2] * rows[2][2] + v[3] * rows[3][2],
    v[1] * rows[1][3] + v[2] * rows[2][3] + v[3] * rows[3][3] }
end

local function cross(a, b)
  return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end

local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end

local function unit(v)
  local l = math.sqrt(dot(v, v))
  if l < 1e-6 then return { 0, 0, 1 } end
  return { v[1] / l, v[2] / l, v[3] / l }
end

-- Rows of the rotation that turns unit vector a onto unit vector b (Rodrigues; any axis for a = -b).
local function rowsFromTo(a, b)
  local k, c = cross(a, b), dot(a, b)
  local s = math.sqrt(dot(k, k))
  if s < 1e-6 then
    if c > 0 then return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } end
    k = cross(a, math.abs(a[1]) < 0.9 and { 1, 0, 0 } or { 0, 1, 0 })
    s, c = 0, -1
  end
  k = unit(k)
  local rows = {}
  for i = 1, 3 do
    local e = { 0, 0, 0 }
    e[i] = 1
    local kxe, kde = cross(k, e), dot(k, e)
    rows[i] = { e[1] * c + kxe[1] * s + k[1] * kde * (1 - c),
      e[2] * c + kxe[2] * s + k[2] * kde * (1 - c),
      e[3] * c + kxe[3] * s + k[3] * kde * (1 - c) }
  end
  return rows
end

-- One entry's connections in the plan frame: { entryIdx, macro, name, pos, dir, used }.
local function connectionsOf(entryIdx, macroName, pose, usedNames)
  local list = {}
  for _, c in ipairs(sab.Connections(pose.macroPtr)) do
    local p = rotate(c.pos, pose.rows)
    list[#list + 1] = { entryIdx = entryIdx, macro = macroName, name = c.name,
      pos = { p[1] + pose.x, p[2] + pose.y, p[3] + pose.z }, dir = unit(rotate(c.dir, pose.rows)),
      used = usedNames and usedNames[c.name] or false }
  end
  return list
end

-- Every entry's connections in the plan frame with the used ones marked.
function sab.PlanConnections(editor)
  local plan = sab.ReadPlan()
  local used = {}
  for _, e in ipairs(plan) do
    if e.connection ~= "" then
      used[e.idx] = used[e.idx] or {}
      used[e.idx][e.connection] = true
    end
    if e.predecessorConnection ~= "" then
      used[e.predecessorIdx] = used[e.predecessorIdx] or {}
      used[e.predecessorIdx][e.predecessorConnection] = true
    end
  end
  local list = {}
  for _, e in ipairs(plan) do
    local pose = sab.EntryPose(editor, e.idx)
    if pose then
      for _, c in ipairs(connectionsOf(e.idx, e.macro, pose, used[e.idx])) do list[#list + 1] = c end
    end
  end
  return list
end

-- The module pose that puts moduleConn onto a station connection at world sPos pointing along sDir,
-- directions opposed: { pos = { x, y, z }, rows }. The engine quantises the roll about the axis itself.
function sab.PoseForWorld(sPos, sDir, moduleConn)
  local rows = rowsFromTo(unit(moduleConn.dir), { -sDir[1], -sDir[2], -sDir[3] })
  local mPos = rotate(moduleConn.pos, rows)
  return { pos = { x = sPos[1] - mPos[1], y = sPos[2] - mPos[2], z = sPos[3] - mPos[3] }, rows = rows }
end

function sab.PoseForPair(entryPose, stationConn, moduleConn)
  local eRows = entryPose.rows
  local sPos = rotate(stationConn.pos, eRows)
  return sab.PoseForWorld({ sPos[1] + entryPose.x, sPos[2] + entryPose.y, sPos[3] + entryPose.z },
    unit(rotate(stationConn.dir, eRows)), moduleConn)
end

-- Run the editor's update without a cursor: the snap search from the floating transform as written.
-- A target entry pointer at +0x4b8.. means the nearest compatible pair inside the snap radius was found.
function sab.Snap(editor)
  engine.update(editor, 0, zeroRay)
  local r = { snapped = ffi.cast("uint8_t**", editor + 0x4c0)[0] ~= nil, valid = editor[0x4b0] ~= 0 }
  if r.snapped then
    r.entryIdx = tonumber(u64(editor + 0x4b8))
    local modConn, stationConn = ffi.cast("uint8_t**", editor + 0x4c8)[0], ffi.cast("uint8_t**", editor + 0x4d0)[0]
    r.connection = modConn ~= nil and stdString(modConn + 0x10) or nil
    r.predecessorConnection = stationConn ~= nil and stdString(stationConn + 0x10) or nil
    r.pose = readTransform(editor + 0x470)
  end
  return r
end

-- *** one placement ***
-- Frame 1: float the macro. Frame 2: write its transform, run the editor's snap search, drop, all in
-- one chunk, so the drag code's cursor write never reaches the search and the nearest compatible pair
-- to the written pose wins. The editor refuses a drop in the frame the module was floated.

local function beginPlacement(run, item)
  local menu = sab.menu
  run.countBefore = tonumber(C.GetNumBuildMapConstructionPlan(menu.holomap, false))
  C.AddMacroToConstructionMap(menu.holomap, item.macro, true)
  menu.floatingNewModule = item.macro
  run.phase = "drop"
end

local function finishPlacement(run, item)
  local menu = sab.menu
  local editor = sab.Editor()
  if not editor then
    C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
    menu.floatingNewModule = nil
    run.failed = run.failed + 1
    sab.Error("no editor for %s", item.macro)
    return false
  end
  local pos, rows, pair = item.pos, item.rows, item.pair
  if pair then
    local entry = sab.EntryPose(editor, pair.entryIdx)
    local stationConn, moduleConn
    for _, c in ipairs(entry and sab.Connections(entry.macroPtr) or {}) do
      if c.name == pair.predecessorConnection then stationConn = c end
    end
    for _, c in ipairs(sab.Connections(sab.FloatingMacro(editor))) do
      if c.name == pair.connection then moduleConn = c end
    end
    if not (entry and stationConn and moduleConn) then
      C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
      menu.floatingNewModule = nil
      run.failed = run.failed + 1
      sab.Debug("no such pair for %s: entry %d %s / %s", item.macro, pair.entryIdx, tostring(pair.predecessorConnection), tostring(pair.connection))
      return false
    end
    local pose = sab.PoseForPair(entry, stationConn, moduleConn)
    pos, rows = pose.pos, pose.rows
  end
  sab.WriteFloating(editor, pos, rows)
  local snap = sab.Snap(editor)
  local wrongEntry = snap.snapped and ((item.entryIdx and snap.entryIdx ~= item.entryIdx)
    or (pair and (snap.entryIdx ~= pair.entryIdx or snap.connection ~= pair.connection or snap.predecessorConnection ~= pair.predecessorConnection)))
  if (snap.snapped and not wrongEntry) or (item.free and snap.valid) then
    C.AddFloatingSequenceToConstructionPlan(menu.holomap)
  end
  local count = tonumber(C.GetNumBuildMapConstructionPlan(menu.holomap, false))
  if count > run.countBefore then
    local plan = sab.ReadPlan()
    local added = plan[#plan]
    menu.floatingNewModule = nil
    run.placed = run.placed + 1
    applyDefaultLoadout(added)
    sab.Debug("placed %s as entry %d: %s on entry %d %s at %.0f %.0f %.0f", item.macro, added.idx, added.connection, added.predecessorIdx, added.predecessorConnection, added.offset.x, added.offset.y, added.offset.z)
    return true
  end
  C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
  menu.floatingNewModule = nil
  run.failed = run.failed + 1
  if wrongEntry then
    sab.Debug("%s at %.0f %.0f %.0f snapped to entry %d %s / %s instead", item.macro, pos.x, pos.y, pos.z, snap.entryIdx, snap.predecessorConnection, snap.connection)
  elseif snap.snapped then
    sab.Debug("%s on entry %d rejected by the editor (valid %s)", item.macro, snap.entryIdx, tostring(snap.valid))
  else
    sab.Debug("no snap for %s at %.0f %.0f %.0f", item.macro, pos.x, pos.y, pos.z)
  end
  return false
end

-- *** packing ***
-- A pack item goes onto the free station connection that keeps the plan compact: candidates are every
-- free connection x every connection of the module, nearest module centre to the plan's anchor first,
-- pre-checked in Lua against the plot and the placed boxes; the engine's snap (tags) and valid flag
-- (collision) give the verdict. Outer modules take outward connections only and keep a clearance.

local OUTER = { dockarea = 1000, pier = 2000, buildmodule = 2000, defencemodule = 1000, ventureplatform = 1000 }
local TRIES_PER_FRAME, CHECKS_PER_FRAME = 8, 400

local function outerMargin(macro)
  for class, margin in pairs(OUTER) do
    if IsMacroClass(macro, class) then return margin end
  end
  return nil
end

-- World AABB of a size record through a pose (pos as an array).
local function worldBox(size, pos, rows)
  local box = { min = { math.huge, math.huge, math.huge }, max = { -math.huge, -math.huge, -math.huge } }
  for sx = -1, 1, 2 do
    for sy = -1, 1, 2 do
      for sz = -1, 1, 2 do
        local w = rotate({ size.cX + sx * size.maxX, size.cY + sy * size.maxY, size.cZ + sz * size.maxZ }, rows)
        for i = 1, 3 do
          local v = w[i] + pos[i]
          if v < box.min[i] then box.min[i] = v end
          if v > box.max[i] then box.max[i] = v end
        end
      end
    end
  end
  return box
end

local function overlaps(a, b, margin)
  for i = 1, 3 do
    if a.min[i] - margin >= b.max[i] or a.max[i] + margin <= b.min[i] then return false end
  end
  return true
end

local function inside(a, b)
  for i = 1, 3 do
    if a.min[i] < b.min[i] or a.max[i] > b.max[i] then return false end
  end
  return true
end

local function addEntry(run, idx, macro, pose)
  run.n = run.n + 1
  run.sum[1], run.sum[2], run.sum[3] = run.sum[1] + pose.x, run.sum[2] + pose.y, run.sum[3] + pose.z
  local size = sab.sizes[macro]
  if size then run.boxes[idx] = worldBox(size, { pose.x, pose.y, pose.z }, pose.rows) end
end

-- The plan's connections, boxes, anchor and plot at the start of a run.
local function readPlanState(run, editor)
  local menu = sab.menu
  run.conns = sab.PlanConnections(editor)
  run.boxes, run.sum, run.n = {}, { 0, 0, 0 }, 0
  for _, e in ipairs(sab.ReadPlan()) do
    local pose = sab.EntryPose(editor, e.idx)
    if pose then addEntry(run, e.idx, e.macro, pose) end
  end
  local size, centre = C.GetBuildPlotSize(menu.container), C.GetBuildPlotCenterOffset(menu.container)
  run.plot = { min = { centre.x - size.x / 2, centre.y - size.y / 2, centre.z - size.z / 2 },
    max = { centre.x + size.x / 2, centre.y + size.y / 2, centre.z + size.z / 2 } }
end

local function anchorOf(run)
  if run.n == 0 then
    local p = run.plot
    return { (p.min[1] + p.max[1]) / 2, (p.min[2] + p.max[2]) / 2, (p.min[3] + p.max[3]) / 2 }
  end
  return { run.sum[1] / run.n, run.sum[2] / run.n, run.sum[3] / run.n }
end

local function buildCandidates(run, item, editor)
  local anchor = anchorOf(run)
  local mconns = sab.Connections(sab.FloatingMacro(editor))
  local size = sab.sizes[item.macro]
  local list = {}
  for _, f in ipairs(run.conns) do
    if not f.used and (not item.margin or dot(f.dir, { f.pos[1] - anchor[1], f.pos[2] - anchor[2], f.pos[3] - anchor[3] }) > 0) then
      for _, m in ipairs(mconns) do
        local key = f.macro .. "|" .. f.name .. "|" .. item.macro .. "|" .. m.name
        if not sab.incompatible[key] then
          local pose = sab.PoseForWorld(f.pos, f.dir, m)
          local c = { pose.pos.x, pose.pos.y, pose.pos.z }
          if size then
            local cc = rotate({ size.cX, size.cY, size.cZ }, pose.rows)
            c = { c[1] + cc[1], c[2] + cc[2], c[3] + cc[3] }
          end
          local d = { c[1] - anchor[1], c[2] - anchor[2], c[3] - anchor[3] }
          list[#list + 1] = { f = f, m = m, key = key, pose = pose, score = dot(d, d) }
        end
      end
    end
  end
  table.sort(list, function(a, b) return a.score < b.score end)
  item.candidates, item.cursor = list, 1
  sab.Debug("%s: %d candidates, %d module connections, anchor %.0f %.0f %.0f", item.macro, #list, #mconns, anchor[1], anchor[2], anchor[3])
end

-- The Lua pre-check: inside the plot, clear of every placed box but the one it attaches to.
local function boxOk(run, item, cand)
  local size = sab.sizes[item.macro]
  if not size then return true end
  local box = worldBox(size, { cand.pose.pos.x, cand.pose.pos.y, cand.pose.pos.z }, cand.pose.rows)
  if not inside(box, run.plot) then return false, "plot" end
  local margin = item.margin or -5
  for idx, b in pairs(run.boxes) do
    if idx ~= cand.f.entryIdx and overlaps(box, b, margin) then return false, "overlap" end
  end
  return true
end

local function skip(item, reason)
  item.skips = item.skips or { plot = 0, overlap = 0, incompatible = 0, rejected = 0, refused = 0 }
  item.skips[reason] = item.skips[reason] + 1
end

local function addPlacement(run, editor, added, cand)
  local pose = sab.EntryPose(editor, added.idx)
  if not pose then return end
  addEntry(run, added.idx, added.macro, pose)
  cand.f.used = true
  for _, c in ipairs(connectionsOf(added.idx, added.macro, pose, { [added.connection] = true })) do
    run.conns[#run.conns + 1] = c
  end
end

-- One frame of attempts for a pack item: "placed", "more" or "exhausted".
local function tryCandidates(run, item, editor)
  local menu = sab.menu
  local tries, checks = 0, 0
  while tries < TRIES_PER_FRAME and checks < CHECKS_PER_FRAME do
    local cand = item.candidates[item.cursor]
    if not cand then return "exhausted" end
    item.cursor = item.cursor + 1
    checks = checks + 1
    local ok, reason = boxOk(run, item, cand)
    if not ok then
      skip(item, reason)
    else
      tries = tries + 1
      sab.WriteFloating(editor, cand.pose.pos, cand.pose.rows)
      local snap = sab.Snap(editor)
      if snap.snapped and snap.entryIdx == cand.f.entryIdx and snap.connection == cand.m.name and snap.predecessorConnection == cand.f.name then
        if snap.valid then
          C.AddFloatingSequenceToConstructionPlan(menu.holomap)
          if tonumber(C.GetNumBuildMapConstructionPlan(menu.holomap, false)) > run.countBefore then
            local plan = sab.ReadPlan()
            local added = plan[#plan]
            menu.floatingNewModule = nil
            run.placed = run.placed + 1
            applyDefaultLoadout(added)
            addPlacement(run, editor, added, cand)
            sab.Debug("placed %s as entry %d: %s on entry %d %s (%s) at %.0f %.0f %.0f, candidate %d", item.macro, added.idx,
              added.connection, added.predecessorIdx, added.predecessorConnection, cand.f.macro, added.offset.x, added.offset.y, added.offset.z, item.cursor - 1)
            return "placed"
          end
          skip(item, "refused")
          sab.Trace("%s: drop refused on entry %d %s / %s", item.macro, cand.f.entryIdx, cand.f.name, cand.m.name)
        else
          skip(item, "rejected")
          sab.Trace("%s: entry %d %s / %s rejected by the editor", item.macro, cand.f.entryIdx, cand.f.name, cand.m.name)
        end
      else
        sab.incompatible[cand.key] = true
        skip(item, "incompatible")
        sab.Trace("%s: %s / %s on %s incompatible", item.macro, cand.f.name, cand.m.name, cand.f.macro)
      end
    end
  end
  return "more"
end

local function advance(run)
  run.next = run.next + 1
  run.phase = "begin"
end

-- The drop phase of a pack item; the module stays floated across frames while candidates remain.
local function packStep(run, item)
  local menu = sab.menu
  local editor = sab.Editor()
  if not editor then
    C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
    menu.floatingNewModule = nil
    run.failed = run.failed + 1
    sab.Error("no editor for %s", item.macro)
    advance(run)
    return
  end
  if not item.candidates then buildCandidates(run, item, editor) end
  local result = tryCandidates(run, item, editor)
  if result == "more" then return end
  if result == "placed" then
    advance(run)
    return
  end
  C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
  menu.floatingNewModule = nil
  local connector = run.connector
  if connector and connector.budget > 0 and not item.connectorTried and not item.isConnector then
    item.connectorTried, item.candidates = true, nil
    connector.budget = connector.budget - 1
    table.insert(run.items, run.next, { macro = connector.macro, pack = true, isConnector = true })
    sab.Debug("%s: no place, inserting %s first", item.macro, connector.macro)
    run.phase = "begin"
    return
  end
  run.failed = run.failed + 1
  local s = item.skips or {}
  sab.Debug("%s: no place found among %d candidates: plot %d, overlap %d, incompatible %d, rejected %d, refused %d", item.macro,
    #item.candidates, s.plot or 0, s.overlap or 0, s.incompatible or 0, s.rejected or 0, s.refused or 0)
  advance(run)
end

-- A connection module blueprint of the race, a cross when there is one; any race when race is nil.
local function connectorOfRace(race)
  local first
  for _, m in ipairs(sab.menu.modules and sab.menu.modules.moduletypes_other or {}) do
    if IsMacroClass(m, "connectionmodule") then
      local mr = GetMacroData(m, "makerraceid")
      for _, r in ipairs(type(mr) == "table" and mr or { mr }) do
        if race == nil or r == race then
          if string.find(m, "cross", 1, true) then return m end
          first = first or m
        end
      end
    end
  end
  return first
end

local function raceOf(macro)
  local races = GetMacroData(macro, "makerraceid")
  return type(races) == "table" and races[1] or races
end

-- The connector for a bill without one: the macro's maker race, else a race already in the plan, else any.
local function defaultConnector(macro)
  local race = raceOf(macro)
  local found = race and connectorOfRace(race)
  if found then return found end
  for _, e in ipairs(sab.ReadPlan()) do
    race = raceOf(e.macro)
    found = race and connectorOfRace(race)
    if found then return found end
  end
  return connectorOfRace(nil)
end

-- *** the run ***
-- A run is a list of items, one placement per two menu updates at least. An item is { macro, pack = true }
-- for the packer, { macro, pair = { entryIdx, predecessorConnection, connection } } for a chosen pair, or
-- { macro, pos = { x, y, z } in the plan's frame, rows = rotation or nil, entryIdx = the entry the snap
-- must land on or nil, free = drop without a snap } for a pose.

-- A bill { { macro, count } } becomes pack items: inner modules first, largest first, then the outer ones.
-- Connectors in the bill set the insertion budget and type instead of being items.
function sab.StartBill(bill)
  local menu = sab.menu
  if not (menu and menu.shown and menu.holomap ~= 0) then
    sab.Error("the build menu is not open")
    return false
  end
  sab.ReadSizes()
  local items, connector = {}, nil
  for _, b in ipairs(bill) do
    local count = tonumber(b.count) or 1
    if IsMacroClass(b.macro, "connectionmodule") then
      connector = { macro = b.macro, budget = (connector and connector.budget or 0) + count }
    else
      local size = sab.sizes[b.macro]
      for _ = 1, count do
        items[#items + 1] = { macro = b.macro, pack = true, margin = outerMargin(b.macro),
          volume = size and size.maxX * size.maxY * size.maxZ or 0 }
      end
    end
  end
  table.sort(items, function(a, b)
    if (a.margin ~= nil) ~= (b.margin ~= nil) then return a.margin == nil end
    return a.volume > b.volume
  end)
  if not connector and items[1] then
    local macro = defaultConnector(items[1].macro)
    if macro then connector = { macro = macro, budget = #items } end
  end
  if items[1] and tonumber(C.GetNumBuildMapConstructionPlan(menu.holomap, false)) == 0 then
    local centre = C.GetBuildPlotCenterOffset(menu.container)
    items[1].pack, items[1].free, items[1].pos = nil, true, { x = centre.x, y = centre.y, z = centre.z }
  end
  return sab.StartRun(items, connector)
end

function sab.StartRun(items, connector)
  if sab.run then
    sab.Error("a run is already active")
    return false
  end
  local menu = sab.menu
  if not (menu and menu.shown and menu.holomap ~= 0) then
    sab.Error("the build menu is not open")
    return false
  end
  local editor = sab.Editor()
  if not editor then
    sab.Error("the editor is not reachable")
    return false
  end
  local run = { items = items, next = 1, phase = "begin", placed = 0, failed = 0, connector = connector }
  sab.ReadSizes()
  readPlanState(run, editor)
  sab.run = run
  sab.Debug("run started: %d items, %d entries, %d connections, connector %s x %d", #items, run.n, #run.conns,
    connector and connector.macro or "none", connector and connector.budget or 0)
  return true
end

-- Undo the last n map changes, newest first.
function sab.Undo(n)
  local menu = sab.menu
  for _ = 1, n or 1 do
    if not C.CanUndoConstructionMapChange(menu.holomap) then break end
    C.UndoConstructionMapChange(menu.holomap)
  end
  menu.refreshPlan()
  menu.displayMenu()
end

function sab.StopRun(reason)
  local run = sab.run
  if not run then return end
  local menu = sab.menu
  if run.phase == "drop" then
    C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
    menu.floatingNewModule = nil
  end
  sab.run = nil
  sab.Debug("run %s: %d placed, %d failed", reason or "finished", run.placed, run.failed)
  sab.lastRun = { placed = run.placed, failed = run.failed,
    planCount = tonumber(C.GetNumBuildMapConstructionPlan(menu.holomap, false)) }
  -- what the vanilla drop handler does after a mouse-driven placement; "last" selects the newest plan row
  menu.storePlanTableState()
  ---@diagnostic disable-next-line: inject-field
  if run.placed > 0 then menu.selectedRows.plan = "last" end
  menu.refreshPlan()
  menu.displayMenu()
end

-- One step per menu update.
function sab.Tick()
  local run = sab.run
  if not run then return end
  local menu = sab.menu
  if not (menu.shown and menu.holomap ~= 0) then
    sab.run = nil
    sab.Debug("run aborted: the build menu closed")
    return
  end
  if run.phase == "begin" then
    local item = run.items[run.next]
    if not item then
      sab.StopRun("finished")
      return
    end
    beginPlacement(run, item)
  else
    local item = run.items[run.next]
    if item.pack then
      packStep(run, item)
    else
      finishPlacement(run, item)
      advance(run)
    end
  end
end

-- *** panel ***
-- An own frame on a layer the build menu leaves free, rebuilt with the menu's info frame and when the
-- bill changes. The progress text and the button states are cell functions, so a run needs no rebuild.

local PANEL_LAYER = 3
local PAGE = 1972092448
-- the left-bar categories of the build menu with vanilla's names
local CATEGORIES = {
  { mode = "moduletypes_production", text = 2421 },
  { mode = "moduletypes_build", text = 2439 },
  { mode = "moduletypes_storage", text = 2422 },
  { mode = "moduletypes_habitation", text = 2451 },
  { mode = "moduletypes_welfare", text = 9620 },
  { mode = "moduletypes_dock", text = 2452 },
  { mode = "moduletypes_defence", text = 2424 },
  { mode = "moduletypes_processing", text = 9621 },
  { mode = "moduletypes_other", text = 2453 },
  { mode = "moduletypes_venture", text = 2454 },
}

-- { mode, macro, count } rows, kept across menu openings; the last run for Undo run
sab.bill = {}
sab.lastRun = nil
sab.panelDirty = nil

local function categoryOptions()
  local options = {}
  for _, cat in ipairs(CATEGORIES) do
    local macros = sab.menu.modules[cat.mode]
    if macros and #macros > 0 then
      options[#options + 1] = { id = cat.mode, text = ReadText(1001, cat.text), icon = "", displayremoveoption = false }
    end
  end
  return options
end

local function moduleOptions(mode)
  local options = {}
  for _, macro in ipairs(sab.menu.modules[mode] or {}) do
    local name, makericon = GetMacroData(macro, "name", "makericon")
    local prefix = ""
    if type(makericon) == "table" then
      for _, icon in ipairs(makericon) do prefix = prefix .. "\27[" .. icon .. "]" end
    end
    options[#options + 1] = { id = macro, text = prefix .. " " .. tostring(name), icon = "", displayremoveoption = false }
  end
  return options
end

function sab.AddBillRow()
  local options = categoryOptions()
  if #options == 0 then return end
  local last = sab.bill[#sab.bill]
  local mode = last and last.mode or options[1].id
  sab.bill[#sab.bill + 1] = { mode = mode, macro = (sab.menu.modules[mode] or {})[1], count = 1 }
  sab.panelDirty = true
end

function sab.RouteOk()
  return sab.Editor() ~= nil
end

-- Undo run is offered while the plan still has the count the run left behind.
function sab.CanUndoRun()
  local menu, last = sab.menu, sab.lastRun
  if sab.run or not last or last.placed == 0 or menu.holomap == 0 then return false end
  local unchanged = tonumber(C.GetNumBuildMapConstructionPlan(menu.holomap, false)) == last.planCount
  return unchanged and C.CanUndoConstructionMapChange(menu.holomap)
end

function sab.UndoRun()
  if not sab.CanUndoRun() then return end
  local n = sab.lastRun.placed
  sab.lastRun = nil
  sab.Undo(n)
end

function sab.RunBill()
  local bill = {}
  for _, row in ipairs(sab.bill) do
    if row.macro then bill[#bill + 1] = { macro = row.macro, count = row.count } end
  end
  if #bill == 0 then return end
  if sab.StartBill(bill) then sab.panelDirty = true end
end

local function progressText()
  local run = sab.run
  if run then
    return string.format(tostring(ReadText(PAGE, 106)), run.placed, run.failed, math.max(0, #run.items - run.next + 1))
  end
  if not sab.RouteOk() then return ReadText(PAGE, 108) end
  local last = sab.lastRun
  if last then return string.format(tostring(ReadText(PAGE, 107)), last.placed, last.failed) end
  return ""
end

function sab.DisplayPanel()
  local menu = sab.menu
  if not (menu.shown and menu.titleData and menu.titleData.width) then return end
  Helper.clearDataForRefresh(menu, PANEL_LAYER)
  local idle = sab.run == nil
  local buttonHeight = Helper.standardButtonHeight

  local width = math.floor(menu.titleData.width * 0.6)
  local x = menu.titleData.offsetX + menu.titleData.width - width
  local y = menu.titleData.offsetY + menu.titleData.height + 2 * Helper.borderSize
  local frame = Helper.createFrameHandle(menu, {
    layer = PANEL_LAYER, standardButtons = {}, width = width, x = x, y = y, autoFrameHeight = true,
  })
  frame:setBackground("solid", { color = Color["frame_background_semitransparent"] })
  sab.panelFrame = frame

  local ftable = frame:addTable(4, { tabOrder = 1, highlightMode = "off", reserveScrollBar = false,
    maxVisibleHeight = Helper.viewHeight - y - Helper.frameBorder })
  ftable:setColWidthPercent(1, 30)
  ftable:setColWidth(3, Helper.scaleX(50), false)
  ftable:setColWidth(4, Helper.scaleY(buttonHeight), false)

  local title = ftable:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  title[1]:setColSpan(4):createText(ReadText(PAGE, 100), Helper.headerRowCenteredProperties)

  local header = ftable:addRow(false, {})
  header[1]:createText(ReadText(PAGE, 101), Helper.subHeaderTextProperties)
  header[2]:createText(ReadText(1001, 56), Helper.subHeaderTextProperties)
  header[3]:setColSpan(2):createText(ReadText(PAGE, 102), Helper.subHeaderTextProperties)

  local catOptions = categoryOptions()
  for i, entry in ipairs(sab.bill) do
    local row = ftable:addRow(true, {})
    row[1]:createDropDown(catOptions, { startOption = entry.mode, height = buttonHeight, active = idle })
    row[1].handlers.onDropDownConfirmed = function(_, id)
      if id ~= entry.mode then
        entry.mode = id
        entry.macro = (menu.modules[id] or {})[1]
        sab.panelDirty = true
      end
    end
    row[2]:createDropDown(moduleOptions(entry.mode), { startOption = entry.macro or "", height = buttonHeight, active = idle })
    row[2].handlers.onDropDownConfirmed = function(_, id) entry.macro = id end
    row[3]:createEditBox({ height = buttonHeight, active = idle }):setText(tostring(entry.count), { halign = "center" })
    row[3].handlers.onEditBoxDeactivated = function(_, text, textchanged)
      if textchanged then
        entry.count = math.max(1, math.min(99, math.floor(tonumber(text) or 1)))
        sab.panelDirty = true
      end
    end
    row[4]:createButton({ height = buttonHeight, active = idle, mouseOverText = ReadText(1001, 6702) }):setText("X", { halign = "center" })
    row[4].handlers.onClick = function()
      table.remove(sab.bill, i)
      sab.panelDirty = true
    end
  end

  local btable = frame:addTable(4, { tabOrder = 2, highlightMode = "off", reserveScrollBar = false,
    y = ftable.properties.y + ftable:getFullHeight() + Helper.borderSize })
  local row = btable:addRow(true, {})
  row[1]:createButton({ height = buttonHeight, active = idle and #catOptions > 0 }):setText(ReadText(1001, 3106), { halign = "center" })
  row[1].handlers.onClick = sab.AddBillRow
  row[2]:createButton({ height = buttonHeight, active = idle and #sab.bill > 0 }):setText(ReadText(1001, 5706), { halign = "center" })
  row[2].handlers.onClick = function()
    sab.bill = {}
    sab.panelDirty = true
  end
  local function canRun() return sab.run == nil and #sab.bill > 0 and sab.RouteOk() end
  row[3]:createButton({ height = buttonHeight, active = canRun }):setText(ReadText(PAGE, 103), { halign = "center" })
  row[3].handlers.onClick = sab.RunBill
  row[4]:createButton({ height = buttonHeight, active = function() return sab.run ~= nil end }):setText(ReadText(PAGE, 104), { halign = "center" })
  row[4].handlers.onClick = function() sab.StopRun("stopped") end

  row = btable:addRow(true, {})
  row[1]:createButton({ height = buttonHeight, active = sab.CanUndoRun }):setText(ReadText(PAGE, 105), { halign = "center" })
  row[1].handlers.onClick = sab.UndoRun
  row[2]:setColSpan(3):createText(progressText, { halign = "left", minRowHeight = buttonHeight })

  frame:display()
end

-- *** build menu hooks ***

local function hookMenu()
  for _, menu in ipairs(Menus) do
    if menu.name == MENU_NAME then
      sab.menu = menu
      break
    end
  end
  if not sab.menu then
    sab.Error("menu %s not found", MENU_NAME)
    return
  end
  local menu = sab.menu
  local onUpdate = menu.onUpdate
  menu.onUpdate = function(...)
    onUpdate(...)
    if sab.run then
      local ok, err = pcall(sab.Tick)
      if not ok then
        sab.Error("tick failed: %s", tostring(err))
        sab.run = nil
      end
    end
    if sab.panelDirty and menu.shown then
      sab.panelDirty = nil
      local ok, err = pcall(sab.DisplayPanel)
      if not ok then sab.Error("panel failed: %s", tostring(err)) end
    end
    -- function cells (progress, button states) are re-evaluated only by the frame's own update, as vanilla does per frame
    if sab.panelFrame and menu.shown then
      local ok, err = pcall(sab.panelFrame.update, sab.panelFrame)
      if not ok then
        sab.Error("panel update failed: %s", tostring(err))
        sab.panelFrame = nil
      end
    end
  end
  -- the panel goes up before the info frame, so vanilla's frame keeps the focus it expects
  local displayMenu = menu.displayMenu
  menu.displayMenu = function(...)
    local ok, err = pcall(sab.DisplayPanel)
    if not ok then sab.Error("panel failed: %s", tostring(err)) end
    return displayMenu(...)
  end
  local viewCreated = menu.viewCreated
  menu.viewCreated = function(layer, ...)
    if layer == PANEL_LAYER then
      sab.panelTables = { ... }
      return
    end
    return viewCreated(layer, ...)
  end
  local cleanup = menu.cleanup
  menu.cleanup = function(...)
    sab.run, sab.lastRun, sab.panelDirty, sab.panelTables, sab.panelFrame = nil, nil, nil, nil, nil
    return cleanup(...)
  end
  local onCloseElement = menu.onCloseElement
  menu.onCloseElement = function(...)
    if sab.run then sab.StopRun("menu closed") end
    return onCloseElement(...)
  end
  local onShowMenu = menu.onShowMenu
  menu.onShowMenu = function(...)
    onShowMenu(...)
    local ok, err = pcall(sab.RequestSizes)
    if not ok then sab.Error("size request failed: %s", tostring(err)) end
  end
end

local function init()
  RegisterEvent("StationAutoBuilder.ConfigChanged", sab.ReadConfig)
  sab.ReadConfig()
  hookMenu()
  sab.Debug("initialised")
end

-- reachable from a console eval while the panel does not exist yet
StationAutoBuilder = sab

Register_OnLoad_Init(init)
