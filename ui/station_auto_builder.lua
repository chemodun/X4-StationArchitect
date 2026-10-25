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
    float x;
    float y;
    float z;
  } Coord3D;
  typedef struct {
    const char* id;
    const char* name;
  } ProductionMethodInfo;
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
  bool HasBuildMapFloatingSelection(UniverseID holomapid);
  void RemoveFloatingSequenceFromConstructionPlan(UniverseID holomapid);
  void UpdateConstructionMapItemLoadout(UniverseID holomapid, size_t itemidx, UniverseID defensibleid, UILoadout uiloadout);
  int64_t GetBuildPlotPrice(UniverseID sectorid, UIPosRot location, float x, float y, float z, const char* factionid);
  int64_t GetBuildPlotPayment(UniverseID stationid, bool* positionchanged);
  UIPosRot GetObjectPositionInSector(UniverseID objectid);
  UniverseID GetSectorControlStation(UniverseID sectorid);
  const char* GetContainerBuildMethod(UniverseID containerid);
  uint32_t GetNumPlayerBuildMethods(void);
  uint32_t GetPlayerBuildMethods(ProductionMethodInfo* result, uint32_t resultlen);
  bool IsComponentClass(UniverseID componentid, const char* classname);
  bool ExtendBuildPlot(UniverseID stationid, Coord3D poschange, Coord3D negchange, bool allowreduction);
  void UpdateConstructionMapBuildPlot(UniverseID holomapid);
  void PayBuildPlotSize(UniverseID stationid, Coord3D plotsize, Coord3D plotcenter);
  UniverseID ReserveBuildPlot(UniverseID sectorid, const char* factionid, const char* set, UIPosRot location, float x, float y, float z);
  void SetContainerBuildMethod(UniverseID containerid, const char* buildmethodid);
  void SetStationModuleLoadoutLevel(UniverseID stationid, float value);
]]

local MENU_NAME = "StationConfigurationMenu"

-- ctypes once: a type string given to ffi.cast is parsed every call and a function type is never interned,
-- so the finite ctype table runs out after enough calls ("table overflow")
local P, U8PP, U16P, U32P, I32P, U64P = ffi.typeof("uint8_t*"), ffi.typeof("uint8_t**"), ffi.typeof("uint16_t*"), ffi.typeof("uint32_t*"), ffi.typeof("int32_t*"), ffi.typeof("uint64_t*")
local FLOATP, VOIDPP, CHARP, CHARPP, UPTR = ffi.typeof("float*"), ffi.typeof("void**"), ffi.typeof("const char*"), ffi.typeof("const char**"), ffi.typeof("uintptr_t")
local FN_RESOLVE, FN_UPDATE = ffi.typeof("void*(*)(void*, uint64_t, uint32_t)"), ffi.typeof("void(*)(void*, uint8_t, const float*)")
local FN_U8_I32 = ffi.typeof("uint8_t(*)(void*, int32_t)")
local PLAN_ENTRIES = ffi.typeof("UIConstructionPlanEntry2[?]")

