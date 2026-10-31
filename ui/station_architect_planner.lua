-- Station Architect: target planner core. A target (a ware per hour, or ships of a size per hour) becomes
-- a bill of modules from the owned blueprints; no UI here. Module data is read from the game at plan time.
---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C = ffi.C

ffi.cdef [[
  typedef uint64_t UniverseID;
  typedef struct {
    const char* macro;
    const char* ware;
    const char* productionmethodid;
  } UIBlueprint;
  typedef struct {
    const char* id;
    const char* name;
    const char* tags;
    double productiontime;
    double productionamount;
  } ProductionMethodInfo3;
  typedef struct {
    const char* wareid;
    uint32_t amount;
  } UIWareAmount;
  typedef struct {
    uint32_t current;
    uint32_t capacity;
    uint32_t optimal;
    uint32_t available;
    uint32_t maxavailable;
    double timeuntilnextupdate;
  } WorkForceInfo;

  uint32_t GetBlueprints(UIBlueprint* result, uint32_t resultlen, const char* set, const char* category, const char* macroname);
  const char* GetContainerBuildMethod(UniverseID containerid);
  const char* GetPlayerBuildMethod(void);
  double GetContainerWareConsumption(UniverseID containerid, const char* wareid, bool ignorestate);
  double GetContainerWareProduction(UniverseID containerid, const char* wareid, bool ignorestate);
  uint32_t GetNumBlueprints(const char* set, const char* category, const char* macroname);
  uint32_t GetNumProductionMethodResources(const char* wareid, const char* productionmethod);
  uint32_t GetNumStationModules(UniverseID stationid, bool includeconstructions, bool includewrecks);
  ProductionMethodInfo3 GetProductionMethodInfo2(const char* wareid, const char* productionmethod);
  uint32_t GetProductionMethodResources(UIWareAmount* result, uint32_t resultlen, const char* wareid, const char* productionmethod);
  uint32_t GetStationModules(UniverseID* result, uint32_t resultlen, UniverseID stationid, bool includeconstructions, bool includewrecks);
  WorkForceInfo GetWorkForceInfo(UniverseID containerid, const char* raceid);
]]
local BLUEPRINTS, WARE_AMOUNTS, IDS = ffi.typeof("UIBlueprint[?]"), ffi.typeof("UIWareAmount[?]"), ffi.typeof("UniverseID[?]")
-- the loadout and build order types are vanilla's (menu_ship_configuration.lua)
local loadoutApi = pcall(ffi.cdef, [[
  void GenerateShipLoadout2(UILoadout2* result, UniverseID containerid, UniverseID shipid, const char* macroname, float level);
  void GenerateShipLoadoutCounts2(UILoadoutCounts2* result, UniverseID containerid, UniverseID shipid, const char* macroname, float level);
  double GetBuildDuration(UniverseID containerid, UIBuildOrderList order);
]])

local sab = StationArchitect

local planner = {
  -- sizing rules
  storageHours = 4,           -- storage per ware: hours of its hourly flow, unless the target sets its own
  shipLoadout = 0.5,          -- equipment of a planned ship: vanilla's Medium loadout preset
  lShare = 0.7,               -- share of the trade volume carried by L/XL ships, the rest by M
  pierDockM3PerHour = 250000, -- L/XL trade volume one pier dock serves per hour
  mDockM3PerHour = 150000,    -- M trade volume one M dock of a dock area serves per hour
  basePierDocks = 3,          -- a station without docks gets at least this, as vanilla's smallest prefabs
  baseDockAreas = 1,
  bigPier = 3,               -- piers with more docks: one per station at most, at the bottom
  livingStart = 0.4,          -- share of the turns done before the habitats and what only feeds them
  -- set -> catalogue of owned module blueprints
  catalogue = {},
  -- ware -> { name, transport, volume }
  wares = {},
  -- ware -> true: a product of a special (byHand) module, scrap metal
  sectionWares = {},
}

-- 9.00: GetProductionMethodInfo2; 8.00 has only GetProductionMethodInfo (vanilla-declared there), same two fields
local hasMethodInfo2 = pcall(function() return C.GetProductionMethodInfo2 end)
local function methodInfo(ware, method)
  if hasMethodInfo2 then return C.GetProductionMethodInfo2(ware, method) end
  return C.GetProductionMethodInfo(ware, method)
end

local LIBS = {
  production = "moduletypes_production",
  processing = "moduletypes_processing",
  storage = "moduletypes_storage",
  habitation = "moduletypes_habitation",
  dock = "moduletypes_dock",
  build = "moduletypes_build",
}

-- bill order
local GROUPS = { "build", "production", "processing", "habitation", "storage", "dock", "pier" }

local function ceil(x) return math.ceil(x - 1e-6) end

-- pier docks and dock areas for a trade flow, at least the plan's base
local function dockNeed(plan, flow)
  local pierDocks = ceil(flow * planner.lShare / planner.pierDockM3PerHour)
  local areas = ceil(flow * (1 - planner.lShare) / (plan.areaDocksM * planner.mDockM3PerHour))
  return math.max(plan.basePierDocks, pierDocks), math.max(plan.baseDockAreas, areas)
end

function planner.Ware(ware)
  local w = planner.wares[ware]
  if not w then
    -- processed (raw scrap): tugs hand it to a processing module's buffer, no dock and no storage
    local name, transport, volume, processed = GetWareData(ware, "name", "transport", "volume", "isprocessed")
    w = { name = name, transport = transport, volume = volume or 0, processed = processed and true or false }
    planner.wares[ware] = w
  end
  return w
end

-- *** catalogue ***

