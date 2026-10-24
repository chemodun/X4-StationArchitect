-- Station Auto Builder: dense grid layout. Crosses joined arm to arm make a grid of cells; every module is a
-- block of cells in one of its poses (any connection on any cross arm, four rolls), packed into one footprint
-- floor by floor; crosses form the shortest tree to every module, a module's free connection carries a cross or
-- another module directly; straight runs of bare crosses become struts. Sizes, connections and lengths come
-- from the game at run time.
---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C = ffi.C

local sab = StationAutoBuilder
local grid = {}
sab.grid = grid

local yield = coroutine.yield

local DIRS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
local OPPOSITE = { 2, 1, 4, 3, 6, 5 }
local ROLLS = { 0, math.pi / 2, math.pi, 3 * math.pi / 2 }
local CHECKS_PER_FRAME = 150000
grid.checksPerFrame = CHECKS_PER_FRAME
-- new crosses a module may need to reach the tree
local MAX_PATH = 4
-- footprint estimate: grid cells per module cell
local FILL = 1.6
-- a box may reach this share of a cell past a cell face
local EPS = 0.05
local W_TOP, W_COST, W_CONTACT, W_CENTRE = 1000, 40, 6, 1
-- one pack per new-cross cost, the best is kept: the greedy packer is not monotonic in this weight
---@type number[]
grid.costs = { 40, 150, 300, 1000 }

-- Score weights from eval, for layout experiments: { top, cost, contact, centre }, nil keeps a weight; a cost
-- packs that cost only, costs = { ... } sets the list.
function grid.SetWeights(w)
  W_TOP, W_CONTACT, W_CENTRE = w.top or W_TOP, w.contact or W_CONTACT, w.centre or W_CENTRE
  if w.cost then grid.costs = { w.cost } end
  if w.costs then grid.costs = w.costs end
  return { top = W_TOP, costs = grid.costs, contact = W_CONTACT, centre = W_CENTRE }
end

local function dirIndex(v)
  for i, d in ipairs(DIRS) do
    if v[1] * d[1] + v[2] * d[2] + v[3] * d[3] > 0.99 then return i end
  end
  return nil
end