local sab = {
  configBlackboard = "$StationAutoBuilderConfig",
  playerId = nil,
  cfg = {},
  debugLevel = "none",
  menu = nil,
  -- the active run; nil between runs
  run = nil,
  -- macro -> { maxX, maxY, maxZ, cX, cY, cZ }, read on first use
  sizes = {},
  -- macro -> snap connections from the Extra Data API
  snapCache = {},
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
  sab.panelDirty = true
end

-- *** module sizes ***
-- half-extents about a centre, metres, from the Extra Data API; nil when it cannot answer

setmetatable(sab.sizes, { __index = function(sizes, macro)
  local box = ExtraData and ExtraData.GetMacroDataEx(macro, "boundingbox")
  if not box then return nil end
  local size = { maxX = box.max[1], maxY = box.max[2], maxZ = box.max[3], cX = box.centre[1], cY = box.centre[2], cZ = box.centre[3] }
  sizes[macro] = size
  return size
end })

-- *** plan read-back ***

-- The plan as the map holds it: one entry per module, map order.
function sab.ReadPlan()
  local menu = sab.menu
  local n = C.GetNumBuildMapConstructionPlan(menu.holomap, false)
  local plan = {}
  if n == 0 then return plan end
  local buf = ffi.new(PLAN_ENTRIES, n)
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

local function u32(p) return ffi.cast(U32P, p)[0] end
local function i32(p) return ffi.cast(I32P, p)[0] end
local function u64(p) return ffi.cast(U64P, p)[0] end
local function pp(p) return ffi.cast(U8PP, p) end
local function uptr(p) return ffi.cast(UPTR, p) end
local function fp(p) return ffi.cast(FLOATP, p) end
local function u16p(p) return ffi.cast(U16P, p) end

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
-- inside the update: cmp byte [r15 + disp32], r12b, the editor's dragging flag that gates the snap search
---@type (integer|false)[]
local DRAGGING = { 0x45, 0x38, 0xa7, false, false, false, false }

-- GOG 9.00: operand positions in the patterns above and the engine objects' field offsets; the patterns pin
-- editor, plan and the floating rows, the code-read dragging offset must equal `dragging`. Another build needs its own set.
local LAYOUT = {
  dropRegistry = 0x13, dropResolver = 0x1e, resetRegistry = 0x26, resetResolver = 0x2b, resetRoutine = 0xdc,
  updateCall = 0x163, draggingCmp = 0x1f9,
  -- holomap: resolver kind, type check vfunc with its argument, the editor pointer
  holomapKind = 4, holomapCheck = 0x11e0, holomapCheckArg = 0x3a, editor = 0x2c0,
  -- editor: type check vfunc with its argument, plan entry vector, floating transform, snap result, dragging flag
  editorCheck = 0x18, editorCheckArg = 2, plan = 0x300, floating = 0x430, snapPose = 0x470, valid = 0x4b0,
  snapEntryIdx = 0x4b8, snapEntry = 0x4c0, snapModuleConn = 0x4c8, snapStationConn = 0x4d0, dragging = 0x570,
  -- plan entry transform, connection name
  entryTransform = 0x30, connectionName = 0x10,
}

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
    if p[0] == 0x4d and p[1] == 0x5a then
      local lfanew = i32(p + 0x3c)
      if lfanew >= 0x40 and lfanew <= 0x1000 and u32(p + lfanew) == 0x4550 then
        base = p
        break
      end
    end
    a = a - 0x10000
  end
  if not base then return nil, "image base not found" end
  local pe = base + i32(base + 0x3c)
  local opt = pe + 24
  local img = { base = base, sec = {}, id = string.format("%x-%x", u32(pe + 8), u32(opt + 56)) }
  local s = opt + u16p(pe + 20)[0]
  for i = 0, u16p(pe + 6)[0] - 1 do
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
  local dropAnchor = uptr(C.AddFloatingSequenceToConstructionPlan)
  local resetAnchor = uptr(C.ResetConstructionMapModuleRotation)
  local img, why = mapImage(dropAnchor)
  if not img then return false, why end
  local base = uptr(img.base)
  local drop, reset = tonumber(dropAnchor - base), tonumber(resetAnchor - base)
  if not (inText(img, drop, #DROP) and matchBytes(img.base + drop, DROP)) then return false, "drop wrapper mismatch" end
  if not (inText(img, reset, #RESET) and matchBytes(img.base + reset, RESET)) then return false, "rotation reset wrapper mismatch" end
  local registry, resolver = rel32(img, drop + LAYOUT.dropRegistry), rel32(img, drop + LAYOUT.dropResolver)
  if registry ~= rel32(img, reset + LAYOUT.resetRegistry) or resolver ~= rel32(img, reset + LAYOUT.resetResolver) then return false, "wrappers disagree" end
  local d = img.sec[".data"]
  if registry < d.from or registry + 8 > d.vto then return false, "registry outside .data" end
  local routine = rel32(img, reset + LAYOUT.resetRoutine)
  local at = routine + LAYOUT.updateCall
  if not (inText(img, at, #UPDATE) and matchBytes(img.base + at, UPDATE)) then return false, "update call mismatch" end
  local update = rel32(img, at + #UPDATE - 4)
  at = update + LAYOUT.draggingCmp
  if not (inText(img, at, #DRAGGING) and matchBytes(img.base + at, DRAGGING)) then return false, "dragging flag mismatch" end
  local dragging = i32(img.base + at + 3)
  if dragging ~= LAYOUT.dragging then return false, string.format("dragging flag at +0x%x, not +0x%x", dragging, LAYOUT.dragging) end
  if not (inText(img, resolver, 16) and inText(img, update, 16)) then return false, "target outside .text" end
  sab.Debug("engine located (%s): resolver 0x%x registry 0x%x update 0x%x dragging +0x%x", img.id, resolver, registry, update, dragging)
  return {
    resolve = ffi.cast(FN_RESOLVE, img.base + resolver),
    registry = ffi.cast(VOIDPP, img.base + registry),
    update = ffi.cast(FN_UPDATE, img.base + update),
    dragging = dragging,
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
  local vt = pp(obj)[0]
  return ffi.cast(sig, ffi.cast(VOIDPP, vt + offset)[0])
end

-- The station editor behind the menu's holomap, or nil.
function sab.Editor()
  if engine == nil then locate() end
  local menu = sab.menu
  if not (engine and menu and menu.holomap ~= 0) then return nil end
  local registry = engine.registry[0]
  if registry == nil then return nil end
  local holo = engine.resolve(registry, menu.holomap, LAYOUT.holomapKind)
  if holo == nil then return nil end
  if vfunc(holo, LAYOUT.holomapCheck, FN_U8_I32)(holo, LAYOUT.holomapCheckArg) == 0 then return nil end
  local editor = pp(ffi.cast(P, holo) + LAYOUT.editor)[0]
  if editor == nil then return nil end
  if vfunc(editor, LAYOUT.editorCheck, FN_U8_I32)(editor, LAYOUT.editorCheckArg) == 0 then return nil end
  return editor
end

-- MSVC std::string at p
local function stdString(p)
  local size, cap = tonumber(u64(p + 0x10)), tonumber(u64(p + 0x18))
  if size > 1024 or cap < size or cap < 15 or cap > 0x10000 then return nil end
  return ffi.string(cap > 15 and ffi.cast(CHARPP, p)[0] or ffi.cast(CHARP, p), size)
end

-- 4x4 float transform at p: translation then three rotation rows
local function readTransform(p)
  local f = fp(p)
  return { x = f[0], y = f[1], z = f[2],
    rows = { { f[4], f[5], f[6] }, { f[8], f[9], f[10] }, { f[12], f[13], f[14] } } }
end

function sab.ReadFloating(editor)
  return readTransform(editor + LAYOUT.floating)
end

-- pos = { x, y, z } in the plan's frame; rows = three { x, y, z } or nil to keep the rotation
function sab.WriteFloating(editor, pos, rows)
  local f = fp(editor + LAYOUT.floating)
  f[0], f[1], f[2] = pos.x, pos.y, pos.z
  if rows then
    for r = 1, 3 do
      f[r * 4], f[r * 4 + 1], f[r * 4 + 2] = rows[r][1], rows[r][2], rows[r][3]
    end
  end
end

-- A plan entry's transform as the editor holds it, built ones included.
function sab.EntryPose(editor, idx)
  local vec = pp(editor + LAYOUT.plan)[0]
  if vec == nil then return nil end
  local first, last = pp(vec)[0], pp(vec + 8)[0]
  local n = tonumber((uptr(last) - uptr(first)) / 8)
  if idx < 0 or idx >= n then return nil end
  local e = pp(first)[idx]
  if e == nil then return nil end
  local pose = readTransform(e + LAYOUT.entryTransform)
  pose.count = n
  return pose
end

-- The editor's entry pose of a ReadPlan entry; a translation other than the plan's offset means the entry
-- layout differs from GOG 9.00: the route turns off.
local function checkedPose(editor, e)
  local pose = sab.EntryPose(editor, e.idx)
  if not pose then return nil end
  local o = e.offset
  if math.abs(pose.x - o.x) > 0.1 or math.abs(pose.y - o.y) > 0.1 or math.abs(pose.z - o.z) > 0.1 then
    engine = false
    sab.Error("engine access unavailable (entry %d %s at %.1f %.1f %.1f, the plan has %.1f %.1f %.1f)", e.idx, e.macro, pose.x, pose.y, pose.z, o.x, o.y, o.z)
    return nil
  end
  return pose
end

-- the module data the route needs from the Extra Data API is readable on this build
local function macroDataOk()
  if not (ExtraData and ExtraData.Available) then return false end
  local _, macros = ExtraData.Available()
  return macros
end

-- A macro's snap connections from the Extra Data API: name, position and direction in the macro's frame.
function sab.Connections(name)
  if not (name and ExtraData) then return {} end
  if sab.snapCache[name] then return sab.snapCache[name] end
  local list = {}
  for _, c in ipairs(ExtraData.GetMacroDataEx(name, "snapconnections") or {}) do
    list[#list + 1] = { name = c.name, pos = c.position, dir = c.direction, rows = c.rows }
  end
  if #list > 0 then sab.snapCache[name] = list end
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

-- Rows of the rotation about unit axis k by the angle with cosine c and sine s (Rodrigues).
local function rowsAxisAngle(k, c, s)
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

-- Rows of the rotation that turns unit vector a onto unit vector b. Near a = -b the axis comes from a alone,
-- so engine float noise in b cannot pick it (that flips the roll by 180 deg).
local function rowsFromTo(a, b)
  local k, c = cross(a, b), dot(a, b)
  local s = math.sqrt(dot(k, k))
  if s < 1e-6 or c < -0.999 then
    if c > 0 then return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } end
    k = cross(a, math.abs(a[1]) < 0.9 and { 1, 0, 0 } or { 0, 1, 0 })
    s, c = 0, -1
  end
  return rowsAxisAngle(unit(k), c, s)
end

-- Rows of "a, then b": (v a) b = v (a b).
local function mulRows(a, b)
  local r = {}
  for i = 1, 3 do
    r[i] = {}
    for j = 1, 3 do r[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j] end
  end
  return r
end

-- One entry's connections in the plan frame: { entryIdx, macro, name, pos, dir, used }.
local function connectionsOf(entryIdx, macroName, pose, usedNames)
  local list = {}
  for _, c in ipairs(sab.Connections(macroName)) do
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
    local pose = checkedPose(editor, e)
    if pose then
      for _, c in ipairs(connectionsOf(e.idx, e.macro, pose, used[e.idx])) do list[#list + 1] = c end
    end
  end
  return list
end

-- The module pose that puts moduleConn onto a station connection at world sPos pointing along sDir,
-- directions opposed, turned by roll (radians) about that axis: { pos = { x, y, z }, rows }.
function sab.PoseForWorld(sPos, sDir, moduleConn, roll)
  local rows = rowsFromTo(unit(moduleConn.dir), { -sDir[1], -sDir[2], -sDir[3] })
  if roll and roll ~= 0 then rows = mulRows(rows, rowsAxisAngle(unit(sDir), math.cos(roll), math.sin(roll))) end
  local mPos = rotate(moduleConn.pos, rows)
  return { pos = { x = sPos[1] - mPos[1], y = sPos[2] - mPos[2], z = sPos[3] - mPos[3] }, rows = rows }
end

function sab.PoseForPair(entryPose, stationConn, moduleConn, roll)
  local eRows = entryPose.rows
  local sPos = rotate(stationConn.pos, eRows)
  return sab.PoseForWorld({ sPos[1] + entryPose.x, sPos[2] + entryPose.y, sPos[3] + entryPose.z },
    unit(rotate(stationConn.dir, eRows)), moduleConn, roll)
end

-- Run the editor's update without a cursor: the snap search from the floating transform as written.
-- A target entry pointer means the nearest compatible pair inside the snap radius was found.
function sab.Snap(editor)
  if not C.HasBuildMapFloatingSelection(sab.menu.holomap) then return { snapped = false, valid = false } end
  -- the snap search runs only while the editor drags a module
  editor[engine.dragging] = 1
  engine.update(editor, 0, zeroRay)
  local r = { snapped = pp(editor + LAYOUT.snapEntry)[0] ~= nil, valid = editor[LAYOUT.valid] ~= 0 }
  if r.snapped then
    r.entryIdx = tonumber(u64(editor + LAYOUT.snapEntryIdx))
    local modConn, stationConn = pp(editor + LAYOUT.snapModuleConn)[0], pp(editor + LAYOUT.snapStationConn)[0]
    r.connection = modConn ~= nil and stdString(modConn + LAYOUT.connectionName) or nil
    r.predecessorConnection = stationConn ~= nil and stdString(stationConn + LAYOUT.connectionName) or nil
    r.pose = readTransform(editor + LAYOUT.snapPose)
  end
  return r
end

-- *** one placement ***
-- Frame 1: float the macro. Frame 2: write its transform, run the editor's snap search, drop, all in
-- one chunk, so the drag code's cursor write never reaches the search and the nearest compatible pair
-- to the written pose wins. The editor refuses a drop in the frame the module was floated.

local VALID_RETRIES = 10

-- The snapped pose equals the planned one (within a metre and a near-identical rotation).
local function samePlace(pose, pos, rows)
  if math.abs(pose.x - pos.x) > 1 or math.abs(pose.y - pos.y) > 1 or math.abs(pose.z - pos.z) > 1 then return false end
  for i = 1, 3 do
    local a, b = pose.rows[i], rows and rows[i]
    if b and a[1] * b[1] + a[2] * b[2] + a[3] * b[3] < 0.999 then return false end
  end
  return true
end

-- the slider's placements per frame, under the run's cap after a failure
local function perFrame(run)
  return math.min(sab.perFrame, run.cap or sab.perFrame)
end

local function beginPlacement(run, item)
  local menu = sab.menu
  run.countBefore = tonumber(C.GetNumBuildMapConstructionPlan(menu.holomap, false))
  -- dragged: the drop waits a frame; not dragged: the editor takes it in the frame of the float
  item.dragged = perFrame(run) <= 1
  C.AddMacroToConstructionMap(menu.holomap, item.macro, item.dragged)
  menu.floatingNewModule = item.macro
  run.phase = "drop"
end

local function finishPlacement(run, item)
  local menu = sab.menu
  local editor = sab.Editor()
  if not (editor and C.HasBuildMapFloatingSelection(menu.holomap)) then
    C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
    menu.floatingNewModule = nil
    run.failed = run.failed + 1
    sab.Error(editor and "%s is not floating any more" or "no editor for %s", item.macro)
    return false
  end
  local pos, rows, pair = item.pos, item.rows, item.pair
  local entryIdx = pair and pair.entryIdx
  if entryIdx == "last" then entryIdx = run.lastPlacedIdx elseif type(entryIdx) == "table" then entryIdx = entryIdx.placedIdx end
  if (item.after and not item.after.placedIdx) or (pair and not entryIdx) then
    C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
    menu.floatingNewModule = nil
    run.failed = run.failed + 1
    sab.Debug("%s: the skeleton chain broke before it", item.macro)
    return false
  end
  if pair then
    local entry = entryIdx and sab.EntryPose(editor, entryIdx)
    local stationConn, moduleConn
    for _, c in ipairs(entry and sab.Connections(run.macros[entryIdx]) or {}) do
      if c.name == pair.predecessorConnection then stationConn = c end
    end
    for _, c in ipairs(sab.Connections(item.macro)) do
      if c.name == pair.connection then moduleConn = c end
    end
    if not (entry and stationConn and moduleConn) then
      C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
      menu.floatingNewModule = nil
      run.failed = run.failed + 1
      sab.Debug("no such pair for %s: entry %s %s / %s", item.macro, tostring(entryIdx), tostring(pair.predecessorConnection), tostring(pair.connection))
      return false
    end
    local pose = sab.PoseForPair(entry, stationConn, moduleConn, item.roll)
    pos, rows = pose.pos, pose.rows
  end
  -- an undragged float drops only inside the plot
  local size = sab.sizes[item.macro]
  if not item.dragged and run.plot and size then
    sab.FitPlot(sab.geo.worldBox(size, { pos.x, pos.y, pos.z }, rows or sab.ReadFloating(editor).rows), false)
  end
  sab.WriteFloating(editor, pos, rows)
  local snap = sab.Snap(editor)
  local wrongEntry = snap.snapped and ((item.entryIdx and snap.entryIdx ~= item.entryIdx)
    or (pair and (snap.entryIdx ~= entryIdx or snap.connection ~= pair.connection or snap.predecessorConnection ~= pair.predecessorConnection)))
  -- a module touching two free connections may take the other one: the same place is the planned placement
  if wrongEntry and pair and not item.entryIdx and samePlace(snap.pose, pos, rows) then
    sab.Debug("%s: snapped to entry %d %s / %s, the planned place", item.macro, snap.entryIdx, snap.predecessorConnection, snap.connection)
    wrongEntry = false
  end
  if (snap.snapped and not wrongEntry) or (item.free and snap.valid) then
    C.AddFloatingSequenceToConstructionPlan(menu.holomap)
  end
  local count = tonumber(C.GetNumBuildMapConstructionPlan(menu.holomap, false))
  -- a snap to the wanted entry the editor calls invalid can be a passing state: stay floated, retry next frames
  if count <= run.countBefore and pair and snap.snapped and not wrongEntry and (item.validRetries or 0) < VALID_RETRIES then
    item.validRetries = (item.validRetries or 0) + 1
    return false, true
  end
  if (item.validRetries or 0) > 0 then sab.Debug("%s: %d retries for the editor's valid flag", item.macro, item.validRetries) end
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
  if item.spurAnchor then item.spurAnchor.spurFailed = true end
  if wrongEntry then
    sab.Debug("%s at %.0f %.0f %.0f snapped to entry %d %s / %s instead", item.macro, pos.x, pos.y, pos.z, snap.entryIdx, snap.predecessorConnection, snap.connection)
  elseif snap.snapped then
    sab.Debug("%s on entry %d rejected by the editor (valid %s): %s / %s, roll %.0f deg, at %.0f %.0f %.0f", item.macro, snap.entryIdx, tostring(snap.valid),
      pair and pair.predecessorConnection or "-", pair and pair.connection or "-", math.deg(item.roll or 0), pos.x, pos.y, pos.z)
  elseif item.free then
    sab.Debug("free drop of %s at %.0f %.0f %.0f refused by the editor (valid %s)", item.macro, pos.x, pos.y, pos.z, tostring(snap.valid))
  else
    sab.Debug("no snap for %s at %.0f %.0f %.0f", item.macro, pos.x, pos.y, pos.z)
  end
  return false
end

-- *** packing ***
-- A pack item goes onto the free station connection that keeps the plan compact: candidates are every
-- free connection x every connection of the module x four rolls, nearest module centre to the plan's
-- anchor first, pre-checked in Lua against the plot and the placed boxes; the engine's snap (tags) and
-- valid flag (collision) give the verdict. Outer modules take outward connections only and keep a clearance.
-- No place: the overlapping candidates go to the engine's collision check, then the plot grows when it
-- blocked candidates, then a connector grows outward from the edge and the item tries again. Further
-- connectors for the same item continue straight from the previous one's tip (a spur); the item tries the tip first.
-- A target plan on an empty plot takes the grid layout (station_auto_builder_grid.lua) instead.

local OUTER = { dockarea = 1000, pier = 2000, buildmodule = 2000, defencemodule = 1000, ventureplatform = 1000 }
local TRIES_PER_FRAME, CHECKS_PER_FRAME = 8, 400
local ROLLS = { 0, math.pi / 2, math.pi, 3 * math.pi / 2 }
local RELAXED_TRIES, MAX_REACH, MAX_SPURS, MAX_PLOT, PLOT_STEP = 200, 6, 3, 20000, 1000
sab.maxPlotKm = MAX_PLOT / 1000
local AXES = { "x", "y", "z" }
local STRAIGHT = 0.9
local SPUR_GAP = 500
-- classes with approach zones the engine keeps free (exclusionzones)
local COLUMN = { "dockarea", "pier" }
local GROUP_CLASSES = { { "production", "production" }, { "processingmodule", "production" }, { "buildmodule", "build" },
  { "storage", "storage" }, { "habitation", "habitation" }, { "dockarea", "dock" }, { "pier", "pier" } }

local function groupOf(macro)
  for _, g in ipairs(GROUP_CLASSES) do
    if IsMacroClass(macro, g[1]) then return g[2] end
  end
  return "other"
end

local function dist2(a, b)
  local d = { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
  return dot(d, d)
end

local function outerMargin(macro)
  for class, margin in pairs(OUTER) do
    if IsMacroClass(macro, class) then return margin end
  end
  return nil
end

local function columnClass(macro)
  for _, class in ipairs(COLUMN) do
    if IsMacroClass(macro, class) then return true end
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

-- The approach zones (exclusionzones, Extra Data API) of a macro through a pose, as boxes with their direction.
local function zoneBoxes(macro, pos, rows)
  local list = {}
  for _, z in ipairs(ExtraData and ExtraData.GetMacroDataEx(macro, "exclusionzones") or {}) do
    local m = mulRows(z.rows, rows)
    local at, mid = rotate(z.position, rows), rotate(z.centre, m)
    local box = { min = {}, max = {}, dir = unit(rotate(z.direction, rows)) }
    for j = 1, 3 do
      local h = (math.abs(m[1][j]) * z.size[1] + math.abs(m[2][j]) * z.size[2] + math.abs(m[3][j]) * z.size[3]) / 2
      local c = pos[j] + at[j] + mid[j]
      box.min[j], box.max[j] = c - h, c + h
    end
    list[#list + 1] = box
  end
  return list
end

local function overlaps(a, b, margin)
  for i = 1, 3 do
    if a.min[i] - margin >= b.max[i] or a.max[i] + margin <= b.min[i] then return false end
  end
  return true
end

-- A box entering a placed approach zone deeper than a metre.
local function inZone(run, box)
  for _, zones in pairs(run.zones) do
    for _, z in ipairs(zones) do
      if overlaps(box, z, -1) then return true end
    end
  end
  return false
end

local function inside(a, b)
  for i = 1, 3 do
    if a.min[i] < b.min[i] or a.max[i] > b.max[i] then return false end
  end
  return true
end

local function addEntry(run, idx, macro, pose)
  run.n = run.n + 1
  run.macros[idx] = macro
  run.sum[1], run.sum[2], run.sum[3] = run.sum[1] + pose.x, run.sum[2] + pose.y, run.sum[3] + pose.z
  local size = sab.sizes[macro]
  if size then
    local box = worldBox(size, { pose.x, pose.y, pose.z }, pose.rows)
    run.boxes[idx] = box
    if columnClass(macro) then run.zones[idx] = zoneBoxes(macro, { pose.x, pose.y, pose.z }, pose.rows) end
    if run.plot then sab.FitPlot(box, false) end
  end
end

local function readPlot(run)
  local menu = sab.menu
  local size, centre = C.GetBuildPlotSize(menu.container), C.GetBuildPlotCenterOffset(menu.container)
  run.plot = { min = { centre.x - size.x / 2, centre.y - size.y / 2, centre.z - size.z / 2 },
    max = { centre.x + size.x / 2, centre.y + size.y / 2, centre.z + size.z / 2 } }
end

-- The plan's connections, boxes, anchor and plot at the start of a run.
local function readPlanState(run, editor)
  run.conns = sab.PlanConnections(editor)
  run.boxes, run.zones, run.macros, run.sum, run.n = {}, {}, {}, { 0, 0, 0 }, 0
  for _, e in ipairs(sab.ReadPlan()) do
    local pose = checkedPose(editor, e)
    if pose then addEntry(run, e.idx, e.macro, pose) end
  end
  readPlot(run)
end

-- The plot's face distances from the station's position in metres, { pos = { x, y, z }, neg = { x, y, z } };
-- a map-reserved plot has faces half a step out.
local function plotExtents()
  local menu = sab.menu
  local size, centre = C.GetBuildPlotSize(menu.container), C.GetBuildPlotCenterOffset(menu.container)
  local e = { pos = {}, neg = {} }
  for i, axis in ipairs(AXES) do
    e.pos[i] = size[axis] / 2 + centre[axis]
    e.neg[i] = size[axis] / 2 - centre[axis]
  end
  return e
end

-- Each face of the plot moved on its own to whole steps from the station's position that cover box (station
-- coordinates; the station's position stays inside); shrink lets faces move inwards. Capped per axis.
-- Returns the face moves (metres per axis), whether any face moves, the new faces in steps and the longest axis
-- the box needs before the cap, in metres.
local function plotChange(box, shrink, quiet)
  local have = plotExtents()
  local pos, neg, change = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, false
  local faces, need = { pos = {}, neg = {}, uncapped = {} }, 0
  for i, axis in ipairs(AXES) do
    local hp, hn = math.ceil(have.pos[i] / PLOT_STEP - 0.001), math.ceil(have.neg[i] / PLOT_STEP - 0.001)
    local p = math.max(0, math.ceil(box.max[i] / PLOT_STEP - 0.001))
    local n = math.max(0, math.ceil(-box.min[i] / PLOT_STEP - 0.001))
    if not shrink then p, n = math.max(p, hp), math.max(n, hn) end
    if p + n == 0 then p = 1 end
    need = math.max(need, (p + n) * PLOT_STEP)
    faces.uncapped[i] = p + n
    if (p + n) * PLOT_STEP > MAX_PLOT then
      if not quiet then sab.Debug("the layout needs %.1f km on %s, above the plot cap %.0f km", (p + n) * PLOT_STEP / 1000, axis, MAX_PLOT / 1000) end
      while (p + n) * PLOT_STEP > MAX_PLOT do
        if p - hp >= n - hn and p > 0 then p = p - 1 else n = n - 1 end
      end
    end
    pos[axis], neg[axis] = p * PLOT_STEP - have.pos[i], n * PLOT_STEP - have.neg[i]
    if math.abs(pos[axis]) > 1 or math.abs(neg[axis]) > 1 then change = true end
    faces.pos[i], faces.neg[i] = p, n
  end
  return pos, neg, change, faces, need
end

-- The whole-km faces the plot grows to for box (station frame), capped; uncapped: steps per axis before the cap.
function sab.PlotFaces(box)
  return select(4, plotChange(box, false, true))
end

-- Vanilla's licence rule: free where the sector owner is nobody, the Xenon or the player.
local function plotIsFree(sector)
  local owner = GetComponentData(sector, "owner")
  return owner == "ownerless" or owner == "xenon" or GetComponentData(sector, "isplayerowned")
end

function sab.FitPlot(box, shrink)
  local menu = sab.menu
  local pos, neg, change = plotChange(box, shrink)
  if not change then return false end
  if not C.ExtendBuildPlot(menu.container, pos, neg, true) then
    sab.Debug("plot change refused: +%.0f %.0f %.0f / -%.0f %.0f %.0f m", pos.x, pos.y, pos.z, neg.x, neg.y, neg.z)
    return false
  end
  C.UpdateConstructionMapBuildPlot(menu.holomap)
  if plotIsFree(GetComponentData(menu.container, "sectorid")) then
    C.PayBuildPlotSize(menu.container, C.GetBuildPlotSize(menu.container), C.GetBuildPlotCenterOffset(menu.container))
  end
  if sab.run then readPlot(sab.run) end
  local e = plotExtents()
  sab.Debug("plot faces now x +%.1f -%.1f, y +%.1f -%.1f, z +%.1f -%.1f km", e.pos[1] / 1000, e.neg[1] / 1000, e.pos[2] / 1000, e.neg[2] / 1000,
    e.pos[3] / 1000, e.neg[3] / 1000)
  return true
end

-- The licence still to pay for the plot as it is now (vanilla's plot menu price).
local function plotPrice(sector)
  local menu = sab.menu
  local size, buf = C.GetBuildPlotSize(menu.container), ffi.new("bool[1]", 0)
  local full = tonumber(C.GetBuildPlotPrice(sector, C.GetObjectPositionInSector(menu.container), size.x, size.y, size.z, "player"))
  return full - tonumber(C.GetBuildPlotPayment(menu.container, buf))
end

-- After the pack: the plot the layout grows to (run.plotBox, station frame) and its licence price less what is
-- paid; a price to pay waits in phase "confirm" for the panel's answer, else the placement begins.
function sab.OfferPlot(run)
  local menu, box = sab.menu, run.plotBox
  local sector = ConvertIDTo64Bit(GetComponentData(menu.container, "sectorid"))
  local pos, neg, change, f, need
  if box then pos, neg, change, f, need = plotChange(box, false, true) end
  -- a layout past the plot cap would leave modules outside: nothing is placed
  if need and need > MAX_PLOT then
    sab.StopRun(string.format("the layout needs %.0f km, above the plot cap", need / 1000))
    sab.lastRun = { placed = 0, failed = 0, tooLarge = need / 1000 }
    return
  end
  if not box or plotIsFree(sector) then
    run.phase = "begin"
    return
  end
  local size = { x = (f.pos[1] + f.neg[1]) * PLOT_STEP, y = (f.pos[2] + f.neg[2]) * PLOT_STEP, z = (f.pos[3] + f.neg[3]) * PLOT_STEP }
  -- the predicted plot, not the current one: plotPrice reads the plot as it is
  local buf = ffi.new("bool[1]", 0)
  local full = tonumber(C.GetBuildPlotPrice(sector, C.GetObjectPositionInSector(menu.container), size.x, size.y, size.z, "player"))
  local price = full - tonumber(C.GetBuildPlotPayment(menu.container, buf))
  sab.Debug("plot after the pack: %.0f x %.0f x %.0f km, licence %d Cr to pay", size.x / 1000, size.y / 1000, size.z / 1000, price)
  if price <= 0 then
    run.phase = "begin"
    return
  end
  run.offer = { pos = pos, neg = neg, change = change, size = size, price = price, sector = sector }
  run.phase = "confirm"
  sab.expanded, sab.panelDirty = true, true
end

-- The panel's answer to the offer: pay and place, or stop with nothing placed.
function sab.AnswerPlot(accept)
  ---@type table?
  local run = sab.run
  local o = run and run.offer
  if not o then return end
  if not accept then
    sab.StopRun("plot licence declined")
    sab.lastRun = { placed = 0, failed = 0, declined = true }
    return
  end
  if GetPlayerMoney() < o.price then return end
  local menu = sab.menu
  if o.change and not C.ExtendBuildPlot(menu.container, o.pos, o.neg, true) then
    sab.Debug("plot change refused: +%.0f %.0f %.0f / -%.0f %.0f %.0f m", o.pos.x, o.pos.y, o.pos.z, o.neg.x, o.neg.y, o.neg.z)
    sab.StopRun("plot change refused")
    return
  end
  C.UpdateConstructionMapBuildPlot(menu.holomap)
  -- the plot as extended is what gets paid; the offer was its prediction
  local price = math.min(o.price, plotPrice(o.sector))
  if price > 0 then TransferPlayerMoneyTo(price, ConvertStringTo64Bit(tostring(C.GetSectorControlStation(o.sector)))) end
  C.PayBuildPlotSize(menu.container, C.GetBuildPlotSize(menu.container), C.GetBuildPlotCenterOffset(menu.container))
  sab.Debug("plot licence paid: %d Cr (offered %d)", price, o.price)
  readPlot(run)
  run.offer, run.phase = nil, "begin"
  sab.panelDirty = true
end

-- The licence still due on a plot in a faction sector (a bill run grows it unpaid), nil when none is due.
function sab.PlotFee()
  local menu = sab.menu
  if sab.run or not menu or menu.container == 0 then return nil end
  local sector = ConvertIDTo64Bit(GetComponentData(menu.container, "sectorid"))
  if plotIsFree(sector) then return nil end
  local price = plotPrice(sector)
  return price > 0 and price or nil
end

function sab.BuyPlot()
  local price = sab.PlotFee()
  if not price or GetPlayerMoney() < price then return end
  local menu = sab.menu
  local sector = ConvertIDTo64Bit(GetComponentData(menu.container, "sectorid"))
  TransferPlayerMoneyTo(price, ConvertStringTo64Bit(tostring(C.GetSectorControlStation(sector))))
  C.PayBuildPlotSize(menu.container, C.GetBuildPlotSize(menu.container), C.GetBuildPlotCenterOffset(menu.container))
  sab.Debug("plot licence paid: %d Cr", price)
  sab.panelDirty = true
end

-- What Optimize plot fits the plot to: the plan's modules, an empty box on an empty plan; nil while a plan
-- module has no known size or the editor is not reachable.
local function optimizeBox(log)
  local menu = sab.menu
  if sab.run or not menu or menu.holomap == 0 then return nil end
  local plan, missing = sab.ReadPlan(), {}
  for _, e in ipairs(plan) do
    if not sab.sizes[e.macro] then missing[#missing + 1] = e.macro end
  end
  if #missing > 0 then
    if log then sab.Debug("optimize plot: no size for %d plan modules (%s); the plot stays", #missing, missing[1]) end
    return nil
  end
  if #plan == 0 then return { min = { 0, 0, 0 }, max = { 0, 0, 0 } } end
  local box = sab.PlanBox()
  if not box and log then sab.Debug("optimize plot: the editor is not reachable; the plot stays") end
  return box
end

-- Offered only when the fit would move a face of the plot.
function sab.CanOptimizePlot()
  local box = optimizeBox(false)
  return box ~= nil and select(3, plotChange(box, true, true))
end

-- The plot fitted to the plan's modules on each side, the smallest plot on an empty plan.
function sab.OptimizePlot()
  local box = optimizeBox(true)
  if box and sab.FitPlot(box, true) then sab.panelDirty = true end
end

-- The box around every plan entry with a known size, nil on an empty plan.
function sab.PlanBox()
  local editor = sab.Editor()
  if not editor then return nil end
  local box
  for _, e in ipairs(sab.ReadPlan()) do
    local size, pose = sab.sizes[e.macro], checkedPose(editor, e)
    if size and pose then
      local b = worldBox(size, { pose.x, pose.y, pose.z }, pose.rows)
      if box then
        for i = 1, 3 do
          if b.min[i] < box.min[i] then box.min[i] = b.min[i] end
          if b.max[i] > box.max[i] then box.max[i] = b.max[i] end
        end
      else
        box = b
      end
    end
  end
  return box
end

local function anchorOf(run)
  if run.n == 0 then
    local p = run.plot
    return { (p.min[1] + p.max[1]) / 2, (p.min[2] + p.max[2]) / 2, (p.min[3] + p.max[3]) / 2 }
  end
  return { run.sum[1] / run.n, run.sum[2] / run.n, run.sum[3] / run.n }
end

-- *** connectors ***
-- Connection geometry from the Extra Data API at the start of the run: every connector and, on the grid
-- route, every module (cached per Lua state).

sab.macroConns = sab.macroConns or {}

local function raceOf(macro)
  local races = GetMacroData(macro, "makerraceid")
  return type(races) == "table" and races[1] or races
end

local function armOf(conns, dir)
  for _, c in ipairs(conns or {}) do
    if dot(c.dir, dir) > 0.9 then return c end
  end
  return nil
end

-- Two opposed collinear connections on a thin body make a strut: length, own axis, end names.
local function strutOf(macro, conns)
  if #conns ~= 2 then return nil end
  local a, b = conns[1], conns[2]
  if dot(a.dir, b.dir) > -0.9 then return nil end
  local d = { b.pos[1] - a.pos[1], b.pos[2] - a.pos[2], b.pos[3] - a.pos[3] }
  local len = math.sqrt(dot(d, d))
  if len < 1 or dot(unit(d), b.dir) < 0.9 then return nil end
  local s = sab.sizes[macro]
  if s and (s.maxX + s.maxY + s.maxZ - len / 2) > 0.75 * len then return nil end
  return { length = len, vertical = math.abs(b.dir[2]) > 0.9, near = a.name, far = b.name }
end

-- The owned connection modules as a kit: the cross with the most arms, every strut length; the plan's race first.
local function connectorKit(race)
  local kit, seen, seenV = { struts = {}, lengths = {}, vLengths = {} }, {}, {}
  for _, m in ipairs(sab.menu.modules and sab.menu.modules.moduletypes_other or {}) do
    local conns = sab.macroConns[m]
    if conns and IsMacroClass(m, "connectionmodule") then
      local tier = raceOf(m) == race and 0 or 1
      if #conns >= 6 then
        local cur = kit.cross
        if not cur or tier < cur.tier or (tier == cur.tier and (#conns > #cur.conns or (#conns == #cur.conns and m < cur.macro))) then
          kit.cross = { macro = m, tier = tier, conns = conns }
          kit.arm = 0
          for _, c in ipairs(conns) do kit.arm = math.max(kit.arm, math.abs(dot(c.pos, c.dir))) end
        end
      else
        local s = strutOf(m, conns)
        if s then
          s.macro, s.tier = m, tier
          kit.struts[#kit.struts + 1] = s
          local key = math.floor(s.length + 0.5)
          if not seen[key] then
            seen[key] = true
            kit.lengths[#kit.lengths + 1] = key
          end
          if s.vertical and not seenV[key] then
            seenV[key] = true
            kit.vLengths[#kit.vLengths + 1] = key
          end
        end
      end
    end
  end
  table.sort(kit.lengths, function(a, b) return a > b end)
  table.sort(kit.vLengths, function(a, b) return a > b end)
  return kit
end

local function strutFor(kit, length, vertical)
  local best, bestRank
  for _, s in ipairs(kit.struts) do
    if math.floor(s.length + 0.5) == length then
      local rank = s.tier * 2 + ((s.vertical == vertical) and 0 or 1)
      if not best or rank < bestRank or (rank == bestRank and s.macro < best.macro) then best, bestRank = s, rank end
    end
  end
  return best
end

-- for the grid layout (station_auto_builder_grid.lua)
sab.geo = { rotate = rotate, unit = unit, mulRows = mulRows, worldBox = worldBox, zoneBoxes = zoneBoxes, armOf = armOf, strutFor = strutFor }

-- The shortest combination of at most four struts spanning need or more: lengths, longest first.
local function spanWith(lengths, need)
  local best
  local function try(i, sum, count, picked)
    if sum >= need then
      if not best or sum < best.sum or (sum == best.sum and count < best.count) then
        best = { sum = sum, count = count, picked = {} }
        for k, len in ipairs(picked) do best.picked[k] = len end
      end
      return
    end
    if i > #lengths then return end
    for n = 0, 4 - count do
      for _ = 1, n do picked[#picked + 1] = lengths[i] end
      try(i + 1, sum + n * lengths[i], count + n, picked)
      for _ = 1, n do picked[#picked] = nil end
    end
  end
  try(1, 0, 0, {})
  return best and best.picked, best and best.sum
end

-- Struts from a connection of the base entry along dir, then a cross on their far end: pairs on the entry
-- placed just before. Nil when the cross has no arm against dir.
local function link(kit, chain, baseIdx, baseItem, baseConn, dir, lengths, vertical, turn)
  local back = armOf(kit.cross.conns, { -dir[1], -dir[2], -dir[3] })
  if not back then return nil end
  local prevIdx, prevConn, prevItem = baseIdx, baseConn, baseItem
  for k = 1, #lengths do
    local s = strutFor(kit, lengths[k], vertical)
    local it = { macro = s.macro, pair = { entryIdx = prevIdx, predecessorConnection = prevConn, connection = s.near },
      isConnector = true, after = prevItem, turn = turn, far = s.far }
    chain[#chain + 1] = it
    prevIdx, prevConn, prevItem = "last", s.far, it
  end
  local it = { macro = kit.cross.macro, pair = { entryIdx = prevIdx, predecessorConnection = prevConn, connection = back.name },
    isConnector = true, after = prevItem, turn = turn }
  chain[#chain + 1] = it
  return it
end

-- A straight spur for an item that found no place: struts and a cross out of the farthest outward free
-- connection, long enough for the module to sit beyond the station; the item then tries the spur tip first.
-- Also the answer to a pier on a crowded station.
-- The Lua pre-check of a spur: every strut and the cross posed along the chain inside the plot, clear of the
-- placed boxes (the anchor's entry excepted).
local function chainClear(run, chain, f)
  local pos, dir = f.pos, f.dir
  for _, it in ipairs(chain) do
    local near, far
    for _, c in ipairs(sab.macroConns[it.macro] or {}) do
      if c.name == it.pair.connection then near = c end
      if it.far and c.name == it.far then far = c end
    end
    if not near then return false end
    local pose = sab.PoseForWorld(pos, dir, near, 0)
    local size = sab.sizes[it.macro]
    if size then
      local box = worldBox(size, { pose.pos.x, pose.pos.y, pose.pos.z }, pose.rows)
      if not inside(box, run.plot) then return false end
      for idx, b in pairs(run.boxes) do
        if idx ~= f.entryIdx and overlaps(box, b, -5) then return false end
      end
      if inZone(run, box) then return false end
    end
    if far then
      local p = rotate(far.pos, pose.rows)
      pos, dir = { pose.pos.x + p[1], pose.pos.y + p[2], pose.pos.z + p[3] }, unit(rotate(far.dir, pose.rows))
    end
  end
  return true
end

local function spurFor(run, item)
  local kit, anchor = run.kit, anchorOf(run)
  local cands = {}
  for _, f in ipairs(run.conns) do
    if not f.used and not f.spurFailed then
      local v = { f.pos[1] - anchor[1], f.pos[2] - anchor[2], f.pos[3] - anchor[3] }
      local depth = math.sqrt(dot(v, v))
      if depth > 0 and dot(f.dir, v) / depth > 0.7 then cands[#cands + 1] = { f = f, dir = f.dir, depth = depth } end
    end
  end
  if #cands == 0 then return nil, "no free connection facing out" end
  table.sort(cands, function(a, b) return a.depth > b.depth end)
  local s = sab.sizes[item.macro]
  local extent = s and 2 * math.max(s.maxX, s.maxY, s.maxZ) or 1000
  for k = 1, math.min(#cands, 12) do
    local c = cands[k]
    local lengths = spanWith(kit.lengths, extent / 2 + SPUR_GAP - 2 * kit.arm)
    if lengths then
      local chain = {}
      local tip = link(kit, chain, c.f.entryIdx, nil, c.f.name, c.dir, lengths, math.abs(c.dir[2]) > 0.9, item.turn)
      if tip and chainClear(run, chain, c.f) then
        tip.reach, tip.owner, tip.spurDir = true, item, c.dir
        chain[1].spurAnchor = c.f
        return chain, string.format("from entry %d %s, %d struts", c.f.entryIdx, c.f.name, #chain - 1)
      end
    end
  end
  return nil, string.format("no clear spur among %d connections", #cands)
end

-- After a placement: the entry for chained items, the spur tip of a reach connector.
local function notePlaced(run, item, addedIdx, cand)
  item.placedIdx = addedIdx
  if item.reach and (cand or item.spurDir) then run.spur = { owner = item.owner, tipIdx = addedIdx, dir = cand and cand.f.dir or item.spurDir } end
end

-- The connector kit for spurs, then the grid packer, or the plain packer with the first item dropped free at
-- the plot centre.
local function finishLayout(run)
  local menu = sab.menu
  run.kit = connectorKit(run.items[1] and raceOf(run.items[1].macro) or nil)
  if not run.kit.cross then run.kit = nil end
  if not run.gridRoute then
    run.phase = "begin"
    return
  end
  if not run.kit then
    local centre = C.GetBuildPlotCenterOffset(menu.container)
    local first = run.items[1]
    first.pack, first.free, first.pos = nil, true, { x = centre.x, y = centre.y, z = centre.z }
    sab.Debug("grid off: no cross blueprint")
    run.phase = "begin"
    return
  end
  sab.grid.Start(run)
end

-- One sorted list per item: every free connection x every module connection x four rolls; an outer or reach
-- item takes outward connections only. Bonuses order the list: a reach connector continues straight from the
-- spur tip, an item retried after a connector takes the tip (its straight connection first).
local function buildCandidates(run, item)
  local anchor = anchorOf(run)
  local mconns = sab.Connections(item.macro)
  local size = sab.sizes[item.macro]
  local spur = run.spur
  local chain = item.reach and spur and spur.owner == item.owner and spur.tipIdx or nil
  local tip = (not item.reach) and spur and spur.owner == item and spur.tipIdx or nil
  local prefer = item.connectors and run.lastPlacedIdx
  local outwardOnly = item.margin or item.reach
  local list, free = {}, 0
  for _, f in ipairs(run.conns) do
    if not f.used then free = free + 1 end
  end
  -- a module with no connection to spare on the last free one would leave the items after it nowhere to go
  item.closes = not item.isConnector and free + #mconns - 2 <= 0 and run.next < #run.items
  for _, f in ipairs(run.conns) do
    local accept = not f.used
    if accept and outwardOnly then accept = dot(f.dir, { f.pos[1] - anchor[1], f.pos[2] - anchor[2], f.pos[3] - anchor[3] }) > 0 end
    if accept then
      for _, m in ipairs(mconns) do
        local key = f.macro .. "|" .. f.name .. "|" .. item.macro .. "|" .. m.name
        if not sab.incompatible[key] then
          for _, roll in ipairs(ROLLS) do
            local pose = sab.PoseForWorld(f.pos, f.dir, m, roll)
            local c = { pose.pos.x, pose.pos.y, pose.pos.z }
            if size then
              local cc = rotate({ size.cX, size.cY, size.cZ }, pose.rows)
              c = { c[1] + cc[1], c[2] + cc[2], c[3] + cc[3] }
            end
            local score = dist2(c, anchor)
            if item.reach then score = -score end
            if chain and f.entryIdx == chain and dot(f.dir, spur.dir) > STRAIGHT then
              score = score - 4e15
            elseif tip and f.entryIdx == tip then
              score = score - 2e15 - (dot(f.dir, spur.dir) > STRAIGHT and 1e15 or 0)
            elseif prefer and f.entryIdx == prefer then
              score = score - 1e15
            end
            list[#list + 1] = { f = f, m = m, key = key, pose = pose, score = score, roll = roll }
          end
        end
      end
    end
  end
  table.sort(list, function(a, b) return a.score < b.score end)
  item.candidates, item.cursor, item.skips = list, 1, nil
  local first = (chain and string.format(", straight on from entry %d", chain))
      or (tip and string.format(", spur tip %d first", tip)) or (prefer and string.format(", entry %d first", prefer)) or (item.reach and ", reaching outward" or "")
  sab.Debug("%s: %d candidates, %d module connections, anchor %.0f %.0f %.0f%s", item.macro, #list, #mconns, anchor[1], anchor[2], anchor[3], first)
end

-- The Lua pre-check: inside the plot, clear of every placed box but the one it attaches to. An outer module
-- keeps its clearance in front of its outward face only (the approach of the ships), so it sits beside modules.
local function boxOk(run, item, cand)
  local size = sab.sizes[item.macro]
  if not size then return true end
  local box = worldBox(size, { cand.pose.pos.x, cand.pose.pos.y, cand.pose.pos.z }, cand.pose.rows)
  if not inside(box, run.plot) then
    -- the candidate needing the least plot growth, for growing only the faces it crosses
    local grow = 0
    for i = 1, 3 do grow = grow + math.max(0, run.plot.min[i] - box.min[i]) + math.max(0, box.max[i] - run.plot.max[i]) end
    if not item.plotNeed or grow < item.plotNeed.grow then item.plotNeed = { grow = grow, box = box } end
    return false, "plot"
  end
  -- the approach zones of the piers and dock areas: none entered, a new one's own zones clear of every body
  if inZone(run, box) then return false, "block" end
  if item.column then
    for _, z in ipairs(zoneBoxes(item.macro, { cand.pose.pos.x, cand.pose.pos.y, cand.pose.pos.z }, cand.pose.rows)) do
      for idx, b in pairs(run.boxes) do
        if idx ~= cand.f.entryIdx and overlaps(z, b, -1) then return false, "block" end
      end
    end
  end
  local front
  if item.margin then
    front = { min = { box.min[1], box.min[2], box.min[3] }, max = { box.max[1], box.max[2], box.max[3] } }
    for i = 1, 3 do
      if cand.f.dir[i] > 0.5 then
        front.max[i] = front.max[i] + item.margin
      elseif cand.f.dir[i] < -0.5 then
        front.min[i] = front.min[i] - item.margin
      end
    end
  end
  for idx, b in pairs(run.boxes) do
    if idx ~= cand.f.entryIdx then
      if not item.relaxed and overlaps(box, b, -5) then return false, "overlap" end
      if front and not item.relaxed and overlaps(front, b, 0) then return false, "front" end
    end
  end
  return true
end

local function skip(item, reason)
  item.skips = item.skips or { plot = 0, block = 0, overlap = 0, front = 0, closes = 0, incompatible = 0, elsewhere = 0, rejected = 0, refused = 0 }
  item.skips[reason] = item.skips[reason] + 1
end

local function addPlacement(run, editor, added, cand)
  local pose = checkedPose(editor, added)
  if not pose then return end
  addEntry(run, added.idx, added.macro, pose)
  run.lastPlacedIdx = added.idx
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
    if not cand or (item.relaxed and item.relaxedTries >= RELAXED_TRIES) then return "exhausted" end
    item.cursor = item.cursor + 1
    checks = checks + 1
    local ok, reason = boxOk(run, item, cand)
    if item.closes then ok, reason = false, "closes" end
    if cand.tested then
      ok = false
    elseif not ok then
      skip(item, reason)
    end
    if ok then
      tries = tries + 1
      cand.tested = true
      if item.relaxed then item.relaxedTries = item.relaxedTries + 1 end
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
            notePlaced(run, item, added.idx, cand)
            sab.Debug("placed %s as entry %d: %s on entry %d %s (%s) at %.0f %.0f %.0f, candidate %d", item.macro, added.idx,
              added.connection, added.predecessorIdx, added.predecessorConnection, cand.f.macro, added.offset.x, added.offset.y, added.offset.z, item.cursor - 1)
            if cand.roll ~= 0 or item.relaxed then
              sab.Debug("  (roll %.0f deg%s)", math.deg(cand.roll), item.relaxed and ", by the engine's collision check" or "")
            end
            return "placed"
          end
          skip(item, "refused")
          sab.Trace("%s: drop refused on entry %d %s / %s", item.macro, cand.f.entryIdx, cand.f.name, cand.m.name)
        else
          skip(item, "rejected")
          sab.Trace("%s: entry %d %s / %s rejected by the editor", item.macro, cand.f.entryIdx, cand.f.name, cand.m.name)
        end
      elseif snap.snapped then
        -- a nearer pair won the snap; the pair itself may still mate
        skip(item, "elsewhere")
        sab.Trace("%s: entry %d %s / %s snapped to entry %d %s / %s instead", item.macro, cand.f.entryIdx, cand.f.name, cand.m.name,
          snap.entryIdx, tostring(snap.predecessorConnection), tostring(snap.connection))
      else
        sab.incompatible[cand.key] = true
        skip(item, "incompatible")
        sab.Trace("%s: %s / %s on %s incompatible", item.macro, cand.f.name, cand.m.name, cand.f.macro)
      end
    end
  end
  return "more"
end

-- what the vanilla drop handler does after a mouse-driven placement; "last" selects the newest plan row
local function refreshPlanTable(placed)
  local menu = sab.menu
  menu.storePlanTableState()
  ---@diagnostic disable-next-line: inject-field
  if placed then menu.selectedRows.plan = "last" end
  menu.refreshPlan()
  menu.displayMenu()
end

local function advance(run)
  run.next = run.next + 1
  run.phase = "begin"
  if tonumber(C.GetNumBuildMapConstructionPlan(sab.menu.holomap, false)) > run.countBefore then sab.planRefresh = true end
end

-- The drop phase of a pack item; the module stays floated across frames while candidates remain.
local function packStep(run, item)
  local menu = sab.menu
  local editor = sab.Editor()
  if not (editor and C.HasBuildMapFloatingSelection(menu.holomap)) then
    C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
    menu.floatingNewModule = nil
    run.failed = run.failed + 1
    sab.Error(editor and "%s is not floating any more" or "no editor for %s", item.macro)
    advance(run)
    return
  end
  if not item.candidates then buildCandidates(run, item) end
  local result = tryCandidates(run, item, editor)
  if result == "more" then return end
  if result == "placed" then
    advance(run)
    return
  end
  local s, total = item.skips or {}, #item.candidates
  local function skipsText()
    return string.format("%d candidates: plot %d, block %d, overlap %d, front %d, closes %d, incompatible %d, elsewhere %d, rejected %d, refused %d", total,
      s.plot or 0, s.block or 0, s.overlap or 0, s.front or 0, s.closes or 0, s.incompatible or 0, s.elsewhere or 0, s.rejected or 0, s.refused or 0)
  end
  if not item.relaxed and ((s.overlap or 0) > 0 or (s.front or 0) > 0) then
    item.relaxed, item.cursor, item.relaxedTries = true, 1, 0
    sab.Debug("%s: no place among %s; the overlapping and front-blocked ones go to the engine's collision check", item.macro, skipsText())
    return
  end
  C.RemoveFloatingSequenceFromConstructionPlan(menu.holomap)
  menu.floatingNewModule = nil
  local need = item.plotNeed
  item.candidates, item.relaxed, item.plotNeed = nil, nil, nil
  if (s.plot or 0) > 0 and need and sab.FitPlot(need.box, false) then
    sab.Debug("%s: no place among %s; retrying in the grown plot", item.macro, skipsText())
    run.phase = "begin"
    return
  end
  if run.kit and not item.isConnector and (item.spurs or 0) < MAX_SPURS then
    local chain, why = spurFor(run, item)
    if chain then
      item.spurs = (item.spurs or 0) + 1
      for i = #chain, 1, -1 do table.insert(run.items, run.next, chain[i]) end
      sab.Debug("%s: no place among %s; a spur %s first (%d of %d)", item.macro, skipsText(), why, item.spurs, MAX_SPURS)
      run.phase = "begin"
      return
    end
    sab.Trace("%s: no spur (%s)", item.macro, tostring(why))
  end
  local connector = run.connector
  if connector and not item.isConnector and (item.connectors or 0) < MAX_REACH then
    item.connectors = (item.connectors or 0) + 1
    if item.connectors == 1 then run.spur = nil end
    table.insert(run.items, run.next, { macro = connector.macro, pack = true, isConnector = true, reach = true, turn = item.turn, owner = item })
    sab.Debug("%s: no place among %s; growing %s outward first (%d of %d)", item.macro, skipsText(), connector.macro, item.connectors, MAX_REACH)
    run.phase = "begin"
    return
  end
  run.failed = run.failed + 1
  sab.Debug("%s: no place found among %s", item.macro, skipsText())
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
-- A bill whose entries carry a turn (planner.Turns) keeps its order: it is the build order.
-- A connector in the bill sets the type the packer grows outward with instead of being an item.
-- opts.grid on an empty plan: the grid layout.
function sab.StartBill(bill, opts)
  local menu = sab.menu
  if not (menu and menu.shown and menu.holomap ~= 0) then
    sab.Error("the build menu is not open")
    return false
  end
  local items, connector, turns = {}, nil, 0
  for _, b in ipairs(bill) do
    local count = tonumber(b.count) or 1
    if IsMacroClass(b.macro, "connectionmodule") then
      connector = { macro = b.macro }
    else
      local size = sab.sizes[b.macro]
      for _ = 1, count do
        items[#items + 1] = { macro = b.macro, pack = true, margin = outerMargin(b.macro), column = columnClass(b.macro), turn = b.turn,
          group = b.group or groupOf(b.macro), volume = size and size.maxX * size.maxY * size.maxZ or 0 }
      end
      turns = math.max(turns, b.turn or 0)
    end
  end
  if turns == 0 then
    table.sort(items, function(a, b)
      if (a.margin ~= nil) ~= (b.margin ~= nil) then return a.margin == nil end
      return a.volume > b.volume
    end)
  end
  if not connector and items[1] then
    local macro = defaultConnector(items[1].macro)
    if macro then connector = { macro = macro } end
  end
  local empty = items[1] and tonumber(C.GetNumBuildMapConstructionPlan(menu.holomap, false)) == 0
  local gridRoute = empty and opts and opts.grid or false
  if empty and not gridRoute then
    local centre = C.GetBuildPlotCenterOffset(menu.container)
    items[1].pack, items[1].free, items[1].pos = nil, true, { x = centre.x, y = centre.y, z = centre.z }
  end
  return sab.StartRun(items, connector, turns > 0 and turns or nil, gridRoute, opts)
end

-- gridRoute: read every module's connection geometry too, then pack on the grid (StartBill, empty plan only).
-- opts.stopOnFail: the run stops at its first failed placement. opts.packOnly: a grid run stops once packed (layout
-- experiments). opts.subdivide: grid occupancy cells per cell side (nil: grid.subdivide).
function sab.StartRun(items, connector, turns, gridRoute, opts)
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
  if not macroDataOk() then
    sab.Error("the Extra Data API cannot read module data on this build")
    return false
  end
  local run = { items = items, next = 1, phase = "begin", placed = 0, failed = 0, connector = connector, turns = turns,
    stopOnFail = opts and opts.stopOnFail, packOnly = opts and opts.packOnly, subdivide = opts and opts.subdivide }
  readPlanState(run, editor)
  if engine == false then return false end
  run.fromEmpty = run.n == 0
  run.gridRoute = gridRoute
  -- connection geometry: every connector (spurs), on the grid route every module too
  local function want(m)
    if m and not sab.macroConns[m] then sab.macroConns[m] = sab.Connections(m) end
  end
  for _, m in ipairs(menu.modules and menu.modules.moduletypes_other or {}) do
    if IsMacroClass(m, "connectionmodule") then want(m) end
  end
  if gridRoute then
    for _, it in ipairs(items) do want(it.macro) end
  end
  finishLayout(run)
  sab.run = run
  sab.panelDirty = true
  sab.Debug("run started: %d items, %d entries, %d connections, connector %s%s", #items, run.n, #run.conns,
    connector and connector.macro or "none", gridRoute and ", grid" or "")
  return true
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
  -- a plan this run started from nothing gets a plot fitted to it on each side
  if run.fromEmpty and run.placed > 0 then
    local box = sab.PlanBox()
    if box then sab.FitPlot(box, true) end
  end
  sab.lastRun = { placed = run.placed, failed = run.failed }
  -- the panel folds to its title and this result until expanded
  sab.expanded, sab.panelDirty = false, true
  refreshPlanTable(run.placed > 0)
end

-- One step per menu update.
-- A pair or free item that landed joins the run's boxes and free connections, as a pack item does in addPlacement.
local function registerEntry(run, item)
  local editor = sab.Editor()
  local plan = sab.ReadPlan()
  local added = plan[#plan]
  if not (editor and added) then return end
  local pose = checkedPose(editor, added)
  if not pose then return end
  addEntry(run, added.idx, added.macro, pose)
  for _, f in ipairs(run.conns) do
    if f.entryIdx == added.predecessorIdx and f.name == added.predecessorConnection then f.used = true end
  end
  for _, c in ipairs(connectionsOf(added.idx, added.macro, pose, { [added.connection] = true })) do
    run.conns[#run.conns + 1] = c
  end
  run.lastPlacedIdx = added.idx
  notePlaced(run, item, added.idx, nil)
end

-- chained: placements already made in this frame (up to sab.perFrame)
function sab.Tick(chained)
  local run = sab.run
  if not run then return end
  local menu = sab.menu
  if not (menu.shown and menu.holomap ~= 0) then
    sab.run = nil
    sab.Debug("run aborted: the build menu closed")
    return
  end
  if run.stopOnFail and run.failed > 0 then
    sab.StopRun("stopped at the first failure")
    return
  end
  if engine == false then
    sab.StopRun("engine access lost")
    return
  end
  if run.phase == "pack" then
    sab.grid.Step(run)
    return
  end
  if run.phase == "confirm" then return end
  if run.phase == "begin" then
    local item = run.items[run.next]
    if not item then
      sab.StopRun("finished")
      return
    end
    beginPlacement(run, item)
    if item.pack or item.dragged then return end
  end
  local item = run.items[run.next]
  if item.pack then
    packStep(run, item)
    return
  end
  local placed, retry = finishPlacement(run, item)
  if retry then return end
  if not placed then
    local limit = perFrame(run)
    if limit > 1 then
      -- the same item again next frame at half the rate; what is placed stays
      run.failed = run.failed - 1
      run.cap = math.floor(limit / 2)
      item.validRetries = nil
      run.phase = "begin"
      sab.Debug("%s failed at %d per frame, again at %d", item.macro, limit, run.cap)
      return
    end
    sab.StopRun("stopped at a failure at one per frame")
    return
  end
  registerEntry(run, item)
  advance(run)
  chained = (chained or 0) + 1
  -- one per frame: the next item floats in the frame of this drop
  local limit = perFrame(run)
  if sab.run == run and (limit <= 1 or chained < limit) then return sab.Tick(chained) end
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

-- { mode, macro, count } rows, kept across menu openings; the last run for the progress line
sab.bill = {}
sab.lastRun = nil
sab.panelDirty = nil
-- "target" or "bill"; the Target tab's inputs live across menu openings, unset choices default from the catalogue
sab.tab = "target"
-- the panel opens as its title bar only
sab.expanded = false
-- goals: the added targets; new: the editor of the next one. Its ware and build module and the race are
-- filled from the catalogue on the first panel build (targetChoices). station: the station it was derived for.
local function defaultTarget()
  return { goals = {}, new = { kind = "ware" }, fullCycle = false, workforce = true, selfSufficient = false, dense = false, moduleRace = "any" }
end
sab.target = defaultTarget()
-- the goal list shows at most this many rows before it scrolls
local MAX_GOAL_ROWS = 5
-- top rows of the scrolling target tables per form, kept over rebuilds
sab.topRows = {}
-- slider tops above what the station has: producer modules of a ware target, build modules of a ship target
local MAX_ADD_MODULES = 100
local MAX_BAYS = 10
-- storage per ware in hours of its flow; nil in a target keeps the planner's default
local MAX_STORAGE_HOURS = 24
-- placements per frame; 1 keeps the dragged float, more drop undragged floats in the same frame
local MAX_PER_FRAME = 10
sab.perFrame = 1

function sab.ResetTarget()
  sab.target = defaultTarget()
  sab.panelDirty = true
end

-- the goal the editor would add equals an added one (same ware, or same build module)
local function goalTaken(n)
  for _, g in ipairs(sab.target.goals) do
    if g.kind == n.kind and (n.kind == "ware" and g.ware == n.ware or n.kind == "ship" and g.buildMacro == n.buildMacro) then
      return true
    end
  end
  return false
end

-- count: the wanted modules of net output (ware) or build modules (ship), one above what the station has
function sab.AddGoal(count)
  local n = sab.target.new
  if goalTaken(n) then return end
  local ware = n.kind == "ware"
  table.insert(sab.target.goals, { kind = n.kind, ware = ware and n.ware or nil, buildMacro = not ware and n.buildMacro or nil,
    modules = ware and (count or 1) or nil, bays = not ware and (count or 1) or nil })
end
-- the map dialog (07c): the last right-clicked sector spot, the open dialog, the target handed to the next build menu
sab.lastSpot = nil
sab.dialog = nil
sab.pendingTarget = nil

local function option(id, text) return { id = id, text = tostring(text), icon = "", displayremoveoption = false } end

local function sortedByText(options)
  table.sort(options, function(a, b) return a.text < b.text end)
  return options
end

-- The Target tab's choice lists from the owned blueprints; an unset or no longer owned choice takes the default.
local function targetChoices(cat)
  local t = sab.target
  local wares, seen = {}, {}
  for _, group in ipairs({ "production", "processing" }) do
    for _, e in ipairs(cat[group]) do
      for _, p in ipairs(e.products or {}) do
        if not seen[p.ware] then
          seen[p.ware] = true
          wares[#wares + 1] = option(p.ware, sab.planner.Ware(p.ware).name)
        end
      end
    end
  end
  local builds = {}
  for _, e in ipairs(cat.build) do
    if not goalTaken({ kind = "ship", buildMacro = e.macro }) then builds[#builds + 1] = option(e.macro, e.name) end
  end
  local habitats, races, makers, moduleRaces = {}, {}, {}, {}
  for _, e in ipairs(cat.habitation) do habitats[e.race] = (habitats[e.race] or 0) + 1 end
  for _, group in ipairs({ "production", "processing", "storage", "dock" }) do
    for _, e in ipairs(cat[group]) do
      for r in pairs(e.races) do makers[r] = true end
    end
  end
  for _, r in ipairs(GetLibrary("races")) do
    if habitats[r.id] then races[#races + 1] = option(r.id, r.name) end
    if makers[r.id] then moduleRaces[#moduleRaces + 1] = option(r.id, r.name) end
  end
  sortedByText(wares); sortedByText(builds); sortedByText(races); sortedByText(moduleRaces)
  table.insert(moduleRaces, 1, option("any", ReadText(PAGE, 151)))
  -- the editor offers the wares no added goal takes
  local taken = {}
  for _, g in ipairs(t.goals) do
    if g.kind == "ware" and g.ware then taken[g.ware] = true end
  end
  local free = {}
  for _, w in ipairs(wares) do
    if not taken[w.id] then free[#free + 1] = w end
  end
  local new = t.new
  if not (seen[new.ware] and not taken[new.ware]) then new.ware = free[1] and free[1].id end
  if not (new.buildMacro and cat.byMacro[new.buildMacro] and not goalTaken({ kind = "ship", buildMacro = new.buildMacro })) then
    new.buildMacro = builds[1] and builds[1].id
  end
  -- one kind of target per station: the first added goal fixes it
  if t.goals[1] then new.kind = t.goals[1].kind end
  -- the workforce race: argon first, else the race with the most owned habitats
  if not habitats[t.race] then
    local best, most = nil, 0
    for race, n in pairs(habitats) do
      if n > most then best, most = race, n end
    end
    t.race = habitats.argon and "argon" or best
  end
  if not makers[t.moduleRace] then t.moduleRace = "any" end
  return { wares = free, builds = builds, races = races, moduleRaces = moduleRaces }
end

-- Where a target is planned: the build menu's station, or a sector spot before the station exists.
function sab.PanelContext()
  local menu = sab.menu
  return { set = menu.set, station = menu.container ~= 0 and menu.container or nil }
end

-- The ware's modules and production on the panel's station now; none on a spot before the station exists.
local function currentOf(ctx, ware)
  if not (ctx.station and ware) then return { modules = 0, production = 0, net = 0 } end
  return sab.planner.Current(ctx.station, ware)
end

-- The ware's net output now in modules of its current output: the modules beyond the station's own use.
local function extraModules(current)
  if current.modules == 0 or current.production <= 0 then return current.modules end
  return current.net * current.modules / current.production
end

-- The build modules of a macro the station has, planned ones included.
local function baysOf(ctx, macro)
  return sab.planner.ModuleCount(ctx.station, macro)
end

-- The form's target: derived from the panel's station when the panel first shows on it, again once the build
-- menu has loaded the station's plan; the empty one on a spot or after Reset without a station.
local function formTarget(ctx)
  local t = sab.target
  local planRead = ctx.station ~= nil and sab.menu.holomap ~= 0
  if t.station == ctx.station and (t.planRead or not planRead) then return t end
  t = defaultTarget()
  t.station, t.planRead = ctx.station, planRead
  if ctx.station then
    local d = sab.planner.Derive(ctx.station, ctx.set)
    t.goals, t.fullCycle, t.workforce, t.selfSufficient, t.race = d.goals, d.fullCycle, d.workforce, d.selfSufficient, d.race
    if d.goals[1] then t.new.kind = d.goals[1].kind end
    sab.Debug("target derived for %s: %d goals, full cycle %s, workforce %s, self-sufficient %s, race %s", tostring(ctx.station), #d.goals,
      tostring(d.fullCycle), tostring(d.workforce), tostring(d.selfSufficient), tostring(d.race))
  end
  sab.target = t
  return t
end

-- A ware goal's modules are modules of net output, beyond what the station and the other goals consume; a
-- ship goal's bays count the station's own. The plan adds the difference; the spec keeps the form's order.
function sab.TargetSpec(ctx)
  local t = formTarget(ctx)
  -- a run before the form was ever built (eval, a collapsed panel) still needs the race
  if not t.race then targetChoices(sab.planner.Catalogue(ctx.set, true)) end
  local goals = {}
  for _, g in ipairs(t.goals) do
    if g.kind == "ware" then
      goals[#goals + 1] = { kind = "ware", ware = g.ware, modules = math.max(0, (g.modules or 1) - extraModules(currentOf(ctx, g.ware))) }
    else
      local have = baysOf(ctx, g.buildMacro)
      goals[#goals + 1] = { kind = "ship", buildMacro = g.buildMacro, count = math.max(0, (g.bays or 1) - have), bays = math.max(g.bays or 1, have) }
    end
  end
  return { set = ctx.set, station = ctx.station, sunlight = ctx.sunlight, goals = goals,
    fullCycle = t.fullCycle, workforce = t.workforce, selfSufficient = t.fullCycle and t.workforce and t.selfSufficient,
    race = t.race, moduleRace = t.moduleRace ~= "any" and t.moduleRace or nil, dense = t.dense, storageHours = t.storageHours }
end

function sab.RunTarget()
  local spec = sab.planner and sab.TargetSpec(sab.PanelContext())
  if not spec then return end
  if sab.planner.Run(spec) then sab.panelDirty = true end
end

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
  return sab.Editor() ~= nil and macroDataOk()
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
    return string.format(tostring(ReadText(PAGE, 135)), run.n, run.n + math.max(0, #run.items - run.next + 1), run.failed)
  end
  if not sab.Editor() then return ReadText(PAGE, 108) end
  if not macroDataOk() then return ReadText(PAGE, 153) end
  local last = sab.lastRun
  if last and last.declined then return ReadText(PAGE, 143) end
  if last and last.tooLarge then return string.format(tostring(ReadText(PAGE, 147)), last.tooLarge, MAX_PLOT / 1000) end
  if last then return string.format(tostring(ReadText(PAGE, 107)), last.placed, last.failed) end
  return ""
end

-- the item in work and how far its candidate list is; the plot offer while it waits
local function progressDetail()
  local run = sab.run
  local o = run and run.phase == "confirm" and run.offer
  if o then
    return string.format(tostring(ReadText(PAGE, 142)), math.floor(o.size.x / 1000 + 0.5), math.floor(o.size.y / 1000 + 0.5), math.floor(o.size.z / 1000 + 0.5),
      ConvertMoneyString(o.price, false, true, 0, true) .. " " .. ReadText(1001, 101))
  end
  local item = run and run.items[run.next]
  if not item then return "" end
  local p = run.phase == "pack" and run.packProgress
  if p and p.dock then return string.format(tostring(ReadText(PAGE, 139)), p.dock, p.docks) end
  if p then return string.format(tostring(ReadText(PAGE, 136)), p.pack, p.packs, p.module, p.modules) end
  -- grid and pair items snap to a planned connection: no candidate list to count
  local name = GetMacroData(item.macro, "name")
  local text = item.candidates and string.format(tostring(ReadText(PAGE, 131)), name, item.cursor - 1, #item.candidates) or tostring(name)
  if item.turn and run.turns and not run.gridRoute then text = string.format(tostring(ReadText(PAGE, 132)), item.turn, run.turns) .. ", " .. text end
  return text
end

-- the bar: packed modules over every layout, docks with a place found, then plan entries of the planned total
local function progressValues()
  local run = sab.run
  if not run then return 0, 1 end
  local p = run.phase == "pack" and run.packProgress
  if p and p.dock then return p.dock - 1, math.max(1, p.docks) end
  if p then return (p.pack - 1) * p.modules + p.module, math.max(1, p.packs * p.modules) end
  return run.n, math.max(1, run.n + math.max(0, #run.items - run.next + 1))
end

local function progressDone()
  return (progressValues())
end

local function progressTotal()
  local _, total = progressValues()
  return total
end

-- Input rows of a 4-column form table; a change marks the owning frame dirty through `dirty`.
local function rowKit(ftable, idle, buttonHeight, dirty)
  local kit = {}
  function kit.input(label)
    local row = ftable:addRow(true, {})
    row[1]:createText(label, { minRowHeight = buttonHeight })
    return row
  end
  function kit.dropdown(row, options, current, onChange, active)
    row[2]:setColSpan(3):createDropDown(options, { startOption = current or "", height = buttonHeight, active = idle and #options > 0 and active ~= false })
    row[2].handlers.onDropDownConfirmed = function(_, id)
      if id ~= current then onChange(id); dirty() end
    end
  end
  function kit.checkbox(row, checked, active, onChange)
    row[4]:createCheckBox(checked, { height = buttonHeight, width = buttonHeight, active = idle and active })
    row[4].handlers.onClick = function(_, value) onChange(value); dirty() end
  end
  return kit
end

-- A 4-column form table: label, wide input, a narrow column, a checkbox column; scrolls above maxHeight.
local function formTable(frame, tabOrder, y, buttonHeight, maxHeight)
  local ftable = frame:addTable(4, { tabOrder = tabOrder, highlightMode = "off", reserveScrollBar = false, y = y, maxVisibleHeight = maxHeight })
  ftable:setColWidthPercent(1, 30)
  ftable:setColWidth(3, Helper.scaleX(50), false)
  ftable:setColWidth(4, Helper.scaleY(buttonHeight), false)
  return ftable
end

-- The licence due on the plot with its Buy button, as vanilla's plot panel shows it; returns the next y.
local function feeTable(frame, tabOrder, y, buttonHeight)
  local fee = sab.PlotFee()
  if not fee then return y end
  local ftable = frame:addTable(2, { tabOrder = tabOrder, highlightMode = "off", reserveScrollBar = false, y = y })
  local row = ftable:addRow(true, {})
  row[1]:createText(ReadText(1001, 9242) .. ReadText(1001, 120) .. " " .. ConvertMoneyString(fee, false, true, 0, true) .. " " .. ReadText(1001, 101),
    { halign = "left", minRowHeight = buttonHeight })
  row[2]:createButton({ height = buttonHeight, active = function() return GetPlayerMoney() >= fee end }):setText(ReadText(1001, 9233), { halign = "center" })
  row[2].handlers.onClick = sab.BuyPlot
  return ftable.properties.y + ftable:getVisibleHeight() + Helper.borderSize
end

-- The scroll positions of a form's goal and plan tables, read before its frame is rebuilt.
local function saveTopRows(key)
  local tables = sab.formTables and sab.formTables[key]
  if not tables then return end
  local tops = {}
  for name, ftable in pairs(tables) do
    if ftable.id then tops[name] = GetTopRow(ftable.id) end
  end
  sab.topRows[key] = tops
end

-- The goal's slider text: the ware with its net now and planned, a fabrication bay with its ships per hour
-- now and planned, a maintenance bay by its name.
local function goalText(g, i, ok, plan, cat, ctx)
  if g.kind == "ware" then
    local current = currentOf(ctx, g.ware)
    local planned = ok and current.net + (plan.produced[g.ware] or 0) - (plan.consumed[g.ware] or 0) or current.net
    return sab.planner.Ware(g.ware).name .. ": " .. string.format(tostring(ReadText(PAGE, 140)), string.format("%+d", math.floor(current.net + 0.5)),
      string.format("%+d", math.floor(planned + 0.5)))
  end
  local name = cat.byMacro[g.buildMacro] and cat.byMacro[g.buildMacro].name or tostring(g.buildMacro)
  local hours = ok and plan.shipHours[i]
  if not (hours and hours > 0) then return name end
  local now = baysOf(ctx, g.buildMacro) / hours
  return name .. ": " .. string.format(tostring(ReadText(PAGE, 140)), string.format("%.1f", now), string.format("%.1f", now + plan.shipRates[i]))
end

-- The target form from y down: the editor of the next goal with its Add button, the added goals under their
-- header (one slider row each, its text the goal, its value the count from the station's own up, released there
-- it is removed; scrolls past MAX_GOAL_ROWS), the shared settings and `extraRows(kit)` (never scroll), the
-- planned bill and balance (scroll down to `bottom`).
-- key names the form for its scroll positions. Returns the plan (nil when the planner fails), the next tab
-- order and the y below the tables.
local function addTargetTables(frame, tabOrder, y, bottom, idle, buttonHeight, ctx, dirty, extraRows, key)
  local t = formTarget(ctx)
  local cat = sab.planner.Catalogue(ctx.set, true)
  local choices = targetChoices(cat)
  local ok, plan = pcall(sab.planner.Plan, sab.TargetSpec(ctx))
  local tops = sab.topRows[key] or {}
  local tables = {}
  sab.formTables = sab.formTables or {}
  sab.formTables[key] = tables

  local ftable = formTable(frame, tabOrder, y, buttonHeight)
  tabOrder = tabOrder + 1
  local kit = rowKit(ftable, idle, buttonHeight, dirty)
  local input, dropdown = kit.input, kit.dropdown
  local n = t.new
  local kinds = { option("ware", ReadText(PAGE, 111)), option("ship", ReadText(PAGE, 112)) }
  -- the first added goal fixes the kind
  dropdown(input(ReadText(PAGE, 109)), kinds, n.kind, function(id) n.kind = id end, t.goals[1] == nil)
  if n.kind == "ware" then
    dropdown(input(ReadText(PAGE, 114)), choices.wares, n.ware, function(id) n.ware = id end)
  else
    dropdown(input(ReadText(PAGE, 117)), choices.builds, n.buildMacro, function(id) n.buildMacro = id end)
  end
  local addable = (n.kind == "ware" and n.ware or n.kind == "ship" and n.buildMacro) and not goalTaken(n)
  local row = ftable:addRow(true, {})
  row[1]:setColSpan(4):createButton({ height = buttonHeight, active = idle and addable and true or false }):setText(ReadText(PAGE, 145), { halign = "center" })
  row[1].handlers.onClick = function()
    -- a new goal starts one module above what the station has: ware modules of net output, or build modules
    sab.AddGoal(n.kind == "ware" and math.max(0, math.floor(extraModules(currentOf(ctx, n.ware)) + 1e-6)) + 1 or baysOf(ctx, n.buildMacro) + 1)
    sab.goalsToEnd = key
    dirty()
  end
  y = ftable.properties.y + ftable:getVisibleHeight() + Helper.borderSize

  if #t.goals > 0 then
    local rowHeight = Helper.scaleY(buttonHeight) + Helper.borderSize
    local headerHeight = Helper.scaleY(Helper.subHeaderHeight) + Helper.borderSize
    local gtable = formTable(frame, tabOrder, y, buttonHeight, headerHeight + MAX_GOAL_ROWS * rowHeight)
    tabOrder = tabOrder + 1
    local header = gtable:addRow(false, { fixed = true })
    header[1]:setColSpan(4):createText(string.format(tostring(ReadText(PAGE, 152)), #t.goals), Helper.subHeaderTextProperties)
    for i, g in ipairs(t.goals) do
      local ware = g.kind == "ware"
      -- never below what the station has, built or planned
      local low = ware and math.max(0, math.floor(extraModules(currentOf(ctx, g.ware)) + 1e-6)) or baysOf(ctx, g.buildMacro)
      local top = low + (ware and MAX_ADD_MODULES or MAX_BAYS)
      if ware then g.modules = math.max(low, math.min(top, g.modules or 1)) else g.bays = math.max(low, math.min(top, g.bays or 1)) end
      row = gtable:addRow(true, {})
      row[1]:setColSpan(4):createSliderCell({ height = buttonHeight, valueColor = Color["slider_value"], min = low, minSelect = low, max = top,
        start = ware and g.modules or g.bays, step = 1, hideMaxValue = true, active = idle, mouseOverText = ReadText(PAGE, 144) })
          :setText(goalText(g, i, ok, plan, cat, ctx))
      row[1].handlers.onSliderCellChanged = function(_, value)
        if ware then g.modules = value else g.bays = value end
      end
      row[1].handlers.onSliderCellConfirm = function()
        if (ware and g.modules or g.bays) <= low then
          for j, h in ipairs(t.goals) do
            if h == g then table.remove(t.goals, j); break end
          end
        end
        dirty()
      end
    end
    -- a goal just added shows at the bottom (row 1 is the fixed header)
    if sab.goalsToEnd == key then
      sab.goalsToEnd = nil
      gtable:setTopRow(math.max(2, #t.goals - MAX_GOAL_ROWS + 2))
    elseif tops.goals then
      gtable:setTopRow(tops.goals)
    end
    tables.goals = gtable
    y = gtable.properties.y + gtable:getVisibleHeight() + Helper.borderSize
  end

  local stable = formTable(frame, tabOrder, y, buttonHeight)
  tabOrder = tabOrder + 1
  kit = rowKit(stable, idle, buttonHeight, dirty)
  input, dropdown = kit.input, kit.dropdown
  local checkbox = kit.checkbox
  dropdown(input(ReadText(PAGE, 150)), choices.moduleRaces, t.moduleRace, function(id) t.moduleRace = id end)
  checkbox(input(ReadText(PAGE, 119)), t.fullCycle, true, function(v) t.fullCycle = v end)
  checkbox(input(ReadText(PAGE, 120)), t.workforce, true, function(v) t.workforce = v end)
  checkbox(input(ReadText(PAGE, 121)), t.selfSufficient, t.fullCycle and t.workforce, function(v) t.selfSufficient = v end)
  dropdown(input(ReadText(PAGE, 149)), choices.races, t.race, function(id) t.race = id end)
  -- the grid packs an empty plan only
  local fresh = not ctx.station or (sab.menu.holomap ~= 0 and tonumber(C.GetNumBuildMapConstructionPlan(sab.menu.holomap, false)) == 0)
  checkbox(input(ReadText(PAGE, 134)), t.dense, fresh, function(v) t.dense = v end)
  row = stable:addRow(true, {})
  row[1]:setColSpan(4):createSliderCell({ height = buttonHeight, valueColor = Color["slider_value"], min = 1, minSelect = 1, max = MAX_STORAGE_HOURS,
    start = t.storageHours or sab.planner.storageHours, step = 1, active = idle }):setText(ReadText(PAGE, 148))
  ---@diagnostic disable-next-line: inject-field
  row[1].handlers.onSliderCellChanged = function(_, value) t.storageHours = value end
  row[1].handlers.onSliderCellConfirm = dirty
  if extraRows then extraRows(kit) end
  y = stable.properties.y + stable:getVisibleHeight() + Helper.borderSize

  -- the planned modules and their effect share the rest, each scrolling on its own with three rows at least
  local minHeight = 3 * (Helper.scaleY(Helper.standardTextHeight) + Helper.borderSize)
  local ptable = formTable(frame, tabOrder, y, buttonHeight, math.max(minHeight, math.floor((bottom - y - Helper.borderSize) / 2)))
  tabOrder = tabOrder + 1
  tables.planned = ptable
  local header = ptable:addRow(false, { fixed = true })
  header[1]:setColSpan(4):createText(ReadText(PAGE, 122), Helper.subHeaderTextProperties)
  if not ok then
    row = ptable:addRow(true, {})
    row[1]:setColSpan(4):createText(string.format(tostring(ReadText(PAGE, 125)), tostring(plan)), { color = Color["text_warning"] })
    return nil, tabOrder, ptable.properties.y + ptable:getVisibleHeight() + Helper.borderSize
  end
  for _, b in ipairs(sab.planner.Bill(plan)) do
    row = ptable:addRow(true, {})
    row[1]:createText(tostring(b.count) .. " x", { halign = "right" })
    row[2]:setColSpan(3):createText(cat.byMacro[b.macro].name, {})
  end
  if plan.lacks and plan.lacks.any then
    local names = {}
    for w in pairs(plan.lacks.wares) do names[#names + 1] = sab.planner.Ware(w).name end
    table.sort(names)
    if plan.lacks.workforce > 0 then names[#names + 1] = tostring(ReadText(PAGE, 120)) end
    row = ptable:addRow(true, {})
    row[1]:setColSpan(4):createText(string.format(tostring(ReadText(PAGE, 146)), table.concat(names, ", ")), { wordwrap = true })
  end
  if tops.planned then ptable:setTopRow(tops.planned) end
  y = ptable.properties.y + ptable:getVisibleHeight() + Helper.borderSize

  local wares = {}
  for w in pairs(plan.consumed) do
    if math.abs((plan.produced[w] or 0) - plan.consumed[w]) >= 1 then wares[#wares + 1] = w end
  end
  if #wares == 0 and not plan.adds and #plan.warnings == 0 then return plan, tabOrder, y end
  table.sort(wares, function(a, b) return sab.planner.Ware(a).name < sab.planner.Ware(b).name end)
  local etable = formTable(frame, tabOrder, y, buttonHeight, math.max(minHeight, bottom - y))
  tabOrder = tabOrder + 1
  tables.effect = etable
  for _, w in ipairs(wares) do
    row = etable:addRow(true, {})
    row[1]:setColSpan(2):createText(sab.planner.Ware(w).name, {})
    row[3]:setColSpan(2):createText(string.format(tostring(ReadText(PAGE, 123)), string.format("%+d", (plan.produced[w] or 0) - plan.consumed[w])), { halign = "right" })
  end
  if plan.adds then
    row = etable:addRow(true, {})
    row[1]:setColSpan(4):createText(string.format(tostring(ReadText(PAGE, 124)), plan.workforce, plan.workforceCapacity,
      math.floor(plan.workforceFraction * 100 + 0.5), math.floor(plan.flow.import), math.floor(plan.flow.export)), {})
  end
  for _, warning in ipairs(plan.warnings) do
    row = etable:addRow(true, {})
    row[1]:setColSpan(4):createText(warning, { color = Color["text_warning"] })
  end
  if tops.effect then etable:setTopRow(tops.effect) end
  return plan, tabOrder, etable.properties.y + etable:getVisibleHeight() + Helper.borderSize
end

-- The Bill tab: the manual rows.
local function addBillRows(ftable, idle, buttonHeight)
  local menu = sab.menu
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
  return #catOptions > 0
end

function sab.DisplayPanel()
  local menu = sab.menu
  if not (menu.shown and menu.titleData and menu.titleData.width) then return end
  saveTopRows("panel")
  Helper.clearDataForRefresh(menu, PANEL_LAYER)
  local idle = sab.run == nil
  local buttonHeight = Helper.standardButtonHeight
  local target = sab.tab == "target" and sab.planner ~= nil

  local width = math.floor(menu.titleData.width * 0.6)
  local x = menu.titleData.offsetX + menu.titleData.width - width
  local y = menu.titleData.offsetY + menu.titleData.height + 2 * Helper.borderSize
  local frame = Helper.createFrameHandle(menu, {
    layer = PANEL_LAYER, standardButtons = {}, width = width, x = x, y = y, autoFrameHeight = true,
  })
  frame:setBackground("solid", { color = Color["frame_background_semitransparent"] })
  sab.panelFrame = frame

  -- the head: the title with a small show/hide arrow at its right end, then two equal tab buttons
  local head = frame:addTable(3, { tabOrder = 1, highlightMode = "off", reserveScrollBar = false })
  head:setColWidth(3, Helper.scaleY(buttonHeight), false)
  local title = head:addRow(true, { bgColor = Color["row_title_background"] })
  title[1]:setColSpan(2):createText(ReadText(PAGE, 100), Helper.headerRowCenteredProperties)
  title[3]:createButton({ height = buttonHeight, width = buttonHeight, bgColor = Color["row_title_background"],
    mouseOverText = ReadText(PAGE, sab.expanded and 127 or 126) })
      :setIcon(sab.expanded and "widget_arrow_up_01" or "widget_arrow_down_01")
  title[3].handlers.onClick = function()
    sab.expanded = not sab.expanded
    if sab.expanded then sab.lastRun = nil end
    sab.panelDirty = true
  end
  if not sab.expanded then
    if sab.lastRun and idle then
      local status = head:addRow(true, {})
      status[1]:setColSpan(3):createText(progressText, { halign = "left", minRowHeight = buttonHeight })
    end
    if idle then feeTable(frame, 2, head.properties.y + head:getVisibleHeight() + Helper.borderSize, buttonHeight) end
    frame:display()
    return
  end
  if sab.planner then
    local tabs = head:addRow(true, {})
    for i, tab in ipairs({ { id = "target", text = ReadText(PAGE, 109) }, { id = "bill", text = ReadText(PAGE, 110) } }) do
      local current = tab.id == sab.tab
      tabs[i]:createButton({ height = buttonHeight, bgColor = Color["toplevel_button_background"] })
          :setText(tab.text, { halign = "center", color = current and Color["text_normal"] or Color["text_inactive"] })
      if not current then
        tabs[i].handlers.onClick = function()
          sab.tab = tab.id
          sab.panelDirty = true
        end
      end
    end
  end
  -- the progress sits under the tabs; during a run the tab content is hidden so the map stays in view
  local prow = head:addRow(true, {})
  prow[1]:setColSpan(3):createText(progressText, { halign = "left", minRowHeight = buttonHeight })
  if not idle then
    prow = head:addRow(true, {})
    prow[1]:setColSpan(3):createStatusBar({ current = progressDone, start = progressDone, max = progressTotal, cellBGColor = Color["row_background"],
      valueColor = Color["slider_value"], posChangeColor = Color["statusbar_diff_neg_default"], markerColor = Color["statusbar_marker_hidden"],
      width = width - 2 * Helper.borderSize, height = Helper.scaleY(Helper.standardTextHeight), x = Helper.borderSize, scaling = false })
    prow = head:addRow(true, {})
    prow[1]:setColSpan(3):createText(progressDetail, { halign = "left", minRowHeight = buttonHeight })
  end
  local contentY = head.properties.y + head:getVisibleHeight() + Helper.borderSize

  local canAdd, plan, tabOrder = false, nil, 2
  if idle then
    -- the button table below needs three rows of the view
    local bottom = Helper.viewHeight - y - Helper.frameBorder - Helper.scaleY(3 * buttonHeight)
    if target then
      plan, tabOrder, contentY = addTargetTables(frame, tabOrder, contentY, bottom, idle, buttonHeight, sab.PanelContext(),
        function() sab.panelDirty = true end, nil, "panel")
    else
      local ftable = formTable(frame, tabOrder, contentY, buttonHeight, bottom - contentY)
      tabOrder = tabOrder + 1
      canAdd = addBillRows(ftable, idle, buttonHeight)
      contentY = ftable.properties.y + ftable:getVisibleHeight() + Helper.borderSize
    end
  end

  if idle then
    contentY = feeTable(frame, tabOrder, contentY, buttonHeight)
    tabOrder = tabOrder + 1
  end
  local canOptimize = idle and sab.CanOptimizePlot()
  local btable = frame:addTable(4, { tabOrder = tabOrder, highlightMode = "off", reserveScrollBar = false, y = contentY })
  local row
  local offer = sab.run and sab.run.phase == "confirm" and sab.run.offer
  if offer then
    row = btable:addRow(true, {})
    row[1]:setColSpan(2):createButton({ height = buttonHeight, active = function() return GetPlayerMoney() >= offer.price end })
        :setText(ReadText(1001, 9233), { halign = "center" })
    row[1].handlers.onClick = function() sab.AnswerPlot(true) end
    row[3]:setColSpan(2):createButton({ height = buttonHeight }):setText(ReadText(1001, 64), { halign = "center" })
    row[3].handlers.onClick = function() sab.AnswerPlot(false) end
  end
  row = btable:addRow(true, {})
  row[1]:setColSpan(4):createSliderCell({ height = buttonHeight, valueColor = Color["slider_value"], min = 1, minSelect = 1,
    max = MAX_PER_FRAME, start = sab.perFrame, step = 1 }):setText(ReadText(PAGE, 138))
  row[1].handlers.onSliderCellChanged = function(_, value) sab.perFrame = value end
  row = btable:addRow(true, {})
  if target then
    -- nothing to add: every goal is at what the station has
    local adds = plan ~= nil and plan.adds
    local function canRun() return adds and sab.run == nil and sab.RouteOk() end
    row[1]:createButton({ height = buttonHeight, active = canRun }):setText(ReadText(PAGE, 103), { halign = "center" })
    row[1].handlers.onClick = sab.RunTarget
    row[2]:createButton({ height = buttonHeight, active = function() return sab.run ~= nil end }):setText(ReadText(PAGE, 104), { halign = "center" })
    row[2].handlers.onClick = function() sab.StopRun("stopped") end
    row[3]:createButton({ height = buttonHeight, active = canOptimize }):setText(ReadText(PAGE, 105), { halign = "center" })
    row[3].handlers.onClick = sab.OptimizePlot
    row[4]:createButton({ height = buttonHeight, active = idle }):setText(ReadText(1001, 3318), { halign = "center" })
    row[4].handlers.onClick = sab.ResetTarget
  else
    row[1]:createButton({ height = buttonHeight, active = idle and canAdd }):setText(ReadText(1001, 3106), { halign = "center" })
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
    row[1]:createButton({ height = buttonHeight, active = canOptimize }):setText(ReadText(PAGE, 105), { halign = "center" })
    row[1].handlers.onClick = sab.OptimizePlot
  end

  frame:display()
end

-- *** map dialog (07c) ***
-- The Interact Menu API entry on an empty sector spot (MD cue Plot_Menu_Item) raises StationAutoBuilder.PlotDialog;
-- the spot itself is taken from the interact menu at its open. OK reserves the plot there, sets the station-wide
-- options and opens the build menu, which starts the run from sab.pendingTarget.

local DIALOG_LAYER = 3 -- the map draws on 2, 4, 5 and 6
local LOADOUTS = { { 0, 7990 }, { 0.1, 7910 }, { 0.5, 7911 }, { 1.0, 7912 }, { -1, 7968 } }

-- "global" stands for the empty container method (a dropdown needs a non-empty id)
local function buildMethodOptions()
  local options = { option("global", ReadText(1001, 8367)) }
  local n = C.GetNumPlayerBuildMethods()
  if n > 0 then
    local buf = ffi.new("ProductionMethodInfo[?]", n)
    n = C.GetPlayerBuildMethods(buf, n)
    for i = 0, n - 1 do options[#options + 1] = option(ffi.string(buf[i].id), ffi.string(buf[i].name)) end
  end
  return options
end

local function dialogContext(d)
  return { set = "factory", sunlight = GetComponentData(d.sector, "sunlight") }
end

function sab.OpenPlotDialog()
  local menu, spot = sab.mapMenu, sab.lastSpot
  if not (sab.planner and menu and menu.shown and spot) then
    sab.Debug("plot dialog: no planner, map or spot")
    return
  end
  sab.dialog = { sector = spot.sector, x = spot.x, y = spot.y, z = spot.z, loadout = 1.0, method = "global" }
  sab.target = defaultTarget()
  sab.dialogDirty = true
end

function sab.CloseDialog()
  sab.dialog, sab.dialogFrame = nil, nil
  Helper.clearFrame(sab.mapMenu, DIALOG_LAYER)
end

function sab.DisplayDialog()
  local menu, d = sab.mapMenu, sab.dialog
  if not (d and menu.shown) then return end
  saveTopRows("dialog")
  Helper.clearDataForRefresh(menu, DIALOG_LAYER)
  local buttonHeight = Helper.standardButtonHeight
  local width = math.floor(Helper.viewWidth * 0.3)
  local x = math.floor((Helper.viewWidth - width) / 2)
  local y = math.floor(Helper.viewHeight * 0.1)
  local frame = Helper.createFrameHandle(menu, {
    layer = DIALOG_LAYER, standardButtons = {}, width = width, x = x, y = y, autoFrameHeight = true,
  })
  frame:setBackground("solid", { color = Color["frame_background_semitransparent"] })
  sab.dialogFrame = frame
  local function dirty() sab.dialogDirty = true end

  local ttable = frame:addTable(1, { tabOrder = 1, highlightMode = "off", reserveScrollBar = false })
  local title = ttable:addRow(false, { bgColor = Color["row_title_background"] })
  title[1]:createText(string.format(tostring(ReadText(PAGE, 130)), tostring(GetComponentData(d.sector, "name"))), Helper.headerRowCenteredProperties)

  -- the error and button rows below need three rows of the view
  local bottom = Helper.viewHeight - y - Helper.frameBorder - Helper.scaleY(3 * buttonHeight)
  local plan, tabOrder, nextY = addTargetTables(frame, 2, ttable.properties.y + ttable:getVisibleHeight() + Helper.borderSize, bottom, true,
    buttonHeight, dialogContext(d), dirty, function(kit)
      local loadouts = {}
      for _, l in ipairs(LOADOUTS) do loadouts[#loadouts + 1] = option(l[1], ReadText(1001, l[2])) end
      kit.dropdown(kit.input(ReadText(1001, 7967)), loadouts, d.loadout, function(id) d.loadout = tonumber(id) end)
      kit.dropdown(kit.input(ReadText(1001, 11298)), buildMethodOptions(), d.method, function(id) d.method = id end)
    end, "dialog")

  local btable = frame:addTable(2, { tabOrder = tabOrder, highlightMode = "off", reserveScrollBar = false, y = nextY })
  local row
  if d.error then
    row = btable:addRow(true, {})
    row[1]:setColSpan(2):createText(d.error, { color = Color["text_warning"] })
  end
  row = btable:addRow(true, {})
  row[1]:createButton({ height = buttonHeight, active = plan ~= nil and plan.adds }):setText(ReadText(1001, 14), { halign = "center" })
  row[1].handlers.onClick = sab.ConfirmDialog
  row[2]:createButton({ height = buttonHeight }):setText(ReadText(1001, 64), { halign = "center" })
  row[2].handlers.onClick = sab.CloseDialog
  frame:display()
end

-- OK: reserve the plot at the spot, pay it where vanilla would, set the station-wide options, open the build menu.
function sab.ConfirmDialog()
  local menu, d = sab.mapMenu, sab.dialog
  if not d then return end
  local spec = sab.TargetSpec(dialogContext(d))
  local ok, plan = pcall(sab.planner.Plan, spec)
  if not ok then
    sab.Error("plan failed: %s", tostring(plan))
    return
  end
  -- the smallest plot: the run grows it to the modules
  local size = PLOT_STEP
  local loc = ffi.new("UIPosRot")
  loc.x, loc.y, loc.z = d.x, d.y, d.z
  local station = C.ReserveBuildPlot(d.sector, "player", "factory", loc, size, size, size)
  if station == 0 then
    d.error = ReadText(PAGE, 129)
    sab.dialogDirty = true
    sab.Debug("plot of %d m refused at %s %.0f %.0f %.0f", size, tostring(d.sector), d.x, d.y, d.z)
    return
  end
  station = ConvertStringTo64Bit(tostring(station))
  if GetComponentData(d.sector, "isplayerowned") then
    C.PayBuildPlotSize(station, { x = size, y = size, z = size }, { x = d.x, y = d.y, z = d.z })
  end
  C.SetStationModuleLoadoutLevel(station, d.loadout)
  local method = d.method == "global" and "" or d.method
  local buildstorage = ConvertIDTo64Bit(GetComponentData(station, "buildstorage")) or 0
  if buildstorage ~= 0 then C.SetContainerBuildMethod(buildstorage, method) end
  sab.pendingTarget = { station = station, spec = spec, method = buildstorage == 0 and method or nil, since = getElapsedTime() }
  -- the build menu keeps the dialog's goals for the new station
  sab.target.station, sab.target.planRead = station, true
  sab.Debug("plot reserved: station %s, %d m, loadout %s, method '%s', build storage %s", tostring(station), size,
    tostring(d.loadout), method, tostring(buildstorage))
  sab.CloseDialog()
  AddUITriggeredEvent(menu.name, "initiateconstruction_station", station)
  Helper.closeMenuAndOpenNewMenu(menu, MENU_NAME, { 0, 0, station })
  menu.cleanup()
end

-- The build menu opened on the reserved plot: start the planned run.
function sab.StartPending()
  local menu, p = sab.menu, sab.pendingTarget
  local age = getElapsedTime() - p.since
  if menu.container ~= p.station then
    if age > 30 then
      sab.pendingTarget = nil
      sab.Debug("pending target dropped: another station opened")
    end
    return
  end
  if not sab.RouteOk() then
    sab.pendingTarget = nil
    sab.Error("pending target dropped: the route is unavailable on this build")
    return
  end
  sab.pendingTarget = nil
  if p.method and menu.buildstorage ~= 0 then C.SetContainerBuildMethod(menu.buildstorage, p.method) end
  ---@diagnostic disable-next-line: inject-field
  p.spec.station, p.spec.set = menu.container, menu.set
  sab.expanded, sab.tab = true, "target"
  if sab.planner.Run(p.spec) then sab.panelDirty = true end
end

local function findMenu(name)
  for _, menu in ipairs(Menus) do
    if menu.name == name then return menu end
  end
end

-- The map's right-click opens the interact menu through Helper.openInteractMenu -> Helper.interactMenuCallbacks.show,
-- a reference to menu.showInteractMenu taken at registration; onShowMenu is the engine's own path and never runs here.
local function hookInteractMenu()
  local menu = findMenu("InteractMenu")
  if not menu then
    sab.Error("menu InteractMenu not found")
    return
  end
  local callbacks = Helper.interactMenuCallbacks
  local show = callbacks and callbacks.show or menu.showInteractMenu
  local function wrapped(...)
    show(...)
    local sector, offset = menu.offsetcomponent, menu.offset
    if sector and sector ~= 0 and offset and C.IsComponentClass(sector, "sector") then
      sab.lastSpot = { sector = ConvertStringTo64Bit(tostring(sector)), x = offset.x, y = offset.y, z = offset.z }
    else
      sab.lastSpot = nil
    end
  end
  menu.showInteractMenu = wrapped
  if callbacks then callbacks.show = wrapped end
end

local function hookMapMenu()
  local menu = findMenu("MapMenu")
  if not menu then
    sab.Error("menu MapMenu not found")
    return
  end
  sab.mapMenu = menu
  local onUpdate = menu.onUpdate
  menu.onUpdate = function(...)
    onUpdate(...)
    if sab.dialogDirty and menu.shown then
      sab.dialogDirty = nil
      local ok, err = pcall(sab.DisplayDialog)
      if not ok then sab.Error("dialog failed: %s", tostring(err)) end
    end
  end
  local viewCreated = menu.viewCreated
  menu.viewCreated = function(layer, ...)
    if layer == DIALOG_LAYER then
      sab.dialogTables = { ... }
      return
    end
    return viewCreated(layer, ...)
  end
  local cleanup = menu.cleanup
  menu.cleanup = function(...)
    sab.dialog, sab.dialogDirty, sab.dialogFrame, sab.dialogTables = nil, nil, nil, nil
    return cleanup(...)
  end
  local onCloseElement = menu.onCloseElement
  menu.onCloseElement = function(...)
    if sab.dialog then
      sab.CloseDialog()
      return
    end
    return onCloseElement(...)
  end
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
      if sab.planRefresh and menu.shown then
        sab.planRefresh = nil
        refreshPlanTable(true)
      end
    elseif sab.pendingTarget and menu.shown and menu.holomap ~= 0 then
      local ok, err = pcall(sab.StartPending)
      if not ok then
        sab.Error("pending start failed: %s", tostring(err))
        sab.pendingTarget = nil
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
    sab.expanded = false
    sab.target = defaultTarget()
    return cleanup(...)
  end
  local onCloseElement = menu.onCloseElement
  menu.onCloseElement = function(...)
    if sab.run then sab.StopRun("menu closed") end
    return onCloseElement(...)
  end
end

local function init()
  RegisterEvent("StationAutoBuilder.ConfigChanged", sab.ReadConfig)
  RegisterEvent("StationAutoBuilder.PlotDialog", sab.OpenPlotDialog)
  sab.ReadConfig()
  hookMenu()
  hookInteractMenu()
  hookMapMenu()
  sab.Debug("initialised")
end

-- reachable from a console eval while the panel does not exist yet
StationAutoBuilder = sab

Register_OnLoad_Init(init)
