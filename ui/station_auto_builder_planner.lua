-- Station Auto Builder: target planner core. A target (a ware per hour, or ships of a size per hour) becomes
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
-- the loadout and build order types are vanilla's (menu_ship_configuration.lua)
local loadoutApi = pcall(ffi.cdef, [[
  void GenerateShipLoadout2(UILoadout2* result, UniverseID containerid, UniverseID shipid, const char* macroname, float level);
  void GenerateShipLoadoutCounts2(UILoadoutCounts2* result, UniverseID containerid, UniverseID shipid, const char* macroname, float level);
  double GetBuildDuration(UniverseID containerid, UIBuildOrderList order);
]])

local sab = StationAutoBuilder

local planner = {
  -- sizing rules
  storageHours = 4,           -- storage per ware: hours of its hourly flow
  shipLoadout = 0.5,          -- equipment of a planned ship: vanilla's Medium loadout preset
  lShare = 0.7,               -- share of the trade volume carried by L/XL ships, the rest by M
  pierDockM3PerHour = 250000, -- L/XL trade volume one pier dock serves per hour
  mDockM3PerHour = 150000,    -- M trade volume one M dock of a dock area serves per hour
  basePierDocks = 3,          -- a station without docks gets at least this, as vanilla's smallest prefabs
  baseDockAreas = 1,
  bigPier = 3,               -- piers with more docks: one per station at most, at the bottom
  -- set -> catalogue of owned module blueprints
  catalogue = {},
  -- ware -> { name, transport, volume }
  wares = {},
}

local LIBS = {
  production = "moduletypes_production",
  processing = "moduletypes_processing",
  storage = "moduletypes_storage",
  habitation = "moduletypes_habitation",
  dock = "moduletypes_dock",
  build = "moduletypes_build",
}

-- bill order
local GROUPS = { "build", "production", "habitation", "storage", "dock", "pier" }

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
    local name, transport, volume = GetWareData(ware, "name", "transport", "volume")
    w = { name = name, transport = transport, volume = volume or 0 }
    planner.wares[ware] = w
  end
  return w
end

-- *** catalogue ***

local function blueprints(set, lib)
  local macros = {}
  local n = C.GetNumBlueprints(set, lib, "")
  if n == 0 then return macros end
  local buf = ffi.new("UIBlueprint[?]", n)
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
    local info = C.GetProductionMethodInfo2(ware, m)
    if math.abs(info.productiontime - p.cycle) < 1e-6 and math.abs(info.productionamount - p.amount) < 1e-6 then
      local count, same = tonumber(C.GetNumProductionMethodResources(ware, m)), true
      if count > 0 then
        local buf = ffi.new("UIWareAmount[?]", count)
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

-- 0 the wanted race, 1 generic, 2 another race
local function tier(e, race)
  if e.races[race] then return 0 end
  if e.race == "generic" then return 1 end
  return 2
end

-- The best producer of a ware: race tier first, then no processing (scrap) module, then the higher rate.
local function producerFor(cat, ware, race)
  local best, bestProd, bestScore
  for _, group in ipairs({ "production", "processing" }) do
    for _, e in ipairs(cat[group]) do
      for _, p in ipairs(e.products or {}) do
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
  local buf = ffi.new("UniverseID[?]", n)
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

-- The method a ware is made by for the race: the race's, else "default", else its first.
local function raceMethod(ware, race)
  local methods = ware and GetWareData(ware, "productionmethods")
  local method
  for _, m in ipairs(type(methods) == "table" and methods or {}) do
    if m == race or (m == "default" and method ~= race) or not method then method = m end
  end
  return method
end