-- Every pose of a macro on a cross at the origin: the cells it fills and its other connections that end on a
-- cross position of the grid (a port carries a cross or a module there).
local function poses(g, macro)
  local geo, list = sab.geo, {}
  local conns, size = sab.macroConns[macro], sab.sizes[macro]
  if not (conns and size) then return list end
  local u, a, eps = g.u, g.a, EPS * g.u
  for _, c in ipairs(conns) do
    for di, d in ipairs(DIRS) do
      for _, roll in ipairs(ROLLS) do
        local pose = sab.PoseForWorld({ a * d[1], a * d[2], a * d[3] }, d, c, roll)
        local p = { pose.pos.x, pose.pos.y, pose.pos.z }
        local box = geo.worldBox(size, p, pose.rows)
        local lo, hi = {}, {}
        for i = 1, 3 do
          lo[i] = math.floor((box.min[i] + eps) / u + 0.5)
          hi[i] = math.floor((box.max[i] - eps) / u + 0.5)
        end
        if not (lo[1] <= 0 and hi[1] >= 0 and lo[2] <= 0 and hi[2] >= 0 and lo[3] <= 0 and hi[3] >= 0) then
          local cells = {}
          for x = lo[1], hi[1] do
            for y = lo[2], hi[2] do
              for z = lo[3], hi[3] do cells[#cells + 1] = { x, y, z } end
            end
          end
          local ports = {}
          for _, c2 in ipairs(conns) do
            if c2.name ~= c.name then
              local q, dq = geo.rotate(c2.pos, pose.rows), geo.unit(geo.rotate(c2.dir, pose.rows))
              local pdi = dirIndex(dq)
              local n, aligned = {}, pdi ~= nil
              for i = 1, 3 do
                local w = p[i] + q[i] + a * dq[i]
                n[i] = math.floor(w / u + 0.5)
                if math.abs(w - n[i] * u) > 1 then aligned = false end
              end
              if aligned then ports[#ports + 1] = { name = c2.name, node = n, di = pdi } end
            end
          end
          local sx, sy, sz = hi[1] - lo[1] + 1, hi[2] - lo[2] + 1, hi[3] - lo[3] + 1
          -- top and outer faces bound the score before any cell is checked
          list[#list + 1] = { conn = c.name, di = di, roll = roll, cells = cells, ports = ports, span = { sx, sy, sz },
            lo = lo, hi = hi, top = hi[2], faces = 2 * (sx * sy + sy * sz + sx * sz) }
        end
      end
    end
  end
  return list
end

local function key(g, x, y, z) return (y * g.s + z) * g.s + x end

local function free(g, x, y, z)
  return x >= 0 and x < g.s and z >= 0 and z < g.s and y >= 0 and g.occ[key(g, x, y, z)] == nil
end

---@async
local function work(g, n)
  g.work = g.work + n
  if g.work > grid.checksPerFrame then
    g.work = 0
    g.frames = (g.frames or 0) + 1
    yield()
  end
end

local function addCross(g, node, parent)
  local k = key(g, node[1], node[2], node[3])
  local X = { node = node, key = k, arms = {}, parent = parent, modules = 0 }
  g.crosses[k] = X
  g.occ[k] = X
  if node[2] > g.top then g.top = node[2] end
  return X
end

-- Steps to the tree from every free cell within reach: crosses (through a free arm) and free ports are the sources.
---@async
local function distances(g, ylo, yhi)
  local dist, from, queue, head = {}, {}, {}, 1
  local function push(x, y, z, d, ref)
    if y < ylo or y > yhi or not free(g, x, y, z) then return end
    local k = key(g, x, y, z)
    if dist[k] then return end
    dist[k], from[k] = d, ref
    queue[#queue + 1] = { x, y, z, d }
  end
  for _, X in pairs(g.crosses) do
    local n = X.node
    if n[2] >= ylo - 1 and n[2] <= yhi + 1 then
      for di, d in ipairs(DIRS) do
        if not X.arms[di] then push(n[1] + d[1], n[2] + d[2], n[3] + d[3], 1, { kind = "cross", cross = X, di = di }) end
      end
    end
  end
  for _, M in ipairs(g.modules) do
    for _, pt in ipairs(M.ports) do
      if not pt.used then push(pt.node[1], pt.node[2], pt.node[3], 1, { kind = "port", module = M, port = pt }) end
    end
  end
  while queue[head] do
    local q = queue[head]
    head = head + 1
    if q[4] < g.maxPath then
      for di, d in ipairs(DIRS) do
        local x, y, z = q[1] + d[1], q[2] + d[2], q[3] + d[3]
        if y >= ylo and y <= yhi and free(g, x, y, z) and not dist[key(g, x, y, z)] then
          push(x, y, z, q[4] + 1, { kind = "new", node = { q[1], q[2], q[3] }, di = di })
        end
      end
    end
    work(g, 6)
  end
  return dist, from
end

-- The cells of a new path from node back to the tree, nearest the node first.
local function pathOf(g, from, node)
  local cells, n = {}, node
  while true do
    local k = key(g, n[1], n[2], n[3])
    cells[#cells + 1] = { n, from[k] }
    local ref = from[k]
    if ref.kind ~= "new" then return cells end
    n = ref.node
  end
end

-- Running sums of occupied cells, so any box of cells is counted in eight lookups; rebuilt after each commit.
local function rebuildSums(g)
  local w, h, occ = g.s + 1, g.top + g.tallest + 2, g.occ
  local S = {}
  for j = 0, h do
    for k = 0, g.s do
      for i = 0, g.s do
        local v = 0
        if i > 0 and j > 0 and k > 0 then
          v = (occ[key(g, i - 1, j - 1, k - 1)] and 1 or 0)
              + S[(j * w + k) * w + i - 1] + S[((j - 1) * w + k) * w + i] + S[(j * w + k - 1) * w + i]
              - S[((j - 1) * w + k) * w + i - 1] - S[(j * w + k - 1) * w + i - 1] - S[((j - 1) * w + k - 1) * w + i]
              + S[((j - 1) * w + k - 1) * w + i - 1]
        end
        S[(j * w + k) * w + i] = v
      end
    end
  end
  g.sums, g.sumH = S, h
end

-- Occupied cells in the box x0..x1, y0..y1, z0..z1 (inside the footprint, y0 >= 0).
local function boxSum(g, x0, x1, y0, y1, z0, z1)
  if y1 >= g.sumH then y1 = g.sumH - 1 end
  if y0 > y1 then return 0 end
  local S, w = g.sums, g.s + 1
  local i1, j1, k1 = x1 + 1, y1 + 1, z1 + 1
  return S[(j1 * w + k1) * w + i1] - S[(j1 * w + k1) * w + x0] - S[(y0 * w + k1) * w + i1] - S[(j1 * w + z0) * w + i1]
      + S[(y0 * w + k1) * w + x0] + S[(j1 * w + z0) * w + x0] + S[(y0 * w + z0) * w + i1] - S[(y0 * w + z0) * w + x0]
end

-- A pose's cells are a box: free test and contacts (occupied or off-grid neighbours) from the running sums.
---@async
local function evaluate(g, node, pose, cost, path)
  work(g, 10)
  local x0, x1 = node[1] + pose.lo[1], node[1] + pose.hi[1]
  local y0, y1 = node[2] + pose.lo[2], node[2] + pose.hi[2]
  local z0, z1 = node[3] + pose.lo[3], node[3] + pose.hi[3]
  local s = g.s
  if x0 < 0 or z0 < 0 or y0 < 0 or x1 >= s or z1 >= s then return nil end
  if boxSum(g, x0, x1, y0, y1, z0, z1) > 0 then return nil end
  for _, step in ipairs(path or {}) do
    local n = step[1]
    if n[1] >= x0 and n[1] <= x1 and n[2] >= y0 and n[2] <= y1 and n[3] >= z0 and n[3] <= z1 then return nil end
  end
  local sx, sy, sz = x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1
  local contacts = boxSum(g, x0, x1, y1 + 1, y1 + 1, z0, z1)
  contacts = contacts + (x0 == 0 and sy * sz or boxSum(g, x0 - 1, x0 - 1, y0, y1, z0, z1))
  contacts = contacts + (x1 == s - 1 and sy * sz or boxSum(g, x1 + 1, x1 + 1, y0, y1, z0, z1))
  contacts = contacts + (z0 == 0 and sx * sy or boxSum(g, x0, x1, y0, y1, z0 - 1, z0 - 1))
  contacts = contacts + (z1 == s - 1 and sx * sy or boxSum(g, x0, x1, y0, y1, z1 + 1, z1 + 1))
  contacts = contacts + (y0 == 0 and sx * sz or boxSum(g, x0, x1, y0 - 1, y0 - 1, z0, z1))
  local c = (s - 1) / 2
  local cx, cz = (x0 + x1) / 2 - c, (z0 + z1) / 2 - c
  return y1 * W_TOP + cost * W_COST - contacts * W_CONTACT + math.sqrt(cx * cx + cz * cz) * W_CENTRE
end

local function commit(g, rec, best)
  local node, pose = best.node, best.pose
  for _, off in ipairs(pose.cells) do
    local x, y, z = node[1] + off[1], node[2] + off[2], node[3] + off[3]
    g.occ[key(g, x, y, z)] = rec
    if y > g.top then g.top = y end
  end
  local attach
  if best.kind == "port" then
    best.port.used = true
    attach = { kind = "port", module = best.module, port = best.port }
  else
    local X = best.cross
    if best.kind == "root" then
      X = addCross(g, node, { kind = "root" })
      g.root = X
    elseif best.kind == "new" then
      -- the path from the tree outward: each new cross on its parent
      local path = best.path
      for i = #path, 1, -1 do
        local n, ref = path[i][1], path[i][2]
        local parent
        if ref.kind == "cross" then
          ref.cross.arms[ref.di] = true
          parent = { kind = "cross", cross = ref.cross, di = ref.di }
        elseif ref.kind == "port" then
          ref.port.used = true
          parent = { kind = "port", module = ref.module, port = ref.port }
        else
          local P = g.crosses[key(g, ref.node[1], ref.node[2], ref.node[3])]
          P.arms[ref.di] = true
          parent = { kind = "cross", cross = P, di = ref.di }
        end
        X = addCross(g, n, parent)
        if parent.kind == "cross" then X.arms[OPPOSITE[parent.di]] = true end
      end
      g.newCrosses = g.newCrosses + #path
    end
    X.arms[best.di] = true
    X.modules = X.modules + 1
    attach = { kind = "cross", cross = X, di = best.di }
  end
  rec.attach, rec.pose, rec.node = attach, pose, node
  rec.ports = {}
  for _, pt in ipairs(pose.ports) do
    local n = { node[1] + pt.node[1], node[2] + pt.node[2], node[3] + pt.node[3] }
    if n[1] >= 0 and n[1] < g.s and n[3] >= 0 and n[3] < g.s and n[2] >= 0 then
      rec.ports[#rec.ports + 1] = { name = pt.name, node = n, di = pt.di }
    end
  end
  g.modules[#g.modules + 1] = rec
  rebuildSums(g)
end

-- After this placement, can the tree still reach the free space above everything? A placement that closes
-- the last way up leaves every later module without a place.
---@async
local function keepsAccess(g, best)
  local node, pose = best.node, best.pose
  local taken, top, s = {}, g.top, g.s
  local crossNodes = {}
  local function take(x, y, z)
    taken[key(g, x, y, z)] = true
    if y > top then top = y end
  end
  for _, off in ipairs(pose.cells) do take(node[1] + off[1], node[2] + off[2], node[3] + off[3]) end
  if best.kind == "root" then
    take(node[1], node[2], node[3])
    crossNodes[1] = node
  elseif best.kind == "new" then
    for _, step in ipairs(best.path) do
      take(step[1][1], step[1][2], step[1][3])
      crossNodes[#crossNodes + 1] = step[1]
    end
  end
  local seen, queue, head = {}, {}, 1
  local function push(x, y, z)
    if x < 0 or x >= s or z < 0 or z >= s or y < 0 then return false end
    local k = key(g, x, y, z)
    if g.occ[k] or taken[k] or seen[k] then return false end
    if y > top then return true end
    seen[k] = true
    queue[#queue + 1] = { x, y, z }
    return false
  end
  for _, X in pairs(g.crosses) do
    local n = X.node
    for di, d in ipairs(DIRS) do
      if not X.arms[di] and push(n[1] + d[1], n[2] + d[2], n[3] + d[3]) then return true end
    end
  end
  for _, n in ipairs(crossNodes) do
    for _, d in ipairs(DIRS) do
      if push(n[1] + d[1], n[2] + d[2], n[3] + d[3]) then return true end
    end
  end
  for _, M in ipairs(g.modules) do
    for _, pt in ipairs(M.ports) do
      if not pt.used and push(pt.node[1], pt.node[2], pt.node[3]) then return true end
    end
  end
  for _, pt in ipairs(pose.ports) do
    if push(node[1] + pt.node[1], node[2] + pt.node[2], node[3] + pt.node[3]) then return true end
  end
  while queue[head] do
    local q = queue[head]
    head = head + 1
    for _, d in ipairs(DIRS) do
      if push(q[1] + d[1], q[2] + d[2], q[3] + d[3]) then return true end
    end
    work(g, 6)
  end
  return false
end

-- The best place for one module: on a free cross arm, on a free port of a placed module, or on a new cross
-- a short path away; lowest floor first, then fewest new crosses, most contact, nearest the footprint centre.
---@async
local function place(g, rec)
  if not rec.byDi then
    rec.byDi, rec.bound, rec.banned = { {}, {}, {}, {}, {}, {} }, math.huge, {}
    for _, pose in ipairs(rec.poses) do
      table.insert(rec.byDi[pose.di], pose)
      rec.bound = math.min(rec.bound, pose.top * W_TOP - pose.faces * W_CONTACT)
    end
  end
  local best
  local banned = rec.banned
  ---@async
  local function consider(kind, node, di, cost, extra)
    for _, pose in ipairs(rec.byDi[di]) do
      if (not best or (node[2] + pose.top) * W_TOP + cost * W_COST - pose.faces * W_CONTACT < best.score)
          and not (banned[pose] and banned[pose][key(g, node[1], node[2], node[3])]) then
        local score = evaluate(g, node, pose, cost, extra and extra.path)
        if score and (not best or score < best.score) then
          best = { score = score, kind = kind, node = node, di = di, pose = pose }
          if extra then for k, v in pairs(extra) do best[k] = v end end
        end
      end
    end
  end
  if not g.root then
    for x = 0, g.s - 1 do
      for z = 0, g.s - 1 do
        for di = 1, 6 do consider("root", { x, 0, z }, di, 1) end
      end
    end
    return best
  end
  local ylo, yhi = math.max(0, g.floor - g.tallest), g.floor + g.tallest
  for _, X in pairs(g.crosses) do
    local n = X.node
    if n[2] >= ylo and n[2] <= yhi then
      for di = 1, 6 do
        if not X.arms[di] then consider("cross", n, di, 0, { cross = X }) end
      end
    end
  end
  for _, M in ipairs(g.modules) do
    for _, pt in ipairs(M.ports) do
      if not pt.used and pt.node[2] >= ylo and pt.node[2] <= yhi then
        local d = DIRS[pt.di]
        consider("port", { pt.node[1] - d[1], pt.node[2] - d[2], pt.node[3] - d[3] }, pt.di, 0, { module = M, port = pt })
      end
    end
  end
  -- no new-cross node above yTop can beat the best so far; its paths reach at most maxPath - 1 floors higher
  local yTop = yhi
  if best then yTop = math.min(yhi, math.floor((best.score - rec.bound - W_COST) / W_TOP)) end
  if yTop >= ylo then
    local dist, from = distances(g, ylo, math.min(yhi, yTop + g.maxPath - 1))
    for k, d in pairs(dist) do
      local q = from[k]
      local n
      if q.kind == "new" then
        local p = q.node
        local dd = DIRS[q.di]
        n = { p[1] + dd[1], p[2] + dd[2], p[3] + dd[3] }
      elseif q.kind == "cross" then
        local p, dd = q.cross.node, DIRS[q.di]
        n = { p[1] + dd[1], p[2] + dd[2], p[3] + dd[3] }
      else
        n = q.port.node
      end
      if not best or n[2] * W_TOP + rec.bound + d * W_COST < best.score then
        local path = pathOf(g, from, n)
        local back = path[1][2]
        local usedArm = back.kind ~= "port" and OPPOSITE[back.di] or (back.kind == "port" and OPPOSITE[back.port.di])
        for di = 1, 6 do
          if di ~= usedArm then consider("new", n, di, d, { path = path }) end
        end
      end
    end
  end
  return best
end

-- Straight runs of crosses that carry nothing but the run become struts when the game has a strut set that
-- spans the run exactly.
local function exactSpan(lengths, need)
  local best
  local function try(i, sum, picked)
    if math.abs(sum - need) < 1 then
      if not best or #picked < #best then
        best = {}
        for k, v in ipairs(picked) do best[k] = v end
      end
      return
    end
    if sum > need or #picked >= 4 or (best and #picked >= #best) then return end
    for j = i, #lengths do
      picked[#picked + 1] = lengths[j]
      try(j, sum + lengths[j], picked)
      picked[#picked] = nil
    end
  end
  try(1, 0, {})
  return best
end

local function compress(g, kit)
  local kids = {}
  for _, X in pairs(g.crosses) do
    if X.parent.kind == "cross" then
      local P = X.parent.cross
      kids[P] = kids[P] or {}
      kids[P][#kids[P] + 1] = X
    end
  end
  -- a bare cross inside a straight run: hangs on a cross, carries one cross straight on and nothing else
  local function inline(P)
    local k = kids[P]
    return P.parent.kind == "cross" and P.modules == 0 and k ~= nil and #k == 1 and k[1].parent.di == P.parent.di
  end
  local saved = 0
  for _, X in pairs(g.crosses) do
    if not inline(X) and X.parent.kind == "cross" and inline(X.parent.cross) then
      local run, P, di = {}, X.parent.cross, X.parent.di
      while inline(P) do
        run[#run + 1] = P
        P = P.parent.cross
      end
      -- P anchors the run; run[#run] hangs on it, run[1] carries X
      for j = #run, 1, -1 do
        local lengths = exactSpan(kit.lengths, j * g.u)
        if lengths and #lengths < j then
          for i = #run - j + 1, #run do run[i].removed = true end
          local child = (j < #run) and run[#run - j] or X
          child.parent = { kind = "cross", cross = P, di = di, struts = lengths }
          saved = saved + j - #lengths
          break
        end
      end
    end
  end
  for k, X in pairs(g.crosses) do
    if X.removed then g.crosses[k] = nil end
  end
  return saved
end

-- Run items in build order: the bill order, each module after the crosses and modules it hangs on.
local function emit(g, run)
  local geo, kit = sab.geo, run.kit
  local items, crossItem = {}, {}
  local u = g.u
  local function world(n)
    return { g.origin[1] + n[1] * u, g.origin[2] + n[2] * u, g.origin[3] + n[3] * u }
  end
  local function armName(di) return geo.armOf(kit.cross.conns, DIRS[di]).name end
  local emitModule
  local function emitCross(X)
    if crossItem[X] then return crossItem[X] end
    local par, it = X.parent, nil
    if par.kind == "root" then
      local p, s = world(X.node), sab.sizes[kit.cross.macro]
      it = { macro = kit.cross.macro, free = true, isConnector = true, skeleton = true,
        pos = { x = p[1] - (s and s.cX or 0), y = p[2] - (s and s.cY or 0), z = p[3] - (s and s.cZ or 0) } }
    else
      local base, conn, di
      if par.kind == "cross" then
        base, conn, di = emitCross(par.cross), armName(par.di), par.di
      else
        base, conn, di = emitModule(par.module), par.port.name, par.port.di
      end
      local prev, prevConn = base, conn
      for _, len in ipairs(par.struts or {}) do
        local s = geo.strutFor(kit, len, DIRS[di][2] ~= 0)
        local st = { macro = s.macro, pair = { entryIdx = prev, predecessorConnection = prevConn, connection = s.near },
          isConnector = true, skeleton = true, after = prev }
        items[#items + 1] = st
        prev, prevConn = st, s.far
      end
      it = { macro = kit.cross.macro, pair = { entryIdx = prev, predecessorConnection = prevConn, connection = armName(OPPOSITE[di]) },
        isConnector = true, skeleton = true, after = prev }
    end
    items[#items + 1] = it
    crossItem[X] = it
    return it
  end
  emitModule = function(M)
    local it = M.item
    if it.emitted then return it end
    local base, conn
    if M.attach.kind == "cross" then
      base, conn = emitCross(M.attach.cross), armName(M.attach.di)
    else
      base, conn = emitModule(M.attach.module), M.attach.port.name
    end
    it.pack, it.lattice, it.side = nil, nil, nil
    it.pair = { entryIdx = base, predecessorConnection = conn, connection = M.pose.conn }
    it.roll, it.after, it.emitted = M.pose.roll, base, true
    for _, st in ipairs(items) do if st.turn == nil then st.turn = it.turn end end
    items[#items + 1] = it
    return it
  end
  -- items outside the grid go last, so they cannot take an arm the grid planned
  local outside = {}
  if g.root then emitCross(g.root) end
  for _, it in ipairs(run.items) do
    if it.gridRec then emitModule(it.gridRec) elseif not it.emitted then outside[#outside + 1] = it end
  end
  for _, it in ipairs(outside) do items[#items + 1] = it end
  for _, st in ipairs(items) do st.turn = st.turn or (run.items[1] and run.items[1].turn) end
  return items
end

-- Lowest floor first; a placement that closes the way up is banned and the next best taken. A failure
-- leaves the floor where it was.
---@async
local function findPlace(g, rec)
  local floor = g.floor
  while true do
    local best = place(g, rec)
    if best then
      if keepsAccess(g, best) then return best end
      local k = key(g, best.node[1], best.node[2], best.node[3])
      rec.banned[best.pose] = rec.banned[best.pose] or {}
      rec.banned[best.pose][k] = true
      g.banned = g.banned + 1
    elseif g.floor <= g.top + g.tallest then
      g.floor = g.floor + 1
    else
      g.floor = floor
      return nil
    end
  end
end

-- One layout of every module at the current weights.
---@async
local function layout(kit, base, s, tallest)
  local g = { u = 2 * kit.arm, a = kit.arm, s = s, tallest = tallest, occ = {}, crosses = {}, modules = {}, top = 0, floor = 0,
    work = 0, frames = 0, newCrosses = 0, maxPath = MAX_PATH, banned = 0, failed = {} }
  rebuildSums(g)
  for _, b in ipairs(base) do
    local rec = { item = b.item, poses = b.poses, volume = b.volume }
    local best = findPlace(g, rec)
    if not best then
      -- last resort: a path as long as the way out needs
      g.maxPath = 2 * g.s + g.tallest
      best = findPlace(g, rec)
      g.maxPath = MAX_PATH
    end
    if best then
      commit(g, rec, best)
      sab.Trace("grid: %s on %s at %d %d %d, %d cells, cost %d", rec.item.macro, best.kind, best.node[1], best.node[2], best.node[3], #best.pose.cells, best.kind == "new" and #best.path or 0)
    else
      g.failed[#g.failed + 1] = rec.item.macro
      sab.Debug("grid: cost %g: no place for %s", W_COST, rec.item.macro)
    end
    -- the lowest floor that still has a free cell
    while g.floor < g.top do
      local open = false
      for x = 0, g.s - 1 do
        for z = 0, g.s - 1 do
          if not g.occ[key(g, x, g.floor, z)] then open = true break end
        end
        if open then break end
      end
      if open then break end
      g.floor = g.floor + 1
    end
  end
  local crosses = 0
  for _ in pairs(g.crosses) do crosses = crosses + 1 end
  g.saved = compress(g, kit)
  g.connectors = crosses - g.saved
  local lo, hi, modCells = { math.huge, math.huge, math.huge }, { -1, -1, -1 }, 0
  for k in pairs(g.occ) do
    local c = { k % g.s, math.floor(k / (g.s * g.s)), math.floor(k / g.s) % g.s }
    for i = 1, 3 do
      if c[i] < lo[i] then lo[i] = c[i] end
      if c[i] > hi[i] then hi[i] = c[i] end
    end
  end
  for _, M in ipairs(g.modules) do modCells = modCells + #M.pose.cells end
  g.used = { hi[1] - lo[1] + 1, hi[2] - lo[2] + 1, hi[3] - lo[3] + 1 }
  g.box = g.used[1] * g.used[2] * g.used[3]
  g.cost = W_COST
  sab.Debug("grid: cost %g: %d placed, %d failed, connectors %d (%d crosses, %d saved by struts), used %d x %d x %d cells, module cells %.0f%%, %d placements refused for closing the way up, %d frames",
    W_COST, #g.modules, #g.failed, g.connectors, crosses, g.saved, g.used[1], g.used[2], g.used[3], 100 * modCells / g.box, g.banned, g.frames)
  return g
end

-- Fewest failed modules, then fewest connectors, then the smallest box.
local function better(a, b)
  if not b then return true end
  if #a.failed ~= #b.failed then return #a.failed < #b.failed end
  if a.connectors ~= b.connectors then return a.connectors < b.connectors end
  return a.box < b.box
end

-- Packs once per new-cross cost in grid.costs and keeps the best layout.
---@async
local function pack(run)
  local kit = run.kit
  local probe = { u = 2 * kit.arm, a = kit.arm }
  local base, cells, spanXZ, tallest, byMacro = {}, 0, 1, 1, {}
  for _, it in ipairs(run.items) do
    it.gridRec = nil
    if not it.isConnector and not it.column then
      local m = byMacro[it.macro]
      if not m then
        local ps, minCells, minSpan = poses(probe, it.macro), math.huge, math.huge
        for _, p in ipairs(ps) do
          if #p.cells < minCells then minCells = #p.cells end
          local s = math.max(p.span[1], p.span[3])
          if s < minSpan then minSpan = s end
          if p.span[2] > tallest then tallest = p.span[2] end
        end
        m = { poses = ps, volume = minCells, span = minSpan }
        byMacro[it.macro] = m
      end
      if #m.poses > 0 then
        base[#base + 1] = { item = it, poses = m.poses, volume = m.volume }
        cells = cells + m.volume
        if m.span > spanXZ then spanXZ = m.span end
      else
        sab.Debug("grid: %s has no pose on the grid (no connections or size), packed outside", it.macro)
      end
    end
  end
  local s = math.max(spanXZ + 2, math.ceil((cells * FILL) ^ (1 / 3)))
  table.sort(base, function(a, b)
    if a.volume ~= b.volume then return a.volume > b.volume end
    return a.item.macro < b.item.macro
  end)
  sab.Debug("grid: cell %.0f m, footprint %d x %d cells, %d modules, %d module cells", probe.u, s, s, #base, cells)
  ---@type table
  local keep
  local frames, wCost = 0, W_COST
  for _, cost in ipairs(grid.costs) do
    W_COST = cost
    local g = layout(kit, base, s, tallest)
    frames = frames + g.frames
    if better(g, keep) then keep = g end
  end
  W_COST = wCost
  local g = keep
  for _, M in ipairs(g.modules) do M.item.gridRec = M end
  local H = g.top + 1
  local centre = C.GetBuildPlotCenterOffset(sab.menu.container)
  g.origin = { centre.x - (g.s - 1) * g.u / 2, centre.y - (H - 1) * g.u / 2, centre.z - (g.s - 1) * g.u / 2 }
  sab.Debug("grid: kept cost %g: %d modules, %d failed, %d connectors, %d x %d x %d cells (%.1f x %.1f x %.1f km), %d frames for %d packs",
    g.cost, #g.modules, #g.failed, g.connectors, g.used[1], g.used[2], g.used[3], g.used[1] * g.u / 1000, g.used[2] * g.u / 1000, g.used[3] * g.u / 1000, frames, #grid.costs)
  run.grid = g
  grid.last = g
  run.items = emit(g, run)
  run.next = 1
end

-- After the probe: pack in the background, one budget of checks per frame.
function grid.Start(run)
  run.packer = coroutine.create(pack)
  run.phase = "pack"
end

function grid.Step(run)
  local ok, err = coroutine.resume(run.packer, run)
  if not ok then
    sab.Error("grid layout failed: %s", tostring(err))
    sab.StopRun("grid layout failed")
    return
  end
  if coroutine.status(run.packer) == "dead" and run.packOnly then
    run.packer = nil
    sab.StopRun("packed only")
    return
  end
  if coroutine.status(run.packer) == "dead" then
    run.packer = nil
    run.phase = "begin"
  end
end