local function blueprints(set, lib)
  local macros = {}
  local n = C.GetNumBlueprints(set, lib, "")
  if n == 0 then return macros end
  local buf = ffi.new(BLUEPRINTS, n)
  n = C.GetBlueprints(buf, n, set, lib, "")
  for i = 0, tonumber(n) - 1 do macros[#macros + 1] = ffi.string(buf[i].macro) end
  return macros
end

-- The production method behind a library product: the library carries no method id, so the one whose
-- time, amount and resources match wins; a tie goes to the module's maker race, then to "default".
local function methodOf(ware, p, races)
  local wanted, n = {}, 0
  for _, r in ipairs(p.resources) do wanted[r.ware] = r.amount; n = n + 1 end
  local matches = {}
  local methods = GetWareData(ware, "productionmethods")
  if type(methods) ~= "table" then return nil end
  -- a lone method needs no match (the scrapworks library product reports a 0.4 cycle against a 60 s method)
  if #methods == 1 then return methods[1] end
  for _, m in ipairs(methods) do
    local info = methodInfo(ware, m)
    if math.abs(info.productiontime - p.cycle) < 1e-6 and math.abs(info.productionamount - p.amount) < 1e-6 then
      local count, same = tonumber(C.GetNumProductionMethodResources(ware, m)), true
      if count > 0 then
        local buf = ffi.new(WARE_AMOUNTS, count)
        count = tonumber(C.GetProductionMethodResources(buf, count, ware, m))
        for i = 0, count - 1 do
          if wanted[ffi.string(buf[i].wareid)] ~= buf[i].amount then same = false end
        end
      end
      if same and count == n then matches[#matches + 1] = m end
    end
  end
  for _, m in ipairs(matches) do if races[m] then return m end end
  for _, m in ipairs(matches) do if m == "default" then return m end end
  return matches[1]
end

-- The workforce and sunlight effects of a method from the Extra Data API; nil when that API
-- cannot answer on this build (fail closed: the plan then warns and applies no bonus).
local function effectsOf(ware, method)
  if not (method and ExtraData and ExtraData.Available()) then return nil end
  local work, sunlight = ExtraData.GetWareDataEx(ware,
    "productioneffects." .. method .. ".work", "productioneffects." .. method .. ".sunlight")
  if work == nil and sunlight == nil then return nil end
  return { work = work or 0, sunlight = sunlight or 0 }
end

-- One module as the planner sees it. Rates are per hour. The library carries no pier docks (0 for every
-- pier), so a pier's count is its docking bays from the Extra Data API.
local function entryOf(group, lib, macro)
  local data = GetLibraryEntry(lib, macro)
  local races = GetMacroData(macro, "makerraceid")
  races = type(races) == "table" and races or { races }
  local bays = lib == "moduletypes_dock" and IsMacroClass(macro, "pier") and ExtraData and ExtraData.GetMacroDataEx(macro, "dockingbays")
  local e = { macro = macro, group = group, name = data.name, race = races[1] or "generic", races = {},
    workforce = data.maxworkforce or 0, docksS = data.docks_s or 0, docksM = data.docks_m or 0,
    pierDocks = bays and #bays or 0 }
  for _, r in ipairs(races) do e.races[r] = true end
  if group == "build" then
    -- a build takes 1 + efficiency x (1 - workforce share) times its full-workforce duration
    e.efficiency = data.efficiencyfactor or 0
    -- the ship sizes the module fabricates (none for a maintenance bay); nil when the Extra Data API cannot tell
    local classes = ExtraData and ExtraData.GetMacroDataEx(macro, "builderclasses")
    if classes then
      e.builds = {}
      for _, class in ipairs(classes) do
        local size = class:match("^ship_(%a+)$")
        if size then e.builds[#e.builds + 1] = size end
      end
    end
  end
  if data.products then
    local cycle = 0
    for _, p in ipairs(data.products) do cycle = cycle + p.cycle end
    e.products = {}
    for _, p in ipairs(data.products) do
      local prod = { ware = p.ware, rate = cycle > 0 and p.amount * 3600 / cycle or 0, resources = {}, inputs = 0 }
      for _, r in ipairs(p.resources) do
        prod.resources[r.ware] = cycle > 0 and r.amount * 3600 / cycle or 0
        prod.inputs = prod.inputs + 1
      end
      prod.method = methodOf(p.ware, p, e.races)
      prod.effects = effectsOf(p.ware, prod.method)
      e.products[#e.products + 1] = prod
      -- a module fed a processed ware (scrapworks) is planned only for a goal of its own ware
      for w in pairs(prod.resources) do
        if planner.Ware(w).processed then e.byHand = true end
      end
    end
    if e.byHand then
      for _, prod in ipairs(e.products) do planner.sectionWares[prod.ware] = true end
    end
  end
  if group == "storage" then
    e.capacity = data.storagecapacity or 0
    e.tags = data.storagetags or {}
  elseif group == "habitation" then
    e.capacity = data.workforcecapacity or 0
    e.needs = {}
    local scale = (data.workforceproductamount or 0) > 0 and e.capacity / data.workforceproductamount or 0
    for _, r in ipairs(data.workforceresources or {}) do e.needs[r.ware] = r.amount * 3600 / r.cycle * scale end
  elseif group == "dock" then
    if e.pierDocks > 0 then
      e.group, e.capacity = "pier", e.pierDocks
      -- approach directions: a one-sided pier needs the least plot
      local dirs = {}
      for _, z in ipairs(ExtraData.GetMacroDataEx(macro, "exclusionzones") or {}) do
        local d = z.direction
        dirs[string.format("%.1f,%.1f,%.1f", d[1], d[2], d[3])] = true
      end
      e.approaches = 0
      for _ in pairs(dirs) do e.approaches = e.approaches + 1 end
    else
      e.capacity = e.docksM + e.docksS
    end
  end
  return e
end

function planner.Catalogue(set, refresh)
  local cat = planner.catalogue[set]
  if cat and not refresh then return cat end
  cat = { byMacro = {} }
  for _, group in ipairs({ "production", "processing", "storage", "habitation", "dock", "build" }) do
    cat[group] = {}
    for _, macro in ipairs(blueprints(set, LIBS[group])) do
      local e = entryOf(group, LIBS[group], macro)
      cat[group][#cat[group] + 1] = e
      cat.byMacro[macro] = e
    end
  end
  planner.catalogue[set] = cat
  return cat
end

-- *** picking modules ***

-- 0 the wanted race, 1 generic, 2 another race; every module 0 without a wanted race
local function tier(e, race)
  if race == nil or e.races[race] then return 0 end
  if e.race == "generic" then return 1 end
  return 2
end

-- The best producer of a ware: race tier first, then no processing (scrap) module, then the higher rate;
-- goal-only (byHand) modules only with byHand.
local function producerFor(cat, ware, race, byHand)
  local best, bestProd, bestScore
  for _, group in ipairs({ "production", "processing" }) do
    for _, e in ipairs(cat[group]) do
      for _, p in ipairs((byHand or not e.byHand) and e.products or {}) do
        if p.ware == ware and p.rate > 0 then
          local s = tier(e, race) * 10 + (group == "processing" and 5 or 0)
          if not best or s < bestScore or (s == bestScore and p.rate > bestProd.rate) then
            best, bestProd, bestScore = e, p, s
          end
        end
      end
    end
  end
  return best, bestProd
end

-- The section wares a module takes over all its products, ware -> rate; nil when it takes none (no converter).
local function sectionUse(e)
  local use
  for _, p in ipairs(e and e.products or {}) do
    for w, r in pairs(p.resources) do
      if planner.sectionWares[w] then
        use = use or {}
        use[w] = (use[w] or 0) + r
      end
    end
  end
  return use
end

-- The best converter of a ware (a module taking a section ware): race tier first, then the higher rate.
local function converterFor(cat, ware, race)
  local best, bestProd, bestScore
  for _, group in ipairs({ "production", "processing" }) do
    for _, e in ipairs(cat[group]) do
      for _, p in ipairs((not e.byHand and sectionUse(e)) and e.products or {}) do
        if p.ware == ware and p.rate > 0 then
          local s = tier(e, race)
          if not best or s < bestScore or (s == bestScore and p.rate > bestProd.rate) then
            best, bestProd, bestScore = e, p, s
          end
        end
      end
    end
  end
  return best, bestProd
end

-- The entries of the best race tier that pass the filter, largest capacity first.
local function candidates(list, race, filter)
  local byTier = { {}, {}, {} }
  for _, e in ipairs(list) do
    if (e.capacity or 0) > 0 and (not filter or filter(e)) then
      local t = byTier[tier(e, race) + 1]
      t[#t + 1] = e
    end
  end
  for _, t in ipairs(byTier) do
    if #t > 0 then
      table.sort(t, function(a, b)
        if a.capacity ~= b.capacity then return a.capacity > b.capacity end
        return a.macro < b.macro
      end)
      return t
    end
  end
  return {}
end

-- Covers need with the fewest modules: the largest while it fits, then the smallest that covers the rest.
local function ladder(cands, need, counts)
  if need <= 0 or #cands == 0 then return end
  local big = cands[1]
  local n = math.floor(need / big.capacity)
  if n > 0 then
    counts[big.macro] = (counts[big.macro] or 0) + n
    need = need - n * big.capacity
  end
  if need > 1e-6 then
    local pick = big
    for _, e in ipairs(cands) do
      if e.capacity >= need and e.capacity <= pick.capacity and e.capacity < pick.capacity + 1e-6 == (e.capacity < pick.capacity) then pick = e end
    end
    counts[pick.macro] = (counts[pick.macro] or 0) + 1
  end
end

-- Storage: one unit of the smallest class that holds the whole need, else enough of the largest.
local function storageUnits(cands, need, counts)
  if need <= 0 or #cands == 0 then return end
  for i = #cands, 1, -1 do
    if cands[i].capacity >= need - 1e-6 then
      counts[cands[i].macro] = (counts[cands[i].macro] or 0) + 1
      return
    end
  end
  counts[cands[1].macro] = (counts[cands[1].macro] or 0) + ceil(need / cands[1].capacity)
end

-- *** targets ***

-- The workforce share a container runs at; 1 when it needs none.
local function workforceFraction(container)
  if not container then return 0 end
  local w = C.GetWorkForceInfo(container, "")
  return w.optimal > 0 and math.min(1, w.current / w.optimal) or 1
end

-- The efficiency factor of a built build module of the station that fabricates the size; nil when it has none.
local function bayFor(station, size)
  local n = C.GetNumStationModules(station, false, false)
  local buf = ffi.new(IDS, n)
  n = C.GetStationModules(buf, n, station, false, false)
  for i = 0, tonumber(n) - 1 do
    local macro = GetComponentData(ConvertStringTo64Bit(tostring(buf[i])), "macro")
    if macro and IsMacroClass(macro, "buildmodule") then
      for _, class in ipairs(ExtraData and ExtraData.GetMacroDataEx(macro, "builderclasses") or {}) do
        if class == "ship_" .. size then return GetLibraryEntry(GetMacroData(macro, "infolibrary"), macro).efficiencyfactor or 0 end
      end
    end
  end
  return nil
end

-- size .. race -> { station, efficiency, fraction } of a known yard the engine reports build durations for
local yards = {}

-- A yard for the size: the station itself when it has the bay, else a known one of a faction of the race (its
-- equipment fits the race's hulls), else of any faction; the fullest workforce first.
local function yardFor(size, station, race)
  local ef = station and bayFor(station, size)
  if ef then return { station = station, efficiency = ef, fraction = workforceFraction(station) } end
  local key = size .. " " .. tostring(race)
  local y = yards[key]
  if y and IsValidComponent(y.station) then return y end
  local best
  for pass = 1, 2 do
    for _, f in ipairs(GetLibrary("factions") or {}) do
      if f.id ~= "player" and ((pass == 1) == (GetFactionData(f.id, "primaryrace") == race)) then
        for _, id in ipairs(GetContainedStationsByOwner(f.id, nil, true) or {}) do
          local s = ConvertIDTo64Bit(id)
          if GetComponentData(s, "canbuildships") then
            ef = bayFor(s, size)
            local fraction = ef and workforceFraction(s)
            if ef and (not best or fraction > best.fraction) then best = { station = s, efficiency = ef, fraction = fraction } end
            if best and best.fraction > 0.999 then break end
          end
        end
      end
      if best and best.fraction > 0.999 then break end
    end
    if best then break end
  end
  yards[key] = best
  return best
end

-- The build method a station's yard applies: its own setting, else the player's global one.
local function stationBuildMethod(station)
  local setting = station and station ~= 0 and ffi.string(C.GetContainerBuildMethod(station)) or ""
  if setting == "" then setting = ffi.string(C.GetPlayerBuildMethod()) end
  return setting
end

-- The method a yard builds a ware by: its build method when the ware has it, else "default", else the first.
local function buildMethod(ware, setting)
  local methods = ware and GetWareData(ware, "productionmethods")
  local method
  for _, m in ipairs(type(methods) == "table" and methods or {}) do
    if m == setting or (m == "default" and method ~= setting) or not method then method = m end
  end
  return method
end

-- Adds a ware's build resources to total; false when it has none.
local function addResources(total, ware, setting)
  local method = buildMethod(ware, setting)
  local n = method and C.GetNumProductionMethodResources(ware, method) or 0
  if n == 0 then return false end
  local buf = ffi.new(WARE_AMOUNTS, n)
  n = C.GetProductionMethodResources(buf, n, ware, method)
  for i = 0, tonumber(n) - 1 do
    local res = ffi.string(buf[i].wareid)
    total[res] = (total[res] or 0) + buf[i].amount
  end
  return true
end

-- macro .. yard -> { full-workforce seconds, equipment }: the engine logs each loadout it cannot fill, so each
-- is asked once
local equipped = {}

-- The ship with the yard's loadout of the planner's preset: the engine's build seconds at a full workforce and
-- the equipment macros; nil without the loadout functions.
local function equippedBuild(macro, yard)
  if not loadoutApi then return nil end
  local key = macro .. " " .. tostring(yard.station)
  local known = equipped[key]
  if known then return known[1], known[2] end
  local l2 = Helper.getLoadoutHelper2(C.GenerateShipLoadout2, C.GenerateShipLoadoutCounts2, "UILoadout2", yard.station, 0, macro, planner.shipLoadout)
  local loadout, keep, equipment = ffi.new("UILoadout"), {}, {}
  for _, f in ipairs({ { "engines", "numengines" }, { "shields", "numshields" }, { "weapons", "numweapons" }, { "turrets", "numturrets" } }) do
    local n = l2[f[2]]
    local list = ffi.new("UILoadoutMacroData[?]", n)
    keep[#keep + 1] = list
    for i = 0, n - 1 do
      local src = l2[f[1]][i]
      list[i].macro, list[i].upgradetypename, list[i].slot, list[i].optional = src.macro, src.upgradetypename, src.slot, src.optional
      equipment[#equipment + 1] = ffi.string(src.macro)
    end
    loadout[f[1]], loadout[f[2]] = list, n
  end
  local order = ffi.new("UIBuildOrderList")
  order.shipid, order.macroname, order.amount, order.loadout = 0, Helper.ffiNewString(macro), 1, loadout
  local seconds = tonumber(C.GetBuildDuration(yard.station, order)) / (1 + yard.efficiency * (1 - yard.fraction))
  equipped[key] = { seconds, equipment }
  return seconds, equipment
end

-- Per-ship build resources (hull and equipment) and build hours at a full workforce, averaged over the owned
-- ship blueprints of the sizes (s, m, l, xl), those of the race when it owns any (Terran hulls need other wares
-- than Commonwealth ones), every owned one without a race; hull and equipment by the station's build method; the
-- hours from the engine at a yard of the hull's race, else from the hull ware (fromWare).
local function shipResources(sizes, race, station)
  local total, ships, seconds, fromWare = {}, 0, 0, false
  local setting = stationBuildMethod(station)
  for _, size in ipairs(sizes) do
    local macros, ofRace, hullRace = blueprints("", "shiptypes_" .. size), {}, {}
    for _, macro in ipairs(macros) do
      local races = GetMacroData(macro, "makerraceid")
      races = type(races) == "table" and races or { races }
      hullRace[macro] = races[1]
      for _, r in ipairs(races) do
        if r == race then ofRace[#ofRace + 1], hullRace[macro] = macro, race end
      end
    end
    if #ofRace > 0 then macros = ofRace end
    for _, macro in ipairs(macros) do
      local ware, r = GetMacroData(macro, "ware"), hullRace[macro]
      if addResources(total, ware, setting) then
        ships = ships + 1
        local yard = yardFor(size, station, r)
        local built, equipment = nil, nil
        if yard then built, equipment = equippedBuild(macro, yard) end
        if built then
          seconds = seconds + built
          for _, m in ipairs(equipment or {}) do addResources(total, GetMacroData(m, "ware"), setting) end
        else
          fromWare = true
          seconds = seconds + methodInfo(ware, buildMethod(ware, setting)).productiontime
        end
      end
    end
  end
  if ships > 0 then
    for w, amount in pairs(total) do total[w] = amount / ships end
  end
  return total, ships, ships > 0 and seconds / ships / 3600 or 0, fromWare
end

-- A product's hourly rate under a workforce fraction and sunlight; the engine multiplies the two bonuses
-- (HQ energy cells: 1.7519 = (1 + 0.43 * 0.446) * (1 + 1 * 0.47)).
local function rateOf(p, fraction, sunlight)
  local fx = p.effects
  if not fx then return p.rate end
  return p.rate * (1 + fx.work * fraction) * (1 + fx.sunlight * (sunlight - 1))
end

-- The workforce fraction an existing station's producers run at (0 without a station or producers).
local function liveWorkforceFraction(station)
  if not station or #(GetProductionModules(station) or {}) == 0 then return 0 end
  return workforceFraction(station)
end

-- The station's module macros: the open build menu's plan on it (built and planned), else its modules and
-- constructions.
local function stationMacros(station)
  local macros = {}
  local menu = sab.menu
  if menu and menu.shown and menu.holomap ~= 0 and menu.container == station then
    for _, e in ipairs(sab.ReadPlan()) do macros[#macros + 1] = e.macro end
  else
    local n = C.GetNumStationModules(station, true, false)
    local buf = ffi.new(IDS, n)
    n = C.GetStationModules(buf, n, station, true, false)
    for i = 0, tonumber(n) - 1 do macros[#macros + 1] = GetComponentData(ConvertStringTo64Bit(tostring(buf[i])), "macro") end
  end
  return macros
end

-- How many modules of a macro the station has, planned ones included; 0 without a station.
function planner.ModuleCount(station, macro)
  if not station then return 0 end
  local n = 0
  for _, m in ipairs(stationMacros(station)) do
    if m == macro then n = n + 1 end
  end
  return n
end

-- The station's pier docks and trade dock areas.
local function stationDocks(station)
  local pierDocks, areas = 0, 0
  for _, macro in ipairs(stationMacros(station)) do
    if IsMacroClass(macro, "pier") then
      local bays = ExtraData and ExtraData.GetMacroDataEx(macro, "dockingbays")
      pierDocks = pierDocks + (bays and #bays or 0)
    elseif IsMacroClass(macro, "dockarea") and not GetMacroData(macro, "isventuremodule") then
      areas = areas + 1
    end
  end
  return pierDocks, areas
end

-- a station module's catalogue group and library by its class
local CLASS_GROUPS = { { "production", "production" }, { "processingmodule", "processing" }, { "habitation", "habitation" }, { "buildmodule", "build" } }
-- macro -> entry of a module whose blueprint is not owned, false for other classes
local foreign = {}

local function moduleEntry(cat, macro)
  local e = cat.byMacro[macro] or foreign[macro]
  if e ~= nil then return e or nil end
  for _, c in ipairs(CLASS_GROUPS) do
    if IsMacroClass(macro, c[1]) then
      e = entryOf(c[2], LIBS[c[2]], macro)
      break
    end
  end
  foreign[macro] = e or false
  return e
end

-- An existing station's modules, planned ones included: producers per ware, the wares its producers and
-- habitats use, workforce need and housing, habitats per race, build and special modules per macro.
local function stationProfile(station, set)
  local cat = planner.Catalogue(set or "")
  local p = { makes = {}, uses = {}, habWares = {}, need = 0, capacity = 0, races = {}, builds = {}, special = {} }
  for _, macro in ipairs(stationMacros(station)) do
    local e = moduleEntry(cat, macro)
    if e and e.group == "habitation" then
      p.capacity = p.capacity + e.capacity
      p.races[e.race] = (p.races[e.race] or 0) + 1
      for w in pairs(e.needs) do p.habWares[w] = true end
    elseif e then
      p.need = p.need + e.workforce
      if e.group == "build" then p.builds[macro] = (p.builds[macro] or 0) + 1 end
      if e.byHand then p.special[macro] = (p.special[macro] or 0) + 1 end
      for _, prod in ipairs(e.products or {}) do
        p.makes[prod.ware] = (p.makes[prod.ware] or 0) + 1
        for w in pairs(prod.resources) do p.uses[w] = true end
      end
    end
  end
  return p
end

-- The target an existing station looks built for: its build modules as ship goals, else its end products (made,
-- used by none of its producers, a whole module of net output at least, not made by special modules or by
-- converters alone) as ware goals, each at what the station has; its special modules as the section.
-- Full cycle: it makes every resource it could (one at least); self-sufficient: its habitats' wares too.
-- The workforce race is its habitats' (nil without any); the module race stays any.
function planner.Derive(station, set)
  local cat = planner.Catalogue(set or "")
  local p = stationProfile(station, set)
  local race, most = nil, 0
  for r, n in pairs(p.races) do
    if n > most or (n == most and r < race) then race, most = r, n end
  end
  local d = { goals = {}, special = {}, workforce = p.capacity > 0, race = race }
  for macro, n in pairs(p.special) do d.special[#d.special + 1] = { macro = macro, count = n } end
  table.sort(d.special, function(a, b) return a.macro < b.macro end)
  local builds = {}
  for macro in pairs(p.builds) do builds[#builds + 1] = macro end
  table.sort(builds)
  for _, macro in ipairs(builds) do d.goals[#d.goals + 1] = { kind = "ship", buildMacro = macro, bays = p.builds[macro] } end
  if #builds == 0 then
    local wares = {}
    for w in pairs(p.makes) do
      if not p.uses[w] and not (planner.sectionWares[w] and not producerFor(cat, w, nil)) then wares[#wares + 1] = w end
    end
    table.sort(wares)
    for _, w in ipairs(wares) do
      local c = planner.Current(station, w)
      if c.modules > 0 and c.production > 0 and c.extra >= 1 - 1e-6 then d.goals[#d.goals + 1] = { kind = "ware", ware = w, modules = math.floor(c.extra + 1e-6) } end
    end
  end
  local function covered(list)
    local any = false
    for w in pairs(list) do
      if p.makes[w] then
        any = true
      elseif producerFor(cat, w, nil) then
        return false
      end
    end
    return any
  end
  d.fullCycle = covered(p.uses)
  d.selfSufficient = d.fullCycle and d.workforce and covered(p.habWares)
  return d
end

-- An existing station's shortfalls the target makes its own: wares it makes, under full cycle its resources and,
-- self-sufficient, its habitats' wares (nominal rates; goal wares count in their goal; wares no owned module
-- makes stay imported); with workforce the housing its producers lack.
local function stationLacks(target)
  local lack = { wares = {}, workforce = 0, any = false }
  if not target.station then return lack end
  local cat = planner.Catalogue(target.set or "")
  local p = stationProfile(target.station, target.set)
  local wares = {}
  for w in pairs(p.makes) do wares[w] = true end
  if target.fullCycle then
    for w in pairs(p.uses) do wares[w] = true end
    if target.selfSufficient then
      for w in pairs(p.habWares) do wares[w] = true end
    end
  end
  for _, g in ipairs(target.goals or {}) do
    if g.ware then wares[g.ware] = nil end
  end
  for w in pairs(wares) do
    local net = producerFor(cat, w, nil) and planner.Current(target.station, w).net or 0
    if net < -0.5 then
      lack.wares[w], lack.any = -net, true
    end
  end
  if target.workforce and p.need > p.capacity then lack.workforce, lack.any = p.need - p.capacity, true end
  return lack
end

-- The station's trade volume per hour after the plan: each ware's net now plus the plan's own (shortfall fillers
-- replace imports, so the shortfall counts once).
local function tradeAfter(station, plan, lack)
  local p = stationProfile(station, plan.set)
  local wares = {}
  for _, list in ipairs({ p.makes, p.uses, p.habWares, plan.produced, plan.consumed }) do
    for w in pairs(list) do wares[w] = true end
  end
  local flow = 0
  for w in pairs(wares) do
    if not planner.Ware(w).processed then
      local net = planner.Current(station, w).net + (plan.produced[w] or 0) - (plan.consumed[w] or 0) + (lack.wares[w] or 0)
      flow = flow + math.abs(net) * planner.Ware(w).volume
    end
  end
  return flow
end

-- *** the plan ***

-- The target's goals; a target without a goals list is one goal itself.
local function goalsOf(target)
  return target.goals or { target }
end

-- The race with the most owned habitats in cat; a tie goes to the lower race id.
function planner.WorkforceRace(cat)
  local counts, best = {}, nil
  for _, e in ipairs(cat.habitation) do counts[e.race] = (counts[e.race] or 0) + 1 end
  for race, n in pairs(counts) do
    if not best or n > counts[best] or (n == counts[best] and race < best) then best = race end
  end
  return best
end

-- target = { set, station, goals, fullCycle, workforce, race, moduleRace, selfSufficient, sunlight, storageHours },
--   each goal { kind = "ware", ware, rate (net ware amount per hour) or modules } or { kind = "ship", buildMacro,
--   count (build modules to add), bays (the station's total after the plan, supplied as a whole) }. race: the
--   workforce's (habitats and the producers of what they eat), WorkforceRace when nil; moduleRace: preferred for every
--   other module and the ship hulls, any when nil. A fabrication bay builds the ship sizes its builder classes
--   name (shipSize overrides), a maintenance bay none (repair forces that); plan.shipRates and plan.shipHours
--   per goal index. special = { { macro, count (special modules to add) } }: the section, modules fed a
--   processed ware (scrapworks); under full cycle their output and the station's surplus of it feed converters
--   of the goal wares (goal by goal up to the goal, the rest to the first goal's converter, the last converter
--   part-time) and the goals' own producers make only the rest; else that output is sold.
--   A goal ware another goal consumes gets its producers on top of that consumption. A station's shortfalls
--   (stationLacks) are planned too, with or without a goal.
--   The result carries counts per macro, the ware balance, the workforce and the warnings; Bill() turns it
--   into StartBill's list.
function planner.Plan(target)
  local set = target.set or "factory"
  local cat = planner.Catalogue(set, true)
  local race, moduleRace = target.race or planner.WorkforceRace(cat), target.moduleRace
  local sunlight = target.sunlight
  if not sunlight and target.station then
    sunlight = GetComponentData(GetComponentData(target.station, "sectorid"), "sunlight")
  end
  sunlight = sunlight or 1
  local plan = { target = target, set = set, sunlight = sunlight, counts = {}, warnings = {}, produced = {},
    consumed = {}, workforce = 0, workforceCapacity = 0, workforceFraction = 0, storage = {}, flow = { import = 0, export = 0 },
    shipRates = {}, shipHours = {}, adds = false }
  local counts = plan.counts
  local function warn(fmt, ...) plan.warnings[#plan.warnings + 1] = string.format(fmt, ...) end
  if not (ExtraData and ExtraData.Available()) then
    warn("production effects unavailable (Extra Data API): no workforce or sunlight bonus applied")
  end
  -- without planned habitats the new modules run at the station's current workforce
  local liveFraction = (not target.workforce) and liveWorkforceFraction(target.station) or 0

  -- baseRate: wares wanted beyond the station's own use; modules: module count goals per ware; use: what
  -- the station itself takes (ship building)
  local baseRate, moduleGoals, use, habWares, fixedWorkforce = {}, {}, {}, {}, 0
  ---@type table<string, any[]>
  local bySizes = {}
  for i, goal in ipairs(goalsOf(target)) do
    if goal.kind == "ship" then
      local e = goal.buildMacro and cat.byMacro[goal.buildMacro]
      local bays = goal.count or 1
      -- the supply serves every bay, the station's own included
      local supplied = math.max(bays, goal.bays or bays)
      if bays > 0 or (target.fullCycle and supplied > 0) then plan.adds = true end
      local sizes = goal.repair and {} or (goal.shipSize and { goal.shipSize }) or (e and e.builds)
      if e and not sizes then warn("build module kind unknown (Extra Data API): %s planned without ships", e.name) end
      if sizes and #sizes > 0 then
        -- one ship per bay at a time
        local id = table.concat(sizes, " ")
        bySizes[id] = bySizes[id] or { shipResources(sizes, moduleRace, target.station) }
        local perShip, ships, hours, fromWare = bySizes[id][1], bySizes[id][2], bySizes[id][3], bySizes[id][4]
        if ships == 0 then warn("no owned %s ship blueprint", id) end
        if fromWare then warn("no known %s yard: ship build times from the hull wares", id) end
        -- planned habitats staff the bays, else they run at the station's workforce now
        if e then hours = hours * (1 + e.efficiency * (1 - (target.workforce and 1 or workforceFraction(target.station)))) end
        local shipRate = hours > 0 and supplied / hours or 0
        plan.shipRates[i], plan.shipHours[i] = shipRate, hours
        for w, amount in pairs(perShip) do use[w] = (use[w] or 0) + amount * shipRate end
      end
      if e then
        if bays > 0 then counts[e.macro] = (counts[e.macro] or 0) + bays end
        fixedWorkforce = fixedWorkforce + e.workforce * bays
      else
        warn("no owned build module %s", tostring(goal.buildMacro))
      end
    elseif goal.ware then
      if goal.modules then
        moduleGoals[goal.ware] = (moduleGoals[goal.ware] or 0) + goal.modules
        baseRate[goal.ware] = baseRate[goal.ware] or 0
        if goal.modules > 0 then plan.adds = true end
      else
        baseRate[goal.ware] = (baseRate[goal.ware] or 0) + (goal.rate or 0)
        if (goal.rate or 0) > 0 then plan.adds = true end
      end
    end
  end
  local special = {}
  for _, s in ipairs(target.special or {}) do
    local e = cat.byMacro[s.macro]
    if not e then
      warn("no owned module %s", tostring(s.macro))
    elseif (s.count or 0) > 0 then
      special[e.macro] = (special[e.macro] or 0) + s.count
      plan.adds = true
    end
  end
  local lack = stationLacks(target)
  plan.lacks, plan.use = lack, use
  -- a new station has nothing to trade through: its docks lead every turn; an upgrade's close them
  plan.newStation = not target.station or #stationMacros(target.station) == 0
  if lack.any then plan.adds = true end
  -- no goal, every goal met and no shortfall: nothing to plan, not even the base docks
  if not plan.adds then return plan end
  local base = {}

  -- an existing station's surplus (built, building and planned modules alike) covers new consumption first;
  -- a goal ware's surplus is the goal's own
  local surplus = {}
  local function surplusOf(w)
    if not target.station or baseRate[w] then return 0 end
    if surplus[w] == nil then surplus[w] = math.max(0, planner.Current(target.station, w).net) end
    return surplus[w]
  end
  plan.surplus = surplus

  -- a self-sufficient plan makes what the station's and the planned habitats eat with the workforce race's producers
  local fed = target.station and stationProfile(target.station, set).habWares or {}
  local function raceFor(w) return (target.selfSufficient and (fed[w] or habWares[w])) and race or moduleRace end

  -- fixedCounts: the special modules and their converters, whole modules
  local prodCounts, habCounts, fixedCounts = {}, {}, {}
  for macro, n in pairs(special) do fixedCounts[macro] = n end
  local missing = {}
  for _ = 1, 50 do
    -- the workforce of the current counts, the habitats that house it, the fraction they cover
    local produced, consumed, workforce, capacity = {}, {}, fixedWorkforce, 0
    for macro, n in pairs(prodCounts) do workforce = workforce + cat.byMacro[macro].workforce * n end
    for macro, n in pairs(fixedCounts) do workforce = workforce + cat.byMacro[macro].workforce * n end
    habCounts = {}
    if target.workforce then
      ladder(candidates(cat.habitation, race), workforce + lack.workforce, habCounts)
      for macro, n in pairs(habCounts) do capacity = capacity + cat.byMacro[macro].capacity * n end
      capacity = math.max(0, capacity - lack.workforce)
    end
    local fraction = target.workforce and (workforce > 0 and math.min(1, capacity / workforce) or 0) or liveFraction
    -- a module count goal: that many of the ware's producer at this round's fraction
    base = {}
    for w, r in pairs(baseRate) do base[w] = r end
    for w, n in pairs(moduleGoals) do
      local _, p = producerFor(cat, w, raceFor(w), true)
      base[w] = base[w] + (p and n * rateOf(p, fraction, sunlight) or 0)
    end
    -- module shares of the special modules and their converters; a part-time converter by the share it gets
    local shares = {}
    for macro, n in pairs(special) do shares[macro] = n end
    if target.fullCycle then
      local left, credit, first = {}, {}, nil
      for macro, n in pairs(special) do
        for _, p in ipairs(cat.byMacro[macro].products) do left[p.ware] = (left[p.ware] or 0) + rateOf(p, fraction, sunlight) * n end
      end
      for w in pairs(planner.sectionWares) do left[w] = (left[w] or 0) + surplusOf(w) end
      local function feed(e, share)
        local takes = sectionUse(e) or {}
        for w, r in pairs(takes) do share = math.min(share, (left[w] or 0) / r) end
        if share <= 1e-6 or share == math.huge then return end
        for w, r in pairs(takes) do left[w] = left[w] - r * share end
        shares[e.macro] = (shares[e.macro] or 0) + share
        for _, p in ipairs(e.products) do credit[p.ware] = (credit[p.ware] or 0) + rateOf(p, fraction, sunlight) * share end
      end
      for _, goal in ipairs(goalsOf(target)) do
        local w = goal.kind == "ware" and goal.ware
        local e, p = nil, nil
        if w then e, p = converterFor(cat, w, raceFor(w)) end
        if e then
          first = first or e
          feed(e, math.max(0, (base[w] or 0) - (credit[w] or 0)) / rateOf(p, fraction, sunlight))
        end
      end
      if first then feed(first, math.huge) end
    end
    -- what they make, which the station's own producers then need not
    local fixed = {}
    for macro, share in pairs(shares) do
      for _, p in ipairs(cat.byMacro[macro].products) do
        local r = rateOf(p, fraction, sunlight) * share
        produced[p.ware] = (produced[p.ware] or 0) + r
        fixed[p.ware] = (fixed[p.ware] or 0) + r
        for w, c in pairs(p.resources) do consumed[w] = (consumed[w] or 0) + c * share end
      end
    end
    -- the balance of the current counts
    for w, r in pairs(use) do consumed[w] = (consumed[w] or 0) + r end
    for w, r in pairs(lack.wares) do consumed[w] = (consumed[w] or 0) + r end
    for macro, n in pairs(prodCounts) do
      for _, p in ipairs(cat.byMacro[macro].products) do
        produced[p.ware] = (produced[p.ware] or 0) + rateOf(p, fraction, sunlight) * n
        for w, r in pairs(p.resources) do consumed[w] = (consumed[w] or 0) + r * n end
      end
    end
    for macro, n in pairs(habCounts) do
      for w, r in pairs(cat.byMacro[macro].needs) do
        consumed[w] = (consumed[w] or 0) + r * n
        habWares[w] = true
      end
    end
    -- what the station produces itself
    local demand = {}
    for w, r in pairs(base) do demand[w] = r end
    for w, r in pairs(consumed) do
      local own = base[w] ~= nil or lack.wares[w] ~= nil or (target.fullCycle and (target.selfSufficient or not habWares[w]))
      if own then demand[w] = (demand[w] or 0) + math.max(0, r - surplusOf(w)) end
    end
    for w, r in pairs(fixed) do
      if demand[w] then demand[w] = demand[w] - r end
    end
    local next = {}
    for w, r in pairs(demand) do
      -- goal-only modules serve their goal ware alone, never a shortfall or a full cycle
      local e, p = producerFor(cat, w, raceFor(w), base[w] ~= nil)
      if r <= 0 then
        -- covered by the station's surplus
      elseif e then
        next[e.macro] = (next[e.macro] or 0) + ceil(r / rateOf(p, fraction, sunlight))
      elseif not missing[w] and not planner.Ware(w).processed then
        missing[w] = true
        if producerFor(cat, w, nil, true) then
          warn("%s is made only by special resource modules: imported", planner.Ware(w).name)
        else
          warn("no owned module produces %s: imported", planner.Ware(w).name)
        end
      end
    end
    local nextFixed = {}
    for macro, share in pairs(shares) do nextFixed[macro] = ceil(share) end
    local same = true
    for _, pair in ipairs({ { next, prodCounts }, { nextFixed, fixedCounts } }) do
      for macro, n in pairs(pair[1]) do if pair[2][macro] ~= n then same = false end end
      for macro in pairs(pair[2]) do if not pair[1][macro] then same = false end end
    end
    prodCounts, fixedCounts = next, nextFixed
    plan.produced, plan.consumed, plan.workforce, plan.workforceFraction = produced, consumed, workforce, fraction
    if same then break end
  end
  for _, list in ipairs({ prodCounts, fixedCounts }) do
    for macro, n in pairs(list) do counts[macro] = (counts[macro] or 0) + n end
  end
  for macro, n in pairs(habCounts) do
    counts[macro] = n
    plan.workforceCapacity = plan.workforceCapacity + cat.byMacro[macro].capacity * n
  end

  -- the wares the planned and the station's habitats eat, for the turns
  plan.habWares = {}
  for _, list in ipairs({ habWares, fed }) do
    for w in pairs(list) do plan.habWares[w] = true end
  end

  -- storage per ware and per transport type, docks and piers from the trade volume
  local m3 = {}
  plan.wareStorage = {}
  for w in pairs(base) do plan.consumed[w] = plan.consumed[w] or 0 end
  for w, r in pairs(plan.produced) do plan.consumed[w] = plan.consumed[w] or 0; plan.produced[w] = r end
  for w, c in pairs(plan.consumed) do
    local p = plan.produced[w] or 0
    local ware = planner.Ware(w)
    if not ware.processed then
      plan.wareStorage[w] = (target.storageHours or planner.storageHours) * math.max(p, c) * ware.volume
      m3[ware.transport] = (m3[ware.transport] or 0) + plan.wareStorage[w]
      local net = p - c
      if net > 0 then plan.flow.export = plan.flow.export + net * ware.volume end
      if net < 0 then plan.flow.import = plan.flow.import - net * ware.volume end
    end
  end
  plan.storage = m3
  for transport, volume in pairs(m3) do
    local cands = candidates(cat.storage, moduleRace, function(e) return e.tags[transport] end)
    if #cands > 0 then storageUnits(cands, volume, counts) else warn("no owned %s storage", tostring(transport)) end
  end
  -- docks for the station's whole trade after the plan, less those it has; the base only while it has none
  local flow = plan.flow.import + plan.flow.export
  local havePierDocks, haveAreas = 0, 0
  if target.station then
    havePierDocks, haveAreas = stationDocks(target.station)
    flow = tradeAfter(target.station, plan, lack)
  end
  plan.tradeAfter = flow
  local piers = candidates(cat.dock, moduleRace, function(e) return e.group == "pier" end)
  local areas = candidates(cat.dock, moduleRace, function(e) return e.group == "dock" end)
  plan.areaDocksM = math.max(1, areas[1] and areas[1].docksM or 1)
  plan.basePierDocks = havePierDocks > 0 and 0 or planner.basePierDocks
  plan.baseDockAreas = haveAreas > 0 and 0 or planner.baseDockAreas
  local need, needAreas = dockNeed(plan, flow)
  need, needAreas = math.max(0, need - havePierDocks), math.max(0, needAreas - haveAreas)
  if need > 0 and #piers == 0 then
    warn("no owned pier")
  elseif need > 0 then
    -- whole piers of one size, the largest up to bigPier docks, so an upgrade adds more of the same
    local pick
    for _, e in ipairs(piers) do
      local better = not pick or e.capacity > pick.capacity or (e.capacity == pick.capacity and e.approaches < pick.approaches)
      if e.capacity <= planner.bigPier and better then pick = e end
    end
    pick = pick or piers[#piers]
    counts[pick.macro] = (counts[pick.macro] or 0) + ceil(need / pick.capacity)
  end
  if needAreas > 0 and #areas == 0 then
    warn("no owned dock area")
  elseif needAreas > 0 then
    counts[areas[1].macro] = (counts[areas[1].macro] or 0) + needAreas
  end
  return plan
end

-- macro -> { ware = true } of a production or processing module, owned blueprint or not
local productsCache = {}

local function makes(cat, macro, ware)
  local wares = productsCache[macro]
  if not wares then
    wares = {}
    local entry = cat.byMacro[macro]
    local lib = (IsMacroClass(macro, "production") and LIBS.production) or (IsMacroClass(macro, "processingmodule") and LIBS.processing)
    local products = entry and entry.products or (lib and GetLibraryEntry(lib, macro).products) or {}
    for _, p in ipairs(products) do wares[p.ware] = true end
    productsCache[macro] = wares
  end
  return wares[ware] == true
end

-- A built processing module's nominal balance of a ware: the engine's container production and consumption
-- leave processing modules out (no workforce or sunlight effect on them).
local function processingBalance(cat, macro, ware)
  if not IsMacroClass(macro, "processingmodule") then return 0, 0 end
  local entry = moduleEntry(cat, macro)
  local prod, cons = 0, 0
  for _, p in ipairs(entry and entry.products or {}) do
    if p.ware == ware then prod = prod + p.rate end
    cons = cons + (p.resources[ware] or 0)
  end
  return prod, cons
end

-- The current hourly balance of a ware on an existing station at nominal rates (a waiting module counts),
-- workforce use included, plus what the open build menu's plan still has to build (planned entries and modules
-- under construction): producers at the workforce fraction the whole plan's habitats house and the sunlight,
-- habitats full; built processing modules at their nominal rates; modules: the station's modules making the ware,
-- planned ones included, converters not; converted: the converters' share of production; extra: the net in
-- modules of the regular producers' output (in the best producer's nominal rate when only converters make it).
function planner.Current(station, ware)
  local production = tonumber(C.GetContainerWareProduction(station, ware, true)) or 0
  local consumption = (tonumber(C.GetContainerWareConsumption(station, ware, true)) or 0) + (Helper.getWorkforceConsumption(station, ware) or 0)
  local pending, modules, converted = 0, 0, 0
  local menu = sab.menu
  local inMenu = menu and menu.shown and menu.holomap ~= 0 and menu.container == station
  local cat = planner.Catalogue(inMenu and menu.set or "")
  local fraction, sunlight
  local function rateNow(p)
    if not fraction then
      local profile = stationProfile(station, inMenu and menu.set or nil)
      fraction = math.max(liveWorkforceFraction(station), profile.need > 0 and math.min(1, profile.capacity / profile.need) or 0)
      sunlight = GetComponentData(GetComponentData(station, "sectorid"), "sunlight") or 1
    end
    return rateOf(p, fraction, sunlight)
  end
  -- a module making the ware: a converter's output apart (built: nominal, as the engine's), else one more
  -- regular producer
  local function count(macro, built)
    if not makes(cat, macro, ware) then return end
    local entry = moduleEntry(cat, macro)
    if sectionUse(entry) then
      for _, p in ipairs(entry and entry.products or {}) do
        if p.ware ~= ware then
          -- another product
        elseif built then
          converted = converted + p.rate
        else
          converted = converted + rateNow(p)
        end
      end
    else
      modules = modules + 1
    end
  end
  if inMenu then
    for _, e in ipairs(sab.ReadPlan()) do
      local planned = e.component == 0 or IsComponentConstruction(e.component)
      count(e.macro, not planned)
      if planned then
        local entry = cat.byMacro[e.macro]
        for _, p in ipairs(entry and entry.products or {}) do
          if p.ware == ware then
            production = production + rateNow(p)
            pending = pending + 1
          end
          if p.resources[ware] then consumption = consumption + p.resources[ware] end
        end
        if entry and entry.needs and entry.needs[ware] then consumption = consumption + entry.needs[ware] end
      else
        local prod, cons = processingBalance(cat, e.macro, ware)
        production, consumption = production + prod, consumption + cons
      end
    end
  else
    for _, module in ipairs(GetProductionModules(station) or {}) do count(GetComponentData(module, "macro"), true) end
    local n = C.GetNumStationModules(station, false, false)
    local buf = ffi.new(IDS, n)
    n = C.GetStationModules(buf, n, station, false, false)
    for i = 0, tonumber(n) - 1 do
      local macro = GetComponentData(ConvertStringTo64Bit(tostring(buf[i])), "macro")
      local prod, cons = processingBalance(cat, macro, ware)
      production, consumption = production + prod, consumption + cons
      if prod > 0 then modules = modules + 1 end
    end
  end
  local net, regular = production - consumption, production - converted
  local extra = modules
  if modules > 0 and regular > 0 then
    extra = net * modules / regular
  elseif modules == 0 and converted > 0 then
    local _, p = producerFor(cat, ware, nil)
    extra = p and net / p.rate or 0
  end
  return { production = production, consumption = consumption, net = net, pending = pending, modules = modules, converted = converted, extra = extra }
end

-- The plan as StartBill takes it, grouped: build, production, processing, habitation, storage, dock areas, piers.
function planner.Bill(plan)
  local cat = planner.Catalogue(plan.set)
  local bill = {}
  for _, group in ipairs(GROUPS) do
    local macros = {}
    for macro in pairs(plan.counts) do
      if (cat.byMacro[macro] or {}).group == group then macros[#macros + 1] = macro end
    end
    table.sort(macros)
    for _, macro in ipairs(macros) do bill[#bill + 1] = { macro = macro, count = plan.counts[macro] } end
  end
  return bill
end

-- *** turns ***
-- The bill in build order, bottom up, so the station works from its first turn on and each turn adds output:
-- a new station's turn 1 opens with a pier and a dock area (an upgrade trades through its own); turn t of N opens
-- with the storage of the imports, the upstream producers t final modules need, deepest first, each level's storage
-- behind it, and ends with one final module (a producer of the target ware, or the build module; without one
-- a producer of a shortfall ware, or a habitat for a workforce shortfall), its storage and the piers and dock
-- areas the trade of t turns needs beyond those standing. The living part
-- (habitats, the producers only they or other living producers take, the imports only those take, and the
-- modules of no chain) starts after livingStart of the turns and spreads evenly over the rest. Storage is due
-- from a ware's first producer on (an import's from the start), its units placed while what stands is below
-- the due share.

local function unitsOf(cat, counts, group)
  local list = {}
  for macro in pairs(counts) do
    local e = cat.byMacro[macro]
    if e and e.group == group then list[#list + 1] = e end
  end
  table.sort(list, function(a, b)
    if (a.capacity or 0) ~= (b.capacity or 0) then return (a.capacity or 0) > (b.capacity or 0) end
    return a.name < b.name
  end)
  local out = {}
  for _, e in ipairs(list) do
    for _ = 1, counts[e.macro] do out[#out + 1] = e end
  end
  return out
end

function planner.Turns(plan)
  local cat = planner.Catalogue(plan.set)
  local counts = plan.counts
  if not next(counts) then return {} end
  local goalWares, goalBuilds = {}, {}
  for _, goal in ipairs(goalsOf(plan.target)) do
    if goal.kind == "ship" then
      if goal.buildMacro then goalBuilds[goal.buildMacro] = true end
    elseif goal.ware then
      goalWares[goal.ware] = true
    end
  end
  local function isFinal(e)
    if goalBuilds[e.macro] then return true end
    for _, p in ipairs(e.products or {}) do if goalWares[p.ware] then return true end end
    return false
  end
  local finals, upstream, others = {}, {}, {}
  for macro in pairs(counts) do
    local e = cat.byMacro[macro]
    if not e then
      others[#others + 1] = { macro = macro, name = macro }
    elseif e.group == "production" or e.group == "processing" or e.group == "build" then
      if isFinal(e) then finals[#finals + 1] = e else upstream[#upstream + 1] = e end
    elseif e.group ~= "habitation" and e.group ~= "storage" and e.group ~= "dock" and e.group ~= "pier" then
      others[#others + 1] = e
    end
  end
  -- no goal module planned: the producers of shortfall wares no other planned module takes are the finals
  local lacks = plan.lacks or { wares = {}, workforce = 0 }
  if #finals == 0 then
    local takers = {}
    for _, e in ipairs(upstream) do
      for _, p in ipairs(e.products or {}) do
        for w in pairs(p.resources) do
          takers[w] = takers[w] or {}
          takers[w][e.macro] = true
        end
      end
    end
    local rest = {}
    for _, e in ipairs(upstream) do
      local final = false
      for _, p in ipairs(e.products or {}) do
        local taken = false
        for m in pairs(takers[p.ware] or {}) do if m ~= e.macro then taken = true end end
        if lacks.wares[p.ware] and not taken then final = true end
      end
      if final then finals[#finals + 1] = e else rest[#rest + 1] = e end
    end
    upstream = rest
  end
  table.sort(finals, function(a, b) return a.name < b.name end)
  table.sort(others, function(a, b) return a.name < b.name end)
  local nFinal = 0
  for _, e in ipairs(finals) do nFinal = nFinal + counts[e.macro] end
  -- level: 0 for a final producer, else 1 + the highest level among the producers consuming its products
  local level, consumers = {}, {}
  for _, e in ipairs(finals) do level[e.macro] = 0 end
  for _, list in ipairs({ finals, upstream }) do
    for _, e in ipairs(list) do
      for _, p in ipairs(e.products or {}) do
        for w in pairs(p.resources) do
          consumers[w] = consumers[w] or {}
          consumers[w][#consumers[w] + 1] = e.macro
        end
      end
    end
  end
  for _ = 1, #upstream + 1 do
    local changed = false
    for _, e in ipairs(upstream) do
      local lv = 1
      for _, p in ipairs(e.products or {}) do
        for _, m in ipairs(consumers[p.ware] or {}) do
          if m ~= e.macro and level[m] and level[m] + 1 > lv then lv = level[m] + 1 end
        end
      end
      if level[e.macro] ~= lv then
        level[e.macro] = lv
        changed = true
      end
    end
    if not changed then break end
  end
  -- deepest first: what feeds the chain stands before what it feeds, the final module's direct inputs last
  table.sort(upstream, function(a, b)
    if level[a.macro] ~= level[b.macro] then return level[a.macro] > level[b.macro] end
    return a.name < b.name
  end)
  -- the living part: a ware only the habitats or living producers take (never a goal, a shortfall the
  -- habitats do not eat, or a ship build's use); a producer is living when every product of it is
  local habWares, use, producerOf, living = plan.habWares or {}, plan.use or {}, {}, {}
  for _, list in ipairs({ finals, upstream }) do
    for _, e in ipairs(list) do
      for _, p in ipairs(e.products or {}) do producerOf[p.ware] = true end
    end
  end
  local function livingWare(w, self)
    if nFinal == 0 or goalWares[w] or use[w] or (lacks.wares[w] and not habWares[w]) then return false end
    local taken = false
    for _, m in ipairs(consumers[w] or {}) do
      if m ~= self then
        if not living[m] then return false end
        taken = true
      end
    end
    return taken or habWares[w] or false
  end
  for _ = 1, #upstream + 1 do
    local changed = false
    for _, e in ipairs(upstream) do
      if not living[e.macro] and e.products and #e.products > 0 then
        local all = true
        for _, p in ipairs(e.products) do
          if not livingWare(p.ware, e.macro) then all = false end
        end
        if all then living[e.macro], changed = true, true end
      end
    end
    if not changed then break end
  end
  local main, supporters = {}, {}
  for _, e in ipairs(upstream) do
    if living[e.macro] then supporters[#supporters + 1] = e else main[#main + 1] = e end
  end
  local imports = {}
  for w in pairs(plan.wareStorage or {}) do
    if not producerOf[w] then imports[#imports + 1] = w end
  end
  table.sort(imports)
  -- the unit lists, largest first; a storage unit goes to the first transport type it serves
  local habitats, piers, areas = unitsOf(cat, counts, "habitation"), unitsOf(cat, counts, "pier"), unitsOf(cat, counts, "dock")
  local transports, storages = {}, {}
  for transport in pairs(plan.storage) do transports[#transports + 1] = transport end
  table.sort(transports)
  for _, u in ipairs(unitsOf(cat, counts, "storage")) do
    for _, transport in ipairs(transports) do
      if u.tags[transport] then
        storages[transport] = storages[transport] or {}
        table.insert(storages[transport], u)
        break
      end
    end
  end

  -- no final at all: one turn per habitat the missing workforce needs
  local nTurns = math.max(1, nFinal > 0 and nFinal or (lacks.workforce > 0 and #habitats or 1))
  -- the living part from the turn after livingStart of the turns; without a final module it is the plan itself
  local firstLiving = nFinal > 0 and math.min(nTurns, ceil(planner.livingStart * nTurns) + 1) or 1
  local flow = plan.flow.import + plan.flow.export
  local turns, cum = {}, {}
  local placedHabitat, placedDocks, placedAreas, placedStorage = 0, 0, 0, {}
  -- storage due per transport type, the living part's apart
  local due, dueLiving, counted = {}, {}, {}
  local function addDue(w, isLiving)
    local need = plan.wareStorage and plan.wareStorage[w]
    if counted[w] or not need then return end
    counted[w] = true
    local list = isLiving and dueLiving or due
    local transport = planner.Ware(w).transport
    list[transport] = (list[transport] or 0) + need
  end
  -- the final macro furthest behind its count, so every goal grows in step
  local function nextFinal()
    local pick, behind
    for _, e in ipairs(finals) do
      local done = (cum[e.macro] or 0) / counts[e.macro]
      if done < 1 and (not pick or done < behind) then pick, behind = e, done end
    end
    return pick
  end
  local function emitWhile(turn, list, placed, need, each)
    while list[1] and placed < need - 1e-6 do
      local u = table.remove(list, 1)
      turn[#turn + 1] = u.macro
      placed = placed + (each or u.capacity or 1)
    end
    return placed
  end
  for t = 1, nTurns do
    local turn, share = {}, t / nTurns
    local livingShare = t >= firstLiving and (t - firstLiving + 1) / (nTurns - firstLiving + 1) or 0
    local function emitStorage()
      for _, transport in ipairs(transports) do
        local need = (due[transport] or 0) * share + (dueLiving[transport] or 0) * livingShare
        placedStorage[transport] = emitWhile(turn, storages[transport] or {}, placedStorage[transport] or 0, need)
      end
    end
    local function emitProducer(e)
      turn[#turn + 1] = e.macro
      for _, p in ipairs(e.products or {}) do addDue(p.ware, living[e.macro]) end
    end
    -- the units due by the share, level by level, each level's storage behind it
    local function emitLevels(list, s)
      local i = 1
      while list[i] do
        local lv = level[list[i].macro]
        while list[i] and level[list[i].macro] == lv do
          local e = list[i]
          while (cum[e.macro] or 0) < ceil(counts[e.macro] * s) do
            cum[e.macro] = (cum[e.macro] or 0) + 1
            emitProducer(e)
          end
          i = i + 1
        end
        emitStorage()
      end
    end
    local function emitDocks()
      local needDocks, needAreas = dockNeed(plan, flow * share)
      placedDocks = emitWhile(turn, piers, placedDocks, math.max(1, needDocks))
      placedAreas = emitWhile(turn, areas, placedAreas, math.max(1, needAreas), 1)
    end
    -- a new station starts from a pier and a dock area
    if t == 1 and plan.newStation ~= false then
      placedDocks = emitWhile(turn, piers, placedDocks, 1)
      placedAreas = emitWhile(turn, areas, placedAreas, 1, 1)
    end
    for _, w in ipairs(imports) do
      local isLiving = livingWare(w)
      if not isLiving or livingShare > 0 then addDue(w, isLiving) end
    end
    emitStorage()
    emitLevels(main, share)
    if t == firstLiving then
      for _, e in ipairs(others) do
        for _ = 1, counts[e.macro] do turn[#turn + 1] = e.macro end
      end
    end
    if nFinal == 0 then
      placedHabitat = emitWhile(turn, habitats, placedHabitat, t, 1)
    elseif livingShare > 0 then
      emitLevels(supporters, livingShare)
      placedHabitat = emitWhile(turn, habitats, placedHabitat, ((plan.workforce or 0) + lacks.workforce) * livingShare)
    end
    -- the last turn: what rounding left over, before its final module
    if t == nTurns then
      for _, u in ipairs(habitats) do turn[#turn + 1] = u.macro end
      for _, list in ipairs({ main, supporters }) do
        for _, e in ipairs(list) do
          for _ = (cum[e.macro] or 0) + 1, counts[e.macro] do emitProducer(e) end
        end
      end
    end
    local f = nextFinal()
    if f then
      cum[f.macro] = (cum[f.macro] or 0) + 1
      emitProducer(f)
      emitStorage()
    end
    -- the docks the trade of t turns needs close the turn, the last turn's leftovers with them
    emitDocks()
    if t == nTurns then
      for _, list in ipairs({ piers, areas }) do
        for _, u in ipairs(list) do turn[#turn + 1] = u.macro end
      end
    end
    turns[t] = turn
  end
  -- the last turn ends with the final modules and the storage still unplaced
  local last = turns[#turns]
  for _, e in ipairs(finals) do
    for _ = (cum[e.macro] or 0) + 1, counts[e.macro] do last[#last + 1] = e.macro end
  end
  for _, transport in ipairs(transports) do
    for _, u in ipairs(storages[transport] or {}) do last[#last + 1] = u.macro end
  end

  local bill = {}
  for t, turn in ipairs(turns) do
    for _, macro in ipairs(turn) do
      local prev = bill[#bill]
      if prev and prev.turn == t and prev.macro == macro then
        prev.count = prev.count + 1
      else
        local e = cat.byMacro[macro]
        bill[#bill + 1] = { macro = macro, count = 1, turn = t, group = e and e.group or "other" }
      end
    end
  end
  return bill
end

-- A readable plan for the log and for eval.
function planner.Print(plan)
  local cat = planner.Catalogue(plan.set)
  local lines = {}
  for _, b in ipairs(planner.Bill(plan)) do
    local e = cat.byMacro[b.macro]
    lines[#lines + 1] = string.format("%3d x %-32s %s (%s)", b.count, e.name, e.group, b.macro)
  end
  local turnLines = {}
  for _, b in ipairs(planner.Turns(plan)) do
    local e = cat.byMacro[b.macro]
    turnLines[b.turn] = (turnLines[b.turn] and turnLines[b.turn] .. ", " or "") .. string.format("%d x %s", b.count, e and e.name or b.macro)
  end
  for t, text in ipairs(turnLines) do lines[#lines + 1] = string.format("    turn %d: %s", t, text) end
  local wares = {}
  for w in pairs(plan.consumed) do wares[#wares + 1] = w end
  table.sort(wares)
  for _, w in ipairs(wares) do
    local p, c = plan.produced[w] or 0, plan.consumed[w]
    lines[#lines + 1] = string.format("    %-24s +%7d -%7d = %+7d /h", planner.Ware(w).name, p, c, p - c)
  end
  lines[#lines + 1] = string.format("    workforce %d (capacity %d, fraction %.2f), sunlight %.2f, trade in %d m3/h, out %d m3/h",
    plan.workforce, plan.workforceCapacity, plan.workforceFraction, plan.sunlight, plan.flow.import, plan.flow.export)
  for w, s in pairs(plan.surplus or {}) do
    if s > 0 then lines[#lines + 1] = string.format("    station surplus used: %-18s %7d /h", planner.Ware(w).name, s) end
  end
  for _, w in ipairs(plan.warnings) do lines[#lines + 1] = "    ! " .. w end
  return table.concat(lines, "\n")
end

-- Plan and start the run in one go, for eval and the Target tab.
function planner.Run(target)
  local plan = planner.Plan(target)
  sab.Debug("planned:\n%s", planner.Print(plan))
  -- every goal is met already
  if not plan.adds then return nil, plan end
  return sab.StartBill(planner.Turns(plan), { grid = true, moduleRace = target.moduleRace }), plan
end

sab.planner = planner
