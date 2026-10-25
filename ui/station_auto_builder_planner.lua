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

  uint32_t GetBlueprints(UIBlueprint* result, uint32_t resultlen, const char* set, const char* category, const char* macroname);
  double GetContainerWareConsumption(UniverseID containerid, const char* wareid, bool ignorestate);
  double GetContainerWareProduction(UniverseID containerid, const char* wareid, bool ignorestate);
  uint32_t GetNumBlueprints(const char* set, const char* category, const char* macroname);
  uint32_t GetNumProductionMethodResources(const char* wareid, const char* productionmethod);
  uint32_t GetNumStationModules(UniverseID stationid, bool includeconstructions, bool includewrecks);
  ProductionMethodInfo3 GetProductionMethodInfo2(const char* wareid, const char* productionmethod);
  uint32_t GetProductionMethodResources(UIWareAmount* result, uint32_t resultlen, const char* wareid, const char* productionmethod);
  uint32_t GetStationModules(UniverseID* result, uint32_t resultlen, UniverseID stationid, bool includeconstructions, bool includewrecks);
]]

local sab = StationAutoBuilder

local planner = {
  -- sizing rules
  storageHours = 4,           -- storage per ware: hours of its hourly flow
  lShare = 0.7,               -- share of the trade volume carried by L/XL ships, the rest by M
  pierDockM3PerHour = 250000, -- L/XL trade volume one pier dock serves per hour
  mDockM3PerHour = 150000,    -- M trade volume one M dock of a dock area serves per hour
  basePierDocks = 3,          -- a station without docks gets at least this, as vanilla's smallest prefabs
  baseDockAreas = 1,
  docking = { high = 1, mid = 2, low = 4 }, -- target.docking: the volume per dock scales by this
  bigPier = 3,                -- piers with more docks: one per station at most, at the bottom
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
  local scale = planner.docking[plan.target.docking or "high"] or 1
  local pierDocks = ceil(flow * planner.lShare / (planner.pierDockM3PerHour / scale))
  local areas = ceil(flow * (1 - planner.lShare) / (plan.areaDocksM * planner.mDockM3PerHour / scale))
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

-- Per-ship build resources and build hours averaged over the owned ship blueprints of a size (s, m, l, xl),
-- those of the race when it owns any (Terran hulls need other wares than Commonwealth ones); each ship by
-- the race's method, else "default", else its first.
local function shipResources(size, race)
  local macros, ofRace = blueprints("", "shiptypes_" .. size), {}
  for _, macro in ipairs(macros) do
    local races = GetMacroData(macro, "makerraceid")
    for _, r in ipairs(type(races) == "table" and races or { races }) do
      if r == race then ofRace[#ofRace + 1] = macro end
    end
  end
  if #ofRace > 0 then macros = ofRace end
  local total, ships, seconds = {}, 0, 0
  for _, macro in ipairs(macros) do
    local ware = GetMacroData(macro, "ware")
    local methods = ware and GetWareData(ware, "productionmethods")
    local method
    for _, m in ipairs(type(methods) == "table" and methods or {}) do
      if m == race or (m == "default" and method ~= race) or not method then method = m end
    end
    if method then
      local n = C.GetNumProductionMethodResources(ware, method)
      if n > 0 then
        local buf = ffi.new("UIWareAmount[?]", n)
        n = C.GetProductionMethodResources(buf, n, ware, method)
        for i = 0, tonumber(n) - 1 do
          local res = ffi.string(buf[i].wareid)
          total[res] = (total[res] or 0) + buf[i].amount
        end
        ships = ships + 1
        seconds = seconds + C.GetProductionMethodInfo2(ware, method).productiontime
      end
    end
  end
  if ships > 0 then
    for w, amount in pairs(total) do total[w] = amount / ships end
  end
  return total, ships, ships > 0 and seconds / ships / 3600 or 0
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
  if not station then return 0 end
  for _, module in ipairs(GetProductionModules(station) or {}) do
    local data = IsValidComponent(module) and GetProductionModuleData(module)
    if data and data.efficiency and data.efficiency.work then return data.efficiency.work.workforce or 0 end
  end
  return 0
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

-- *** the plan ***

-- target = { set, station, kind = "ware" | "ship", ware, rate (net ware amount per hour), modules,
--   buildMacro (the chosen wharf, shipyard or maintenance bay; the game exposes no size or kind for them),
--   shipSize, repair (no ship resource chain), count (build modules; plan.shipRate follows from them),
--   fullCycle, workforce, race, selfSufficient, sunlight }.
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
    consumed = {}, workforce = 0, workforceCapacity = 0, workforceFraction = 0, storage = {}, flow = { import = 0, export = 0 } }
  local counts = plan.counts
  local function warn(fmt, ...) plan.warnings[#plan.warnings + 1] = string.format(fmt, ...) end
  if not (ExtraData and ExtraData.Available()) then
    warn("production effects unavailable (Extra Data API): no workforce or sunlight bonus applied")
  end
  -- without planned habitats the new modules run at the station's current workforce
  local liveFraction = (not target.workforce) and liveWorkforceFraction(target.station) or 0

  -- base: wares wanted beyond the station's own use; use: what the station itself takes (ship building)
  local base, use, habWares, fixedWorkforce = {}, {}, {}, 0
  if target.kind == "ship" then
    local e = target.buildMacro and cat.byMacro[target.buildMacro]
    local bays = target.count or 1
    if not target.repair then
      -- one ship per bay at a time
      local perShip, ships, hours = shipResources(target.shipSize or "m", race)
      if ships == 0 then warn("no owned %s ship blueprint", tostring(target.shipSize)) end
      plan.shipRate = hours > 0 and bays / hours or 0
      for w, amount in pairs(perShip) do use[w] = amount * plan.shipRate end
    end
    if e then
      counts[e.macro] = bays
      fixedWorkforce = e.workforce * bays
    else
      warn("no owned build module %s", tostring(target.buildMacro))
    end
  else
    base[target.ware] = target.rate or 0
  end

  -- an existing station's surplus (built, building and planned modules alike) covers new consumption first
  local surplus = {}
  local function surplusOf(w)
    if not target.station then return 0 end
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
      ladder(candidates(cat.habitation, race), workforce, habCounts)
      for macro, n in pairs(habCounts) do capacity = capacity + cat.byMacro[macro].capacity * n end
    end
    local fraction = target.workforce and (workforce > 0 and math.min(1, capacity / workforce) or 0) or liveFraction
    -- a module count target: that many of the ware's producer at this round's fraction
    if target.modules and target.ware then
      local _, p = producerFor(cat, target.ware, race)
      base[target.ware] = p and target.modules * rateOf(p, fraction, sunlight) or 0
    end
    -- the balance of the current counts
    for w, r in pairs(use) do consumed[w] = r end
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
      local own = base[w] ~= nil or (target.fullCycle and (target.selfSufficient or not habWares[w]))
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
  local flow = plan.flow.import + plan.flow.export
  -- the new trade gets its own docks; the base only while the station has none
  local havePierDocks, haveAreas = 0, 0
  if target.station then havePierDocks, haveAreas = stationDocks(target.station) end
  local piers = candidates(cat.dock, race, function(e) return e.group == "pier" end)
  local areas = candidates(cat.dock, race, function(e) return e.group == "dock" end)
  plan.areaDocksM = math.max(1, areas[1] and areas[1].docksM or 1)
  plan.basePierDocks = havePierDocks > 0 and 0 or planner.basePierDocks
  plan.baseDockAreas = haveAreas > 0 and 0 or planner.baseDockAreas
  local need, needAreas = dockNeed(plan, flow)
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


-- The current hourly balance of a ware on an existing station, workforce use included, plus what the open
-- build menu's plan still has to build (planned entries and modules under construction) at the station's
-- live workforce fraction and sunlight; modules: the station's modules making the ware, planned ones included.
function planner.Current(station, ware)
  local production = tonumber(C.GetContainerWareProduction(station, ware, false)) or 0
  local consumption = (tonumber(C.GetContainerWareConsumption(station, ware, false)) or 0) + (Helper.getWorkforceConsumption(station, ware) or 0)
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
              fraction = liveWorkforceFraction(station)
              sunlight = GetComponentData(GetComponentData(station, "sectorid"), "sunlight") or 1
            end
            production = production + rateOf(p, fraction, sunlight)
            pending = pending + 1
          end
          if p.resources[ware] then consumption = consumption + p.resources[ware] end
        end
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
-- module (a producer of the target ware, or the build module) behind the storage, dock, pier and habitat
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
  local counts, target = plan.counts, plan.target
  local function isFinal(e)
    if target.kind == "ship" then return e.macro == target.buildMacro end
    for _, p in ipairs(e.products or {}) do if p.ware == target.ware then return true end end
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
  if target.kind == "ship" then
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

  local flow = plan.flow.import + plan.flow.export
  local turns, cum = {}, {}
  local placedWorkforce, placedHabitat, placedDocks, placedAreas, placedStorage = 0, 0, 0, 0, {}
  local finalIdx = 1
  local function emitWhile(turn, list, placed, need, each)
    while list[1] and placed < need - 1e-6 do
      local u = table.remove(list, 1)
      turn[#turn + 1] = u.macro
      placed = placed + (each or u.capacity or 1)
    end
    return placed
  end
  for t = 1, math.max(1, nFinal) do
    local turn, share = {}, t / math.max(1, nFinal)
    local producers = {}
    for _, e in ipairs(upstream) do
      while (cum[e.macro] or 0) < ceil(counts[e.macro] * share) do
        cum[e.macro] = (cum[e.macro] or 0) + 1
        producers[#producers + 1] = e
      end
    end
    local f = finals[finalIdx]
    if f then
      cum[f.macro] = (cum[f.macro] or 0) + 1
      if cum[f.macro] >= counts[f.macro] then finalIdx = finalIdx + 1 end
    end
    for _, e in ipairs(producers) do placedWorkforce = placedWorkforce + e.workforce end
    if f then placedWorkforce = placedWorkforce + f.workforce end
    -- the final module first, so it runs on imports while the rest is built; then what it trades through. A
    -- build module is the final stage: last in its turn
    local buildLast = target.kind == "ship"
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
    placedHabitat = emitWhile(turn, habitats, placedHabitat, placedWorkforce)
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
  return sab.StartBill(planner.Turns(plan), { grid = true, subdivide = target.dense and 2 or nil }), plan
end

sab.planner = planner