-- Adds a ware's production resources to total; false when it has none.
local function addResources(total, ware, race)
  local method = raceMethod(ware, race)
  local n = method and C.GetNumProductionMethodResources(ware, method) or 0
  if n == 0 then return false end
  local buf = ffi.new("UIWareAmount[?]", n)
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
-- than Commonwealth ones); the hours from the engine at a yard of the size, else from the hull ware (fromWare).
local function shipResources(sizes, race, station)
  local total, ships, seconds, fromWare = {}, 0, 0, false
  for _, size in ipairs(sizes) do
    local macros, ofRace = blueprints("", "shiptypes_" .. size), {}
    for _, macro in ipairs(macros) do
      local races = GetMacroData(macro, "makerraceid")
      for _, r in ipairs(type(races) == "table" and races or { races }) do
        if r == race then ofRace[#ofRace + 1] = macro end
      end
    end
    if #ofRace > 0 then macros = ofRace end
    local yard = yardFor(size, station, race)
    for _, macro in ipairs(macros) do
      local ware = GetMacroData(macro, "ware")
      if addResources(total, ware, race) then
        ships = ships + 1
        local built, equipment = nil, nil
        if yard then built, equipment = equippedBuild(macro, yard) end
        if built then
          seconds = seconds + built
          for _, m in ipairs(equipment or {}) do addResources(total, GetMacroData(m, "ware"), race) end
        else
          fromWare = true
          seconds = seconds + C.GetProductionMethodInfo2(ware, raceMethod(ware, race)).productiontime
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
    local buf = ffi.new("UniverseID[?]", n)
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
-- habitats use, workforce need and housing, habitats per race, other modules per maker race, build modules per macro.
local function stationProfile(station, set)
  local cat = planner.Catalogue(set or "")
  local p = { makes = {}, uses = {}, habWares = {}, need = 0, capacity = 0, races = {}, moduleRaces = {}, builds = {} }
  for _, macro in ipairs(stationMacros(station)) do
    local e = moduleEntry(cat, macro)
    if e and e.group == "habitation" then
      p.capacity = p.capacity + e.capacity
      p.races[e.race] = (p.races[e.race] or 0) + 1
      for w in pairs(e.needs) do p.habWares[w] = true end
    elseif e then
      p.need = p.need + e.workforce
      for r in pairs(e.races) do p.moduleRaces[r] = (p.moduleRaces[r] or 0) + 1 end
      if e.group == "build" then p.builds[macro] = (p.builds[macro] or 0) + 1 end
      for _, prod in ipairs(e.products or {}) do
        p.makes[prod.ware] = (p.makes[prod.ware] or 0) + 1
        for w in pairs(prod.resources) do p.uses[w] = true end
      end
    end
  end
  return p
end

-- The target an existing station looks built for: its build modules as ship goals, else its end products (made,
-- used by none of its producers, a whole module of net output at least) as ware goals, each at what the station
-- has. Full cycle: it makes every resource it could (one at least); self-sufficient: its habitats' wares too.
function planner.Derive(station, set)
  local cat = planner.Catalogue(set or "")
  local p = stationProfile(station, set)
  local function mostOf(counts)
    local best, most = nil, 0
    for r, n in pairs(counts) do
      if n > most or (n == most and r < best) then best, most = r, n end
    end
    return best
  end
  -- without habitats: the race most of its modules are made by, else the sector owner's
  local race = mostOf(p.races) or mostOf(p.moduleRaces)
  if not race then
    local owner = GetComponentData(GetComponentData(station, "sectorid"), "owner")
    local primary = owner and GetFactionData(owner, "primaryrace")
    race = primary ~= "" and primary or nil
  end
  local d = { goals = {}, workforce = p.capacity > 0, race = race }
  local builds = {}
  for macro in pairs(p.builds) do builds[#builds + 1] = macro end
  table.sort(builds)
  for _, macro in ipairs(builds) do d.goals[#d.goals + 1] = { kind = "ship", buildMacro = macro, bays = p.builds[macro] } end
  if #builds == 0 then
    local wares = {}
    for w in pairs(p.makes) do
      if not p.uses[w] then wares[#wares + 1] = w end
    end
    table.sort(wares)
    for _, w in ipairs(wares) do
      local c = planner.Current(station, w)
      local extra = c.production > 0 and c.net * c.modules / c.production or 0
      if extra >= 1 - 1e-6 then d.goals[#d.goals + 1] = { kind = "ware", ware = w, modules = math.floor(extra + 1e-6) } end
    end
  end
  local function covered(list)
    local any = false
    for w in pairs(list) do
      if p.makes[w] then
        any = true
      elseif producerFor(cat, w, race or "generic") then
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
    local net = producerFor(cat, w, target.race or "generic") and planner.Current(target.station, w).net or 0
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
    local net = planner.Current(station, w).net + (plan.produced[w] or 0) - (plan.consumed[w] or 0) + (lack.wares[w] or 0)
    flow = flow + math.abs(net) * planner.Ware(w).volume
  end
  return flow
end

-- *** the plan ***

-- The target's goals; a target without a goals list is one goal itself.
local function goalsOf(target)
  return target.goals or { target }
end

-- target = { set, station, goals, fullCycle, workforce, race, selfSufficient, sunlight }, each goal
--   { kind = "ware", ware, rate (net ware amount per hour) or modules } or { kind = "ship", buildMacro, count
--   (build modules to add), bays (the station's total after the plan, supplied as a whole) }. A fabrication bay builds the ship sizes its builder classes name (shipSize
--   overrides), a maintenance bay none (repair forces that); plan.shipRates and plan.shipHours per goal index.
--   A goal ware another goal consumes gets its producers on top of that consumption. A station's shortfalls
--   (stationLacks) are planned too, with or without a goal.
--   The result carries counts per macro, the ware balance, the workforce and the warnings; Bill() turns it
--   into StartBill's list.
function planner.Plan(target)
  local set = target.set or "factory"
  local cat = planner.Catalogue(set, true)
  local race = target.race or "generic"
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
        bySizes[id] = bySizes[id] or { shipResources(sizes, race, target.station) }
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
  local lack = stationLacks(target)
  plan.lacks = lack
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

  local prodCounts, habCounts = {}, {}
  local missing = {}
  for _ = 1, 50 do
    -- the workforce of the current counts, the habitats that house it, the fraction they cover
    local produced, consumed, workforce, capacity = {}, {}, fixedWorkforce, 0
    for macro, n in pairs(prodCounts) do workforce = workforce + cat.byMacro[macro].workforce * n end
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
      local _, p = producerFor(cat, w, race)
      base[w] = base[w] + (p and n * rateOf(p, fraction, sunlight) or 0)
    end
    -- the balance of the current counts
    for w, r in pairs(use) do consumed[w] = r end
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
    local next = {}
    for w, r in pairs(demand) do
      local e, p = producerFor(cat, w, race)
      if r <= 0 then
        -- covered by the station's surplus
      elseif e then
        next[e.macro] = (next[e.macro] or 0) + ceil(r / rateOf(p, fraction, sunlight))
      elseif not missing[w] then
        missing[w] = true
        warn("no owned module produces %s: imported", planner.Ware(w).name)
      end
    end
    local same = true
    for macro, n in pairs(next) do if prodCounts[macro] ~= n then same = false end end
    for macro in pairs(prodCounts) do if not next[macro] then same = false end end
    prodCounts = next
    plan.produced, plan.consumed, plan.workforce, plan.workforceFraction = produced, consumed, workforce, fraction
    if same then break end
  end
  for macro, n in pairs(prodCounts) do counts[macro] = n end
  for macro, n in pairs(habCounts) do
    counts[macro] = n
    plan.workforceCapacity = plan.workforceCapacity + cat.byMacro[macro].capacity * n
  end

  -- storage per transport type, docks and piers from the trade volume
  local m3 = {}
  for w in pairs(base) do plan.consumed[w] = plan.consumed[w] or 0 end
  for w, r in pairs(plan.produced) do plan.consumed[w] = plan.consumed[w] or 0; plan.produced[w] = r end
  for w, c in pairs(plan.consumed) do
    local p = plan.produced[w] or 0
    local ware = planner.Ware(w)
    m3[ware.transport] = (m3[ware.transport] or 0) + planner.storageHours * math.max(p, c) * ware.volume
    local net = p - c
    if net > 0 then plan.flow.export = plan.flow.export + net * ware.volume end
    if net < 0 then plan.flow.import = plan.flow.import - net * ware.volume end
  end
  plan.storage = m3
  for transport, volume in pairs(m3) do
    local cands = candidates(cat.storage, race, function(e) return e.tags[transport] end)
    if #cands > 0 then ladder(cands, volume, counts) else warn("no owned %s storage", tostring(transport)) end
  end
  -- docks for the station's whole trade after the plan, less those it has; the base only while it has none
  local flow = plan.flow.import + plan.flow.export
  local havePierDocks, haveAreas = 0, 0
  if target.station then
    havePierDocks, haveAreas = stationDocks(target.station)
    flow = tradeAfter(target.station, plan, lack)
  end
  plan.tradeAfter = flow
  local piers = candidates(cat.dock, race, function(e) return e.group == "pier" end)
  local areas = candidates(cat.dock, race, function(e) return e.group == "dock" end)
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


-- The current hourly balance of a ware on an existing station at nominal rates (a waiting module counts),
-- workforce use included, plus what the open build menu's plan still has to build (planned entries and modules
-- under construction): producers at the workforce fraction the whole plan's habitats house and the sunlight,
-- habitats full; modules: the station's modules making the ware, planned ones included.
function planner.Current(station, ware)
  local production = tonumber(C.GetContainerWareProduction(station, ware, true)) or 0
  local consumption = (tonumber(C.GetContainerWareConsumption(station, ware, true)) or 0) + (Helper.getWorkforceConsumption(station, ware) or 0)
  local pending, modules = 0, 0
  local menu = sab.menu
  if menu and menu.shown and menu.holomap ~= 0 and menu.container == station then
    local cat = planner.Catalogue(menu.set or "")
    local fraction, sunlight
    for _, e in ipairs(sab.ReadPlan()) do
      if makes(cat, e.macro, ware) then modules = modules + 1 end
      if e.component == 0 or IsComponentConstruction(e.component) then
        local entry = cat.byMacro[e.macro]
        for _, p in ipairs(entry and entry.products or {}) do
          if p.ware == ware then
            if not fraction then
              local profile = stationProfile(station, menu.set)
              fraction = math.max(liveWorkforceFraction(station), profile.need > 0 and math.min(1, profile.capacity / profile.need) or 0)
              sunlight = GetComponentData(GetComponentData(station, "sectorid"), "sunlight") or 1
            end
            production = production + rateOf(p, fraction, sunlight)
            pending = pending + 1
          end
          if p.resources[ware] then consumption = consumption + p.resources[ware] end
        end
        if entry and entry.needs and entry.needs[ware] then consumption = consumption + entry.needs[ware] end
      end
    end
  else
    local cat = planner.Catalogue("")
    for _, module in ipairs(GetProductionModules(station) or {}) do
      if makes(cat, GetComponentData(module, "macro"), ware) then modules = modules + 1 end
    end
  end
  return { production = production, consumption = consumption, net = production - consumption, pending = pending, modules = modules }
end

-- The plan as StartBill takes it, grouped: build, production, habitation, storage, dock areas, piers.
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
-- The bill in build order, so the station works from its first final module on: turn t adds one final
-- module (a producer of the target ware, or the build module; without one a producer of a shortfall ware, or
-- a habitat for a workforce shortfall) behind the storage, dock, pier and habitat
-- units the need of t turns exceeds (largest units first, one big unit serves several turns) and the
-- upstream producers t final modules need, deepest first.

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
  local goalWares, goalBuilds, ships = {}, {}, false
  for _, goal in ipairs(goalsOf(plan.target)) do
    if goal.kind == "ship" then
      if goal.buildMacro then goalBuilds[goal.buildMacro] = true end
      ships = true
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
    elseif e.group == "production" or e.group == "build" then
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
  -- a producer nothing in the chain consumes (food, medical for the habitats) goes after the chain
  local deepest, inChain = 0, {}
  for _, e in ipairs(upstream) do
    for _, p in ipairs(e.products or {}) do
      for _, m in ipairs(consumers[p.ware] or {}) do if m ~= e.macro then inChain[e.macro] = true end end
    end
    if inChain[e.macro] and level[e.macro] > deepest then deepest = level[e.macro] end
  end
  for _, e in ipairs(upstream) do
    if not inChain[e.macro] then level[e.macro] = deepest + 1 end
  end
  -- shallow first: a final module's direct inputs come before their own inputs, imports fill the gap meanwhile
  table.sort(upstream, function(a, b)
    if level[a.macro] ~= level[b.macro] then return level[a.macro] < level[b.macro] end
    return a.name < b.name
  end)
  -- the transport types of what a final module makes and takes: its storage comes right after it
  local finalTransports = {}
  for _, e in ipairs(finals) do
    for _, p in ipairs(e.products or {}) do
      finalTransports[planner.Ware(p.ware).transport] = true
      for w in pairs(p.resources) do finalTransports[planner.Ware(w).transport] = true end
    end
  end
  if ships then
    for w in pairs(plan.consumed) do finalTransports[planner.Ware(w).transport] = true end
  end
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
  local flow = plan.flow.import + plan.flow.export
  local turns, cum = {}, {}
  local placedWorkforce, placedHabitat, placedDocks, placedAreas, placedStorage = 0, 0, 0, 0, {}
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
    local producers = {}
    for _, e in ipairs(upstream) do
      while (cum[e.macro] or 0) < ceil(counts[e.macro] * share) do
        cum[e.macro] = (cum[e.macro] or 0) + 1
        producers[#producers + 1] = e
      end
    end
    local f = nextFinal()
    if f then cum[f.macro] = (cum[f.macro] or 0) + 1 end
    for _, e in ipairs(producers) do placedWorkforce = placedWorkforce + e.workforce end
    if f then placedWorkforce = placedWorkforce + f.workforce end
    -- the final module first, so it runs on imports while the rest is built; then what it trades through. A
    -- build module is the final stage: last in its turn
    local buildLast = f and f.group == "build"
    if f and not buildLast then turn[#turn + 1] = f.macro end
    local function emitStorage(ofFinal)
      for _, transport in ipairs(transports) do
        if (finalTransports[transport] or false) == ofFinal then
          placedStorage[transport] = emitWhile(turn, storages[transport] or {}, placedStorage[transport] or 0, (plan.storage[transport] or 0) * share)
        end
      end
    end
    emitStorage(true)
    local needDocks, needAreas = dockNeed(plan, flow * share)
    placedAreas = emitWhile(turn, areas, placedAreas, math.max(1, needAreas), 1)
    placedDocks = emitWhile(turn, piers, placedDocks, math.max(1, needDocks))
    if t == 1 then
      for _, e in ipairs(others) do
        for _ = 1, counts[e.macro] do turn[#turn + 1] = e.macro end
      end
    end
    for _, e in ipairs(producers) do turn[#turn + 1] = e.macro end
    emitStorage(false)
    if nFinal > 0 then
      placedHabitat = emitWhile(turn, habitats, placedHabitat, placedWorkforce + lacks.workforce * share)
    else
      placedHabitat = emitWhile(turn, habitats, placedHabitat, t, 1)
    end
    if f and buildLast then turn[#turn + 1] = f.macro end
    turns[t] = turn
  end
  -- whatever rounding left over goes with the last turn
  local last = turns[#turns]
  for _, list in ipairs({ habitats, piers, areas }) do
    for _, u in ipairs(list) do last[#last + 1] = u.macro end
  end
  for _, transport in ipairs(transports) do
    for _, u in ipairs(storages[transport] or {}) do last[#last + 1] = u.macro end
  end
  for _, e in ipairs(upstream) do
    for _ = (cum[e.macro] or 0) + 1, counts[e.macro] do last[#last + 1] = e.macro end
  end
  for _, e in ipairs(finals) do
    for _ = (cum[e.macro] or 0) + 1, counts[e.macro] do last[#last + 1] = e.macro end
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
  return sab.StartBill(planner.Turns(plan), { grid = true, subdivide = target.dense and 2 or nil }), plan
end

sab.planner = planner
