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
-- a box may reach this share of an occupancy cell past its face
local EPS = 0.05
-- occupancy cells per grid cell side: modules claim finer boxes, crosses stay on the grid
grid.subdivide = 1
-- a new cross costs as much as a floor: fewer connectors over a denser block
local W_TOP, W_COST, W_CONTACT, W_CENTRE = 1000, 1000, 6, 1
-- eval override for layout experiments: a list of new-cross costs, each packed
---@type number[]?
grid.costs = nil
-- footprint variants packed: steps to the estimated side, x-to-z side ratios at the same area; the layout with
-- the fewest connectors is built
---@type number[]
grid.footprintSteps = { 0 }
---@type number[]
grid.footprintRatios = { 1, 2, 1 / 2 }
-- side multipliers of each shape
---@type number[]
grid.footprintScales = { 1 }

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

-- Every pose of a macro on a cross at the origin: the occupancy cells it fills (cross cell n holds occupancy
-- cells R*n .. R*n+R-1), the grid cells they touch, and its other connections that end on a cross position of
-- the grid (a port carries a cross or a module there).
local function poses(g, macro)
  local geo, list = sab.geo, {}
  local conns, size = sab.macroConns[macro], sab.sizes[macro]
  if not (conns and size) then return list end
  local u, a, R = g.u, g.a, g.R
  local h = u / R
  local eps = EPS * h
  for _, c in ipairs(conns) do
    for di, d in ipairs(DIRS) do
      for _, roll in ipairs(ROLLS) do
        local pose = sab.PoseForWorld({ a * d[1], a * d[2], a * d[3] }, d, c, roll)
        local p = { pose.pos.x, pose.pos.y, pose.pos.z }
        local box = geo.worldBox(size, p, pose.rows)
        local lo, hi, clo, chi = {}, {}, {}, {}
        for i = 1, 3 do
          lo[i] = math.floor((box.min[i] + eps) / h + R / 2)
          hi[i] = math.floor((box.max[i] - eps) / h + R / 2)
          clo[i], chi[i] = math.floor(lo[i] / R), math.floor(hi[i] / R)
        end
        if not (lo[1] <= R - 1 and hi[1] >= 0 and lo[2] <= R - 1 and hi[2] >= 0 and lo[3] <= R - 1 and hi[3] >= 0) then
          local cells, ccells = {}, {}
          for x = lo[1], hi[1] do
            for y = lo[2], hi[2] do
              for z = lo[3], hi[3] do cells[#cells + 1] = { x, y, z } end
            end
          end
          for x = clo[1], chi[1] do
            for y = clo[2], chi[2] do
              for z = clo[3], chi[3] do ccells[#ccells + 1] = { x, y, z } end
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
          -- top and outer faces, in grid cell units, bound the score before any cell is checked
          list[#list + 1] = { conn = c.name, di = di, roll = roll, pos = p, rows = pose.rows, cells = cells, ccells = ccells, ports = ports,
            span = { chi[1] - clo[1] + 1, chi[2] - clo[2] + 1, chi[3] - clo[3] + 1 }, lo = lo, hi = hi,
            top = hi[2] / R, faces = 2 * (sx * sy + sy * sz + sx * sz) / (R * R) }
        end
      end
    end
  end
  return list
end

local function key(g, x, y, z) return (y * g.sz + z) * g.sx + x end

local function free(g, x, y, z)
  return x >= 0 and x < g.sx and z >= 0 and z < g.sz and y >= 0 and g.occ[key(g, x, y, z)] == nil
end

-- occupancy cells
local function fkey(g, x, y, z) return (y * g.fz + z) * g.fx + x end

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
  local R = g.R
  for x = R * node[1], R * node[1] + R - 1 do
    for y = R * node[2], R * node[2] + R - 1 do
      for z = R * node[3], R * node[3] + R - 1 do g.focc[fkey(g, x, y, z)] = X end
    end
  end
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

-- Running sums of occupied occupancy cells, so any box of them is counted in eight lookups; rebuilt after each
-- commit.
local function rebuildSums(g)
  local w, d, h, occ = g.fx + 1, g.fz + 1, g.R * (g.top + g.tallest + 2), g.focc
  local S = {}
  for j = 0, h do
    for k = 0, g.fz do
      for i = 0, g.fx do
        local v = 0
        if i > 0 and j > 0 and k > 0 then
          v = (occ[fkey(g, i - 1, j - 1, k - 1)] and 1 or 0)
              + S[(j * d + k) * w + i - 1] + S[((j - 1) * d + k) * w + i] + S[(j * d + k - 1) * w + i]
              - S[((j - 1) * d + k) * w + i - 1] - S[(j * d + k - 1) * w + i - 1] - S[((j - 1) * d + k - 1) * w + i]
              + S[((j - 1) * d + k - 1) * w + i - 1]
        end
        S[(j * d + k) * w + i] = v
      end
    end
  end
  g.sums, g.sumH = S, h
end

-- Occupied occupancy cells in the box x0..x1, y0..y1, z0..z1 (inside the footprint, y0 >= 0).
local function boxSum(g, x0, x1, y0, y1, z0, z1)
  if y1 >= g.sumH then y1 = g.sumH - 1 end
  if y0 > y1 then return 0 end
  local S, w, d = g.sums, g.fx + 1, g.fz + 1
  local i1, j1, k1 = x1 + 1, y1 + 1, z1 + 1
  return S[(j1 * d + k1) * w + i1] - S[(j1 * d + k1) * w + x0] - S[(y0 * d + k1) * w + i1] - S[(j1 * d + z0) * w + i1]
      + S[(y0 * d + k1) * w + x0] + S[(j1 * d + z0) * w + x0] + S[(y0 * d + z0) * w + i1] - S[(y0 * d + z0) * w + x0]
end

-- A pose's occupancy cells are a box: free test and contacts (occupied or off-grid neighbours) from the running
-- sums; the score is in grid cell units.
---@async
local function evaluate(g, node, pose, cost, path)
  work(g, 10)
  local R = g.R
  local x0, x1 = R * node[1] + pose.lo[1], R * node[1] + pose.hi[1]
  local y0, y1 = R * node[2] + pose.lo[2], R * node[2] + pose.hi[2]
  local z0, z1 = R * node[3] + pose.lo[3], R * node[3] + pose.hi[3]
  local nx, nz = g.fx, g.fz
  if x0 < 0 or z0 < 0 or y0 < 0 or x1 >= nx or z1 >= nz then return nil end
  if boxSum(g, x0, x1, y0, y1, z0, z1) > 0 then return nil end
  for _, step in ipairs(path or {}) do
    local n = step[1]
    if R * n[1] + R - 1 >= x0 and R * n[1] <= x1 and R * n[2] + R - 1 >= y0 and R * n[2] <= y1
        and R * n[3] + R - 1 >= z0 and R * n[3] <= z1 then return nil end
  end
  local sx, sy, sz = x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1
  local contacts = boxSum(g, x0, x1, y1 + 1, y1 + 1, z0, z1)
  contacts = contacts + (x0 == 0 and sy * sz or boxSum(g, x0 - 1, x0 - 1, y0, y1, z0, z1))
  contacts = contacts + (x1 == nx - 1 and sy * sz or boxSum(g, x1 + 1, x1 + 1, y0, y1, z0, z1))
  contacts = contacts + (z0 == 0 and sx * sy or boxSum(g, x0, x1, y0, y1, z0 - 1, z0 - 1))
  contacts = contacts + (z1 == nz - 1 and sx * sy or boxSum(g, x0, x1, y0, y1, z1 + 1, z1 + 1))
  contacts = contacts + (y0 == 0 and sx * sz or boxSum(g, x0, x1, y0 - 1, y0 - 1, z0, z1))
  local cx, cz = (x0 + x1 - nx + 1) / (2 * R), (z0 + z1 - nz + 1) / (2 * R)
  return y1 / R * W_TOP + cost * W_COST - contacts / (R * R) * W_CONTACT + math.sqrt(cx * cx + cz * cz) * W_CENTRE
end

local function commit(g, rec, best)
  local node, pose, R = best.node, best.pose, g.R
  for _, off in ipairs(pose.cells) do
    g.focc[fkey(g, R * node[1] + off[1], R * node[2] + off[2], R * node[3] + off[3])] = rec
  end
  for _, off in ipairs(pose.ccells) do
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
  -- ports out of the footprint are kept apart: docks hang there after the pack
  rec.ports, rec.outPorts = {}, {}
  for _, pt in ipairs(pose.ports) do
    local n = { node[1] + pt.node[1], node[2] + pt.node[2], node[3] + pt.node[3] }
    local list = (n[1] >= 0 and n[1] < g.sx and n[3] >= 0 and n[3] < g.sz and n[2] >= 0) and rec.ports or rec.outPorts
    list[#list + 1] = { name = pt.name, node = n, di = pt.di }
  end
  g.modules[#g.modules + 1] = rec
  rebuildSums(g)
end

-- After this placement, can the tree still reach the free space above everything? A placement that closes
-- the last way up leaves every later module without a place.
---@async
local function keepsAccess(g, best)
  local node, pose = best.node, best.pose
  local taken, top, nx, nz = {}, g.top, g.sx, g.sz
  local crossNodes = {}
  local function take(x, y, z)
    taken[key(g, x, y, z)] = true
    if y > top then top = y end
  end
  for _, off in ipairs(pose.ccells) do take(node[1] + off[1], node[2] + off[2], node[3] + off[3]) end
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
    if x < 0 or x >= nx or z < 0 or z >= nz or y < 0 then return false end
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
    for x = 0, g.sx - 1 do
      for z = 0, g.sz - 1 do
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

-- *** docking ***
-- After the pack, piers and then dock areas hang outside the block: on a free cross arm or on a short new chain
-- of crosses under the block or beyond a face in grid.pierFaces, never wholly past the opposite faces or above.
-- A candidate's body and approach zones (exclusionzones) are boxes in the grid frame; the body may touch no
-- body or zone, a zone no body. Piers: least plot growth, then zones pointing outward; a big pier only under
-- the block. Dock areas: under the block with every zone down, then least plot growth. The first of each sits
-- nearest the first built modules, the others take the fewest new crosses. No anchor: a free drop.

local DOCK_REACH = 4
-- one face per horizontal axis carries side piers, the opposite ones stay free for growth (DIRS indices)
---@type integer[]
grid.pierFaces = { 1, 5 }
local IDENTITY = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }

local function nkey(n) return n[1] .. "," .. n[2] .. "," .. n[3] end

local function shifted(b, o)
  return { min = { b.min[1] + o[1], b.min[2] + o[2], b.min[3] + o[3] }, max = { b.max[1] + o[1], b.max[2] + o[2], b.max[3] + o[3] } }
end

-- overlap deeper than a metre
local function hit(a, b)
  for i = 1, 3 do
    if a.min[i] + 1 >= b.max[i] or a.max[i] - 1 <= b.min[i] then return false end
  end
  return true
end

-- The body and approach zone boxes of a pose around the cross it hangs on.
local function dockShape(macro, pose)
  local geo = sab.geo
  pose.body = geo.worldBox(sab.sizes[macro], pose.pos, pose.rows)
  pose.zones = geo.zoneBoxes(macro, pose.pos, pose.rows)
  pose.down = 0
  for _, z in ipairs(pose.zones) do
    if z.dir[2] < -0.99 then pose.down = pose.down + 1 end
  end
end

-- Whole km of one axis from the station's position to both faces of the layout grown to lo..hi.
local function axisKm(D, i, lo, hi)
  lo, hi = math.min(lo, D.all.min[i]) + D.shift[i], math.max(hi, D.all.max[i]) + D.shift[i]
  return math.max(0, math.ceil(hi / 1000 - 0.001)) + math.max(0, math.ceil(-lo / 1000 - 0.001))
end

-- Paid plot volume of the layout grown to a grid-frame box, in whole km per face; nil past the cap.
local function grownKm3(D, x0, y0, z0, x1, y1, z1)
  local nx, ny, nz = axisKm(D, 1, x0, x1), axisKm(D, 2, y0, y1), axisKm(D, 3, z0, z1)
  local cap = D.maxPlot
  if nx > cap or ny > cap or nz > cap then return nil end
  return math.max(1, nx) * math.max(1, ny) * math.max(1, nz)
end

-- Whether x0..x1 / z0..z1 lies wholly past the face of DIRS index fi of box F.
local function beyond(fi, F, x0, z0, x1, z1)
  local d = DIRS[fi]
  if d[1] > 0 then return x0 >= F.max[1] - 1 end
  if d[1] < 0 then return x1 <= F.min[1] + 1 end
  if d[3] > 0 then return z0 >= F.max[3] - 1 end
  return z1 <= F.min[3] + 1
end

-- Whether direction d runs level and along the face of DIRS index fi.
local function levelAlong(d, fi)
  if not fi or math.abs(d[2]) >= 0.1 then return false end
  local n = DIRS[fi]
  return math.abs(d[1] * n[1] + d[3] * n[3]) < 0.1
end

local function union(a, b)
  return { min = { math.min(a.min[1], b.min[1]), math.min(a.min[2], b.min[2]), math.min(a.min[3], b.min[3]) },
    max = { math.max(a.max[1], b.max[1]), math.max(a.max[2], b.max[2]), math.max(a.max[3], b.max[3]) } }
end

local function dockState(g, kit)
  local u, geo = g.u, sab.geo
  local cs = sab.sizes[kit.cross.macro]
  local D = { solid = {}, bodies = {}, zones = {}, crosses = {}, poses = {}, piers = 0, areas = 0,
    crossBox = cs and geo.worldBox(cs, { 0, 0, 0 }, IDENTITY) or { min = { -g.a, -g.a, -g.a }, max = { g.a, g.a, g.a } },
    F = { min = { -g.a, -g.a, -g.a }, max = { (g.sx - 1) * u + g.a, g.top * u + g.a, (g.sz - 1) * u + g.a } },
    maxPlot = sab.maxPlotKm }
  -- grid frame to station frame: the root cross's origin sits at g.origin less its centre offset
  D.shift = { g.origin[1] - (cs and cs.cX or 0), g.origin[2] - (cs and cs.cY or 0), g.origin[3] - (cs and cs.cZ or 0) }
  local seen = {}
  for _, v in pairs(g.occ) do
    -- crosses, those a strut replaced included
    if v.arms and not seen[v] then
      seen[v] = true
      D.solid[#D.solid + 1] = shifted(D.crossBox, { v.node[1] * u, v.node[2] * u, v.node[3] * u })
    end
  end
  ---@type number[]
  local sum = { 0, 0, 0 }
  local first, n = math.huge, 0
  for _, M in ipairs(g.modules) do
    local p = { M.node[1] * u + M.pose.pos[1], M.node[2] * u + M.pose.pos[2], M.node[3] * u + M.pose.pos[3] }
    M.box = geo.worldBox(sab.sizes[M.item.macro], p, M.pose.rows)
    D.solid[#D.solid + 1] = M.box
    first = math.min(first, M.item.turn or 0)
  end
  -- the first built modules: the first production chain
  for _, M in ipairs(g.modules) do
    if (M.item.turn or 0) == first then
      for i = 1, 3 do sum[i] = sum[i] + (M.box.min[i] + M.box.max[i]) / 2 end
      n = n + 1
    end
  end
  D.firstAt = n > 0 and { sum[1] / n, sum[2] / n, sum[3] / n } or { (D.F.min[1] + D.F.max[1]) / 2, 0, (D.F.min[3] + D.F.max[3]) / 2 }
  D.all = D.F
  return D
end

-- New crosses go outside the block: under it, or past a pier face, within reach.
local function dockNode(g, D, n)
  local x, y, z = n[1], n[2], n[3]
  if x < -DOCK_REACH or x >= g.sx + DOCK_REACH or z < -DOCK_REACH or z >= g.sz + DOCK_REACH or y < -DOCK_REACH or y > g.top then return false end
  local inside = x >= 0 and x < g.sx and z >= 0 and z < g.sz and y >= 0
  if inside then return false end
  if y >= 0 then
    local past = false
    for _, fi in ipairs(grid.pierFaces) do
      local d = DIRS[fi]
      if (d[1] > 0 and x >= g.sx) or (d[1] < 0 and x < 0) or (d[3] > 0 and z >= g.sz) or (d[3] < 0 and z < 0) then past = true end
    end
    if not past then return false end
  end
  if D.crosses[nkey(n)] then return false end
  local b = shifted(D.crossBox, { x * g.u, y * g.u, z * g.u })
  for _, o in ipairs(D.bodies) do if hit(b, o) then return false end end
  for _, o in ipairs(D.zones) do if hit(b, o) then return false end end
  return true
end

-- Nodes by steps from the tree: crosses' free arms and modules' outward ports are one step away.
---@async
local function dockReach(g, D)
  local levels, from = {}, {}
  local function push(n, d, ref)
    local k = nkey(n)
    if from[k] or not dockNode(g, D, n) then return end
    from[k] = ref
    levels[d] = levels[d] or {}
    levels[d][#levels[d] + 1] = n
  end
  for _, X in pairs(g.crosses) do
    for di, d in ipairs(DIRS) do
      if not X.arms[di] then push({ X.node[1] + d[1], X.node[2] + d[2], X.node[3] + d[3] }, 1, { kind = "cross", cross = X, di = di }) end
    end
  end
  for _, M in ipairs(g.modules) do
    for _, pt in ipairs(M.outPorts or {}) do
      if not pt.used then push(pt.node, 1, { kind = "port", module = M, port = pt, di = pt.di }) end
    end
  end
  for d = 1, DOCK_REACH - 1 do
    for _, n in ipairs(levels[d] or {}) do
      for di, dd in ipairs(DIRS) do push({ n[1] + dd[1], n[2] + dd[2], n[3] + dd[3] }, d + 1, { kind = "new", node = n, di = di }) end
      work(g, 6)
    end
  end
  return levels, from
end

-- Lexicographic: lower is better.
local function less(a, b)
  for i = 1, #a do
    if a[i] ~= b[i] then return a[i] < b[i] end
  end
  return false
end

-- The best place for one dock item, or nil.
---@async
local function dockPlace(g, D, it)
  local u, F = g.u, D.F
  local byDi = D.poses[it.macro]
  if not byDi then
    byDi = { {}, {}, {}, {}, {}, {} }
    for _, pose in ipairs(poses(g, it.macro)) do
      dockShape(it.macro, pose)
      table.insert(byDi[pose.di], pose)
    end
    D.poses[it.macro] = byDi
  end
  local isPier, isBuild = IsMacroClass(it.macro, "pier"), IsMacroClass(it.macro, "buildmodule")
  local big = isPier and #(ExtraData.GetMacroDataEx(it.macro, "dockingbays") or {}) > sab.planner.bigPier
  local firstOfKind = not isBuild and (isPier and D.piers or D.areas) == 0
  local A = D.all
  local baseKm3 = grownKm3(D, A.min[1], A.min[2], A.min[3], A.max[1], A.max[2], A.max[3])
  local centre = { (F.min[1] + F.max[1]) / 2, (F.min[2] + F.max[2]) / 2, (F.min[3] + F.max[3]) / 2 }
  local otherFaces = {}
  for _, fi in ipairs({ 1, 2, 5, 6 }) do
    local pierFace = false
    for _, pf in ipairs(grid.pierFaces) do if pf == fi then pierFace = true end end
    if not pierFace then otherFaces[#otherFaces + 1] = fi end
  end
  local best = {}
  local function blocked(box, path, isZone)
    if hit(box, D.F) then
      for _, s in ipairs(D.solid) do if hit(box, s) then return true end end
    end
    for _, b in ipairs(D.bodies) do if hit(box, b) then return true end end
    if not isZone then
      for _, z in ipairs(D.zones) do if hit(box, z) then return true end end
    end
    for _, n in ipairs(path) do
      if hit(box, shifted(D.crossBox, { n[1] * u, n[2] * u, n[3] * u })) then return true end
    end
    return false
  end
  ---@async
  local function try(node, di, cost, extra)
    local ox, oy, oz = node[1] * u, node[2] * u, node[3] * u
    local o
    for _, pose in ipairs(byDi[di]) do
      work(g, 40)
      local pb = pose.body
      local x0, y0, z0 = pb.min[1] + ox, pb.min[2] + oy, pb.min[3] + oz
      local x1, y1, z1 = pb.max[1] + ox, pb.max[2] + oy, pb.max[3] + oz
      -- outside the block: under it or past a pier face (a build module only past one), never wholly past the
      -- other faces or above
      local under = y1 <= F.min[2] + 1
      local past, f1, f2 = false, nil, nil
      for _, fi in ipairs(grid.pierFaces) do
        if beyond(fi, F, x0, z0, x1, z1) then
          past = true
          if f1 then f2 = fi else f1 = fi end
        end
      end
      local away = y0 >= F.max[2] - 1
      for _, fi in ipairs(otherFaces) do
        if beyond(fi, F, x0, z0, x1, z1) then away = true end
      end
      -- a build module's approach zones run level along a face it is past
      local off = 0
      if isBuild then
        for _, z in ipairs(pose.zones) do
          if not (levelAlong(z.dir, f1) or levelAlong(z.dir, f2)) then off = off + 1 end
        end
      end
      local wanted
      if isBuild then
        wanted = off == 0
      elseif isPier then
        wanted = not big or under
      else
        wanted = under and pose.down == #pose.zones
      end
      local rank = wanted and 1 or 2
      local cur = best[rank]
      local outside = past or (under and not isBuild)
      local km3 = outside and not away and not (rank == 2 and best[1]) and grownKm3(D, x0, y0, z0, x1, y1, z1)
      -- the plot growth leads the order: a worse one needs no further keys
      if km3 and not (cur and km3 - baseKm3 > cur.order[1]) then
        local bx, by, bz = (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2
        local order = { km3 - baseKm3 }
        if isPier then
          local cx, cy, cz = bx - centre[1], by - centre[2], bz - centre[3]
          local len = math.sqrt(cx * cx + cy * cy + cz * cz)
          local inward = 0
          for _, z in ipairs(pose.zones) do
            if len == 0 or (z.dir[1] * cx + z.dir[2] * cy + z.dir[3] * cz) / len < 0.5 then inward = inward + 1 end
          end
          order[2] = inward
        elseif isBuild then
          order[2] = off
        end
        local near = math.sqrt((bx - D.firstAt[1]) ^ 2 + (by - D.firstAt[2]) ^ 2 + (bz - D.firstAt[3]) ^ 2) / u
        if firstOfKind then order[#order + 1] = near; order[#order + 1] = cost else order[#order + 1] = cost; order[#order + 1] = near end
        if not cur or less(order, cur.order) then
          o = o or { ox, oy, oz }
          local body = shifted(pb, o)
          local path = extra.path or {}
          local ok = not blocked(body, path, false)
          if ok then
            for _, z in ipairs(pose.zones) do
              local zb = shifted(z, o)
              if blocked(zb, path, true) then ok = false break end
            end
          end
          if ok then best[rank] = { order = order, node = node, di = di, pose = pose, cost = cost, cross = extra.cross, path = extra.path, from = extra.from, free = extra.free } end
        end
      end
    end
  end
  -- keys never go below 0: no place d new crosses away beats a wanted one with no growth, no inward or off
  -- zone and fewer
  local function settled(d)
    local b = best[1]
    if not b or firstOfKind or b.order[1] > 0 then return false end
    if isPier or isBuild then return b.order[2] == 0 and b.order[3] < d end
    return b.order[2] < d
  end
  for _, X in pairs(g.crosses) do
    for di = 1, 6 do
      if not X.arms[di] then try(X.node, di, 0, { cross = X }) end
    end
  end
  local levels, from = {}, {}
  if not settled(1) then levels, from = dockReach(g, D) end
  for d = 1, DOCK_REACH do
    if settled(d) then break end
    for _, n in ipairs(levels[d] or {}) do
      local path, m = {}, n
      while true do
        path[#path + 1] = m
        local ref = from[nkey(m)]
        if ref.kind ~= "new" then break end
        m = ref.node
      end
      local back = OPPOSITE[from[nkey(n)].di]
      for di = 1, 6 do
        if di ~= back then try(n, di, d, { path = path, from = from }) end
      end
    end
  end
  if not (best[1] or best[2]) then
    -- no anchor: a free drop anywhere a new cross could stand
    for x = -DOCK_REACH, g.sx + DOCK_REACH - 1 do
      for y = -DOCK_REACH, g.top do
        for z = -DOCK_REACH, g.sz + DOCK_REACH - 1 do
          if dockNode(g, D, { x, y, z }) then
            for di = 1, 6 do try({ x, y, z }, di, 0, { free = true }) end
          end
        end
      end
    end
  end
  return best[1] or best[2], best[1] ~= nil
end

-- The chosen place joins the tree: new crosses from the tree outward, the module on the last one.
local function dockCommit(g, D, it, best)
  local u = g.u
  local X = best.cross
  if best.path then
    for i = #best.path, 1, -1 do
      local n = best.path[i]
      local ref = best.from[nkey(n)]
      local parent
      if ref.kind == "port" then
        ref.port.used = true
        parent = { kind = "port", module = ref.module, port = ref.port }
      else
        local P = ref.kind == "cross" and ref.cross or D.crosses[nkey(ref.node)]
        P.arms[ref.di] = true
        parent = { kind = "cross", cross = P, di = ref.di }
      end
      X = { node = n, key = "dock:" .. nkey(n), arms = { [OPPOSITE[ref.di]] = true }, parent = parent, modules = 0 }
      g.crosses[X.key] = X
      D.crosses[nkey(n)] = X
      D.bodies[#D.bodies + 1] = shifted(D.crossBox, { n[1] * u, n[2] * u, n[3] * u })
    end
    D.newCrosses = (D.newCrosses or 0) + #best.path
  end
  local o = { best.node[1] * u, best.node[2] * u, best.node[3] * u }
  local body = shifted(best.pose.body, o)
  D.bodies[#D.bodies + 1] = body
  for _, z in ipairs(best.pose.zones) do D.zones[#D.zones + 1] = shifted(z, o) end
  D.all = union(D.all, body)
  if best.free then
    local p = best.pose.pos
    it.pack, it.free, it.rows = nil, true, best.pose.rows
    it.pos = { x = o[1] + p[1] + D.shift[1], y = o[2] + p[2] + D.shift[2], z = o[3] + p[3] + D.shift[3] }
  else
    X.arms[best.di] = true
    X.modules = X.modules + 1
    it.gridRec = { item = it, attach = { kind = "cross", cross = X, di = best.di }, pose = best.pose, node = best.node, dock = true }
  end
end

-- Build modules first, then piers, then dock areas, each in bill order.
---@async
local function docks(g, run)
  local list = {}
  for pass = 1, 3 do
    for _, it in ipairs(run.items) do
      local kind = IsMacroClass(it.macro, "buildmodule") and 1 or it.column and (IsMacroClass(it.macro, "pier") and 2 or 3)
      if kind == pass then list[#list + 1] = it end
    end
  end
  local D = dockState(g, run.kit)
  if #list == 0 then return D end
  grid.lastDocks = D
  local placed, dropped, failed = 0, 0, 0
  local progress = run.packProgress
  progress.docks = #list
  for i, it in ipairs(list) do
    progress.dock = i
    local best, wanted = dockPlace(g, D, it)
    if best then
      dockCommit(g, D, it, best)
      if IsMacroClass(it.macro, "pier") then
        D.piers = D.piers + 1
      elseif it.column then
        D.areas = D.areas + 1
      end
      if best.free then dropped = dropped + 1 else placed = placed + 1 end
      sab.Debug("grid: %s %s at %d %d %d arm %d, %d new crosses, plot +%d km3%s", it.macro, best.free and "free" or "hangs", best.node[1], best.node[2], best.node[3],
        best.di, best.cost, best.order[1], wanted and "" or ", not the wanted place")
    else
      failed = failed + 1
      sab.Debug("grid: no place for %s outside the block", it.macro)
    end
  end
  local saved = compress(g, run.kit)
  g.connectors = g.connectors + (D.newCrosses or 0) - saved
  sab.Debug("grid: docking %d hung, %d free, %d without a place, %d new crosses, %d saved by struts", placed, dropped, failed, D.newCrosses or 0, saved)
  return D
end

-- Every body of the layout (crosses, modules, docks) in one station-frame box.
local function layoutBox(D)
  local all
  for _, list in ipairs({ D.solid, D.bodies }) do
    for _, b in ipairs(list) do all = all and union(all, b) or b end
  end
  return all and shifted(all, D.shift)
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
      it = { macro = kit.cross.macro, free = true, isConnector = true,
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
          isConnector = true, after = prev }
        items[#items + 1] = st
        prev, prevConn = st, s.far
      end
      it = { macro = kit.cross.macro, pair = { entryIdx = prev, predecessorConnection = prevConn, connection = armName(OPPOSITE[di]) },
        isConnector = true, after = prev }
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
    it.pack = nil
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
local function layout(kit, base, sx, sz, tallest, R, progress)
  local g = { u = 2 * kit.arm, a = kit.arm, R = R, sx = sx, sz = sz, fx = R * sx, fz = R * sz, tallest = tallest, occ = {}, focc = {},
    crosses = {}, modules = {}, top = 0, floor = 0, work = 0, frames = 0, newCrosses = 0, maxPath = MAX_PATH, banned = 0, failed = {} }
  rebuildSums(g)
  for i, b in ipairs(base) do
    progress.module = i
    local rec = { item = b.item, poses = b.poses, volume = b.volume }
    local best = findPlace(g, rec)
    if not best then
      -- last resort: a path as long as the way out needs
      g.maxPath = g.sx + g.sz + g.tallest
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
      for x = 0, g.sx - 1 do
        for z = 0, g.sz - 1 do
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
  -- the used box from the occupancy cells, in grid cell units
  local lo, hi, modCells = { math.huge, math.huge, math.huge }, { -1, -1, -1 }, 0
  for k in pairs(g.focc) do
    local c = { k % g.fx, math.floor(k / (g.fx * g.fz)), math.floor(k / g.fx) % g.fz }
    for i = 1, 3 do
      if c[i] < lo[i] then lo[i] = c[i] end
      if c[i] > hi[i] then hi[i] = c[i] end
    end
  end
  for _, M in ipairs(g.modules) do modCells = modCells + #M.pose.cells end
  g.used = { (hi[1] - lo[1] + 1) / R, (hi[2] - lo[2] + 1) / R, (hi[3] - lo[3] + 1) / R }
  g.box = g.used[1] * g.used[2] * g.used[3]
  g.cost = W_COST
  sab.Debug("grid: footprint %d x %d, occupancy 1/%d, cost %g: %d placed, %d failed, connectors %d (%d crosses, %d saved by struts), used %.1f x %.1f x %.1f km, module cells %.0f%%, %d placements refused for closing the way up, %d frames",
    g.sx, g.sz, R, W_COST, #g.modules, #g.failed, g.connectors, crosses, g.saved, g.used[1] * g.u / 1000, g.used[2] * g.u / 1000, g.used[3] * g.u / 1000,
    100 * modCells / (R * R * R) / g.box, g.banned, g.frames)
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
  local probe = { u = 2 * kit.arm, a = kit.arm, R = run.subdivide or grid.subdivide }
  local base, cells, spanXZ, tallest, byMacro = {}, 0, 1, 1, {}
  for _, it in ipairs(run.items) do
    it.gridRec = nil
    if not it.isConnector and not it.column and not IsMacroClass(it.macro, "buildmodule") then
      local m = byMacro[it.macro]
      if not m then
        local ps, minCells, minSpan = poses(probe, it.macro), math.huge, math.huge
        for _, p in ipairs(ps) do
          -- grid cells of the fine claim
          local v = #p.cells / (probe.R * probe.R * probe.R)
          if v < minCells then minCells = v end
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
  local s, minSide = math.ceil((cells * FILL) ^ (1 / 3)), spanXZ + 2
  table.sort(base, function(a, b)
    if a.volume ~= b.volume then return a.volume > b.volume end
    return a.item.macro < b.item.macro
  end)
  -- footprints: the estimated side changed by each step, then stretched to each long-to-short ratio at the same area
  local shapes, seen = {}, {}
  for _, scale in ipairs(grid.footprintScales) do
    for _, step in ipairs(grid.footprintSteps) do
      for _, ratio in ipairs(grid.footprintRatios) do
        local side = (s + step) * scale
        local sx = math.max(minSide, math.floor(side * math.sqrt(ratio) + 0.5))
        local sz = math.max(minSide, math.floor(side / math.sqrt(ratio) + 0.5))
        if not seen[sx .. "x" .. sz] then
          seen[sx .. "x" .. sz] = true
          shapes[#shapes + 1] = { sx, sz }
        end
      end
    end
  end
  local costs = grid.costs or { W_COST }
  sab.Debug("grid: cell %.0f m, estimated footprint %d x %d cells, %d footprints, %d modules, %.0f module cells", probe.u, s, s, #shapes, #base, cells)
  ---@type table
  local keep
  local frames, packs, wCost = 0, 0, W_COST
  run.packProgress = { pack = 0, packs = #shapes * #costs, module = 0, modules = #base }
  for _, shape in ipairs(shapes) do
    for _, cost in ipairs(costs) do
      W_COST = cost
      run.packProgress.pack = packs + 1
      local g = layout(kit, base, shape[1], shape[2], tallest, probe.R, run.packProgress)
      frames, packs = frames + g.frames, packs + 1
      if better(g, keep) then keep = g end
    end
  end
  W_COST = wCost
  local g = keep
  for _, M in ipairs(g.modules) do M.item.gridRec = M end
  local H = g.top + 1
  local centre = C.GetBuildPlotCenterOffset(sab.menu.container)
  g.origin = { centre.x - (g.sx - 1) * g.u / 2, centre.y - (H - 1) * g.u / 2, centre.z - (g.sz - 1) * g.u / 2 }
  local box = layoutBox(docks(g, run))
  -- per axis, a shift under half a km that puts the layout's low face on a whole km when that saves a plot km
  if box then
    local shift = {}
    for i = 1, 3 do shift[i] = -1000 * math.floor(-box.min[i] / 1000 + 0.5) - box.min[i] end
    local alt = shifted(box, shift)
    local f0, f1 = sab.PlotFaces(box), sab.PlotFaces(alt)
    for i = 1, 3 do
      if f1.uncapped[i] < f0.uncapped[i] then
        g.origin[i] = g.origin[i] + shift[i]
        box.min[i], box.max[i] = alt.min[i], alt.max[i]
        sab.Debug("grid: shifted %.0f m on axis %d to save a plot km", shift[i], i)
      end
    end
  end
  run.plotBox = box
  sab.Debug("grid: kept footprint %d x %d, occupancy 1/%d, cost %g: %d modules, %d failed, %d connectors, %.1f x %.1f x %.1f km, %d frames for %d packs",
    g.sx, g.sz, g.R, g.cost, #g.modules, #g.failed, g.connectors, g.used[1] * g.u / 1000, g.used[2] * g.u / 1000, g.used[3] * g.u / 1000, frames, packs)
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
    sab.OfferPlot(run)
  end
end
