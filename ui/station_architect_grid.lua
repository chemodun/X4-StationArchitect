-- Station Architect: dense grid layout. Crosses joined arm to arm make a grid of cells; every module is a
-- block of cells in one of its poses (any connection on any cross arm, four rolls), packed into one footprint
-- floor by floor; crosses form the shortest tree to every module, a module's free connection carries a cross or
-- another module directly; straight runs of bare crosses become struts. Sizes, connections and lengths come
-- from the game at run time.
---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C = ffi.C

local sab = StationArchitect
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
-- a box may reach this share of a cell past its face
local EPS = 0.05
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

-- the axis a DIRS index runs along; cells are u[axis] long there (a cross's arms differ per axis)
local function axisOf(di)
  local d = DIRS[di]
  return d[1] ~= 0 and 1 or d[2] ~= 0 and 2 or 3
end

-- Every pose of a macro on a cross at the origin: the cells it fills and its other connections that end on a
-- cross position of the grid (a port carries a cross or a module there).
local function poses(g, macro)
  local geo, list = sab.geo, {}
  local conns, size = sab.macroConns[macro], sab.sizes[macro]
  if not (conns and size) then return list end
  local u, a = g.u, g.a
  for _, c in ipairs(conns) do
    for di, d in ipairs(DIRS) do
      for _, roll in ipairs(ROLLS) do
        local pose = sab.PoseForWorld({ a[1] * d[1], a[2] * d[2], a[3] * d[3] }, d, c, roll)
        local p = { pose.pos.x, pose.pos.y, pose.pos.z }
        local box = geo.worldBox(size, p, pose.rows)
        -- the body lies beyond the connection it hangs by: a box reaching back past it is loose (8.00 models)
        local flat = false
        for i = 1, 3 do
          if d[i] > 0 and box.min[i] < a[i] then box.min[i] = a[i] elseif d[i] < 0 and box.max[i] > -a[i] then box.max[i] = -a[i] end
          if box.min[i] >= box.max[i] then flat = true end
        end
        local lo, hi, tlo, thi = {}, {}, {}, {}
        for i = 1, 3 do
          local eps = EPS * u[i]
          lo[i] = math.floor((box.min[i] + eps) / u[i] + 0.5)
          hi[i] = math.floor((box.max[i] - eps) / u[i] + 0.5)
          -- cells the box enters past a metre: no cross may stand there
          tlo[i] = math.floor((box.min[i] + 1) / u[i] + 0.5)
          thi[i] = math.floor((box.max[i] - 1) / u[i] + 0.5)
        end
        if not flat and not (lo[1] <= 0 and hi[1] >= 0 and lo[2] <= 0 and hi[2] >= 0 and lo[3] <= 0 and hi[3] >= 0) then
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
                local w = p[i] + q[i] + a[i] * dq[i]
                n[i] = math.floor(w / u[i] + 0.5)
                if math.abs(w - n[i] * u[i]) > 1 then aligned = false end
              end
              if aligned then ports[#ports + 1] = { name = c2.name, node = n, di = pdi } end
            end
          end
          local sx, sy, sz = hi[1] - lo[1] + 1, hi[2] - lo[2] + 1, hi[3] - lo[3] + 1
          -- top and outer faces bound the score before any cell is checked
          list[#list + 1] = { conn = c.name, di = di, roll = roll, pos = p, rows = pose.rows, cells = cells, ports = ports,
            span = { sx, sy, sz }, lo = lo, hi = hi, tlo = tlo, thi = thi, box = box,
            top = hi[2], faces = 2 * (sx * sy + sy * sz + sx * sz) }
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

-- A free connection on the face of node x, y, z towards di: a cross arm or a module's free connection on
-- either side.
local NONE = {}
local function faceTaken(g, x, y, z, di)
  local d, op = DIRS[di], OPPOSITE[di]
  local mx, my, mz = x + d[1], y + d[2], z + d[3]
  local inN = x >= 0 and x < g.sx and z >= 0 and z < g.sz and y >= 0
  local inM = mx >= 0 and mx < g.sx and mz >= 0 and mz < g.sz and my >= 0
  local X = inN and g.crosses[key(g, x, y, z)]
  if X and not X.arms[di] then return true end
  local Y = inM and g.crosses[key(g, mx, my, mz)]
  if Y and not Y.arms[op] then return true end
  for _, p in ipairs(inM and g.portAt[key(g, mx, my, mz)] or NONE) do
    if p.di == di and not p.used then return true end
  end
  for _, p in ipairs(inN and g.portAt[key(g, x, y, z)] or NONE) do
    if p.di == op and not p.used then return true end
  end
  return false
end

-- Cells lo..hi take no new cross, keys in own aside.
local function markTouched(g, lo, hi, own)
  for x = math.max(0, lo[1]), math.min(g.sx - 1, hi[1]) do
    for y = math.max(0, lo[2]), hi[2] do
      for z = math.max(0, lo[3]), math.min(g.sz - 1, hi[3]) do
        local k = key(g, x, y, z)
        if not own[k] then g.touched[k] = true end
      end
    end
  end
end

-- Records M in the cells its box enters (t0..t1) past its own claim (c0..c1).
local function markLean(g, t0, t1, c0, c1, M)
  for x = math.max(0, t0[1]), math.min(g.sx - 1, t1[1]) do
    for y = math.max(0, t0[2]), t1[2] do
      for z = math.max(0, t0[3]), math.min(g.sz - 1, t1[3]) do
        if x < c0[1] or x > c1[1] or y < c0[2] or y > c1[2] or z < c0[3] or z > c1[3] then
          local k = key(g, x, y, z)
          local L = g.lean[k]
          if not L then L = {} g.lean[k] = L end
          L[#L + 1] = M
        end
      end
    end
  end
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

-- The earliest turn a parent stands in: a module's, or that of what a cross chain hangs on; emit places a
-- module after its parent, so a module takes no parent of a later turn.
local function parentTurn(parent)
  if parent.kind == "cross" then return parent.cross.turn or 0 end
  if parent.kind == "port" then return parent.module.turn or 0 end
  return 0
end

local function addCross(g, node, parent)
  local k = key(g, node[1], node[2], node[3])
  local X = { node = node, key = k, arms = {}, parent = parent, modules = 0, turn = parentTurn(parent) }
  g.crosses[k] = X
  g.occ[k] = X
  if node[2] > g.top then g.top = node[2] end
  return X
end

-- Steps to the tree from every free cell within reach: crosses (through a free arm) and free ports are the sources.
---@async
local function distances(g, ylo, yhi, turn)
  local dist, from, queue, head = {}, {}, {}, 1
  local function push(x, y, z, d, ref)
    if y < ylo or y > yhi or not free(g, x, y, z) then return end
    local k = key(g, x, y, z)
    if dist[k] or g.touched[k] then return end
    -- no arm but the one to its parent may meet another free connection
    local back = OPPOSITE[ref.kind == "port" and ref.port.di or ref.di]
    for di = 1, 6 do
      if di ~= back and faceTaken(g, x, y, z, di) then return end
    end
    dist[k], from[k] = d, ref
    queue[#queue + 1] = { x, y, z, d }
  end
  for _, X in pairs(g.crosses) do
    local n = X.node
    if n[2] >= ylo - 1 and n[2] <= yhi + 1 and (X.turn or 0) <= turn then
      for di, d in ipairs(DIRS) do
        if not X.arms[di] then push(n[1] + d[1], n[2] + d[2], n[3] + d[3], 1, { kind = "cross", cross = X, di = di }) end
      end
    end
  end
  for _, M in ipairs(g.modules) do
    if (M.turn or 0) <= turn then
      for _, pt in ipairs(M.ports) do
        if not pt.used then push(pt.node[1], pt.node[2], pt.node[3], 1, { kind = "port", module = M, port = pt }) end
      end
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

-- Running sums of occupied cells, so any box of them is counted in eight lookups; rebuilt after each commit.
local function rebuildSums(g)
  local w, d, h, occ = g.sx + 1, g.sz + 1, g.top + g.tallest + 2, g.occ
  local S, CS, LS, lean = {}, {}, {}, g.lean
  for j = 0, h do
    for k = 0, g.sz do
      for i = 0, g.sx do
        local v, c, l = 0, 0, 0
        if i > 0 and j > 0 and k > 0 then
          local fk = key(g, i - 1, j - 1, k - 1)
          local o = occ[fk]
          l = (lean[fk] and 1 or 0)
              + LS[(j * d + k) * w + i - 1] + LS[((j - 1) * d + k) * w + i] + LS[(j * d + k - 1) * w + i]
              - LS[((j - 1) * d + k) * w + i - 1] - LS[(j * d + k - 1) * w + i - 1] - LS[((j - 1) * d + k - 1) * w + i]
              + LS[((j - 1) * d + k - 1) * w + i - 1]
          v = (o and 1 or 0)
              + S[(j * d + k) * w + i - 1] + S[((j - 1) * d + k) * w + i] + S[(j * d + k - 1) * w + i]
              - S[((j - 1) * d + k) * w + i - 1] - S[(j * d + k - 1) * w + i - 1] - S[((j - 1) * d + k - 1) * w + i]
              + S[((j - 1) * d + k - 1) * w + i - 1]
          c = (o and o.arms and 1 or 0)
              + CS[(j * d + k) * w + i - 1] + CS[((j - 1) * d + k) * w + i] + CS[(j * d + k - 1) * w + i]
              - CS[((j - 1) * d + k) * w + i - 1] - CS[(j * d + k - 1) * w + i - 1] - CS[((j - 1) * d + k - 1) * w + i]
              + CS[((j - 1) * d + k - 1) * w + i - 1]
        end
        S[(j * d + k) * w + i], CS[(j * d + k) * w + i], LS[(j * d + k) * w + i] = v, c, l
      end
    end
  end
  g.sums, g.csums, g.lsums, g.sumH = S, CS, LS, h
end

-- Occupied cells in the box x0..x1, y0..y1, z0..z1 (inside the footprint, y0 >= 0); sums: g.csums counts cross
-- cells only, g.lsums cells a module box leans into.
local function boxSum(g, x0, x1, y0, y1, z0, z1, sums)
  if y1 >= g.sumH then y1 = g.sumH - 1 end
  if y0 > y1 then return 0 end
  local S, w, d = sums or g.sums, g.sx + 1, g.sz + 1
  local i1, j1, k1 = x1 + 1, y1 + 1, z1 + 1
  return S[(j1 * d + k1) * w + i1] - S[(j1 * d + k1) * w + x0] - S[(y0 * d + k1) * w + i1] - S[(j1 * d + z0) * w + i1]
      + S[(y0 * d + k1) * w + x0] + S[(j1 * d + z0) * w + x0] + S[(y0 * d + z0) * w + i1] - S[(y0 * d + z0) * w + x0]
end

local function inBox(x, y, z, x0, x1, y0, y1, z0, z1)
  return x >= x0 and x <= x1 and y >= y0 and y <= y1 and z >= z0 and z <= z1
end

-- Module M (not on) has a box that overlaps x0..x1, y0..y1, z0..z1 in grid metres.
local function meets(M, on, x0, x1, y0, y1, z0, z1)
  local b = M and M ~= on and M.box
  return b and x0 < b.max[1] and x1 > b.min[1] and y0 < b.max[2] and y1 > b.min[2] and z0 < b.max[3] and z1 > b.min[3]
end

local function crossAt(g, x, y, z)
  return x >= 0 and x < g.sx and z >= 0 and z < g.sz and y >= 0 and g.crosses[key(g, x, y, z)] ~= nil
end

-- floors up to g.free (a seed block's top) cost nothing: an upgrade fills the block's height before rising
local function topCost(g, y)
  return y > g.free and (y - g.free) * W_TOP or 0
end

-- A pose's cells are a box: free test and contacts (occupied or off-grid neighbours) from the running sums.
---@async
local function evaluate(g, node, pose, cost, path, on)
  work(g, 10)
  local x0, x1 = node[1] + pose.lo[1], node[1] + pose.hi[1]
  local y0, y1 = node[2] + pose.lo[2], node[2] + pose.hi[2]
  local z0, z1 = node[3] + pose.lo[3], node[3] + pose.hi[3]
  local nx, nz = g.sx, g.sz
  if x0 < 0 or z0 < 0 or y0 < 0 or x1 >= nx or z1 >= nz then return nil end
  if boxSum(g, x0, x1, y0, y1, z0, z1) > 0 then return nil end
  local tx0, tx1 = node[1] + pose.tlo[1], node[1] + pose.thi[1]
  local ty0, ty1 = node[2] + pose.tlo[2], node[2] + pose.thi[2]
  local tz0, tz1 = node[3] + pose.tlo[3], node[3] + pose.thi[3]
  local cx0, cx1, cy0, cz0, cz1 = math.max(0, tx0), math.min(nx - 1, tx1), math.max(0, ty0), math.max(0, tz0), math.min(nz - 1, tz1)
  local crosses = boxSum(g, cx0, cx1, cy0, ty1, cz0, cz1, g.csums)
  -- modules in the cells the box leans into, and modules leaning into its own cells: the boxes themselves must
  -- not meet, the module it hangs on aside
  local leaning, leaned = boxSum(g, cx0, cx1, cy0, ty1, cz0, cz1) > crosses, boxSum(g, x0, x1, y0, y1, z0, z1, g.lsums) > 0
  if leaning or leaned then
    local b, u = pose.box, g.u
    local bx0, bx1 = b.min[1] + node[1] * u[1] + 1, b.max[1] + node[1] * u[1] - 1
    local by0, by1 = b.min[2] + node[2] * u[2] + 1, b.max[2] + node[2] * u[2] - 1
    local bz0, bz1 = b.min[3] + node[3] * u[3] + 1, b.max[3] + node[3] * u[3] - 1
    if leaning then
      for x = cx0, cx1 do
        for y = cy0, math.min(ty1, g.sumH - 1) do
          for z = cz0, cz1 do
            if (x < x0 or x > x1 or y < y0 or y > y1 or z < z0 or z > z1)
                and meets(g.occ[key(g, x, y, z)], on, bx0, bx1, by0, by1, bz0, bz1) then return nil end
          end
        end
      end
    end
    if leaned then
      for x = x0, x1 do
        for y = y0, math.min(y1, g.sumH - 1) do
          for z = z0, z1 do
            local L = g.lean[key(g, x, y, z)]
            if L then
              for _, M in ipairs(L) do
                if meets(M, on, bx0, bx1, by0, by1, bz0, bz1) then return nil end
              end
            end
          end
        end
      end
    end
  end
  if crosses > 0 then
    -- the attach cross is the module's to touch
    if crossAt(g, node[1], node[2], node[3]) and inBox(node[1], node[2], node[3], tx0, tx1, ty0, ty1, tz0, tz1) then
      crosses = crosses - 1
    end
    if crosses > 0 then return nil end
  end
  -- a cross or another free connection on one of its other connections closes a loop the editor refuses in
  -- some rolls
  for _, pt in ipairs(pose.ports) do
    local px, py, pz, d = node[1] + pt.node[1], node[2] + pt.node[2], node[3] + pt.node[3], DIRS[pt.di]
    if crossAt(g, px, py, pz) or faceTaken(g, px - d[1], py - d[2], pz - d[3], pt.di) then
      return nil
    end
    for i = 2, #(path or {}) do
      local n = path[i][1]
      if n[1] == node[1] + pt.node[1] and n[2] == node[2] + pt.node[2] and n[3] == node[3] + pt.node[3] then return nil end
    end
  end
  for i, step in ipairs(path or {}) do
    local n = step[1]
    if i == 1 then
      if inBox(n[1], n[2], n[3], x0, x1, y0, y1, z0, z1) then return nil end
    elseif inBox(n[1], n[2], n[3], tx0, tx1, ty0, ty1, tz0, tz1) then
      return nil
    end
  end
  local sx, sy, sz = x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1
  local contacts = boxSum(g, x0, x1, y1 + 1, y1 + 1, z0, z1)
  contacts = contacts + (x0 == 0 and sy * sz or boxSum(g, x0 - 1, x0 - 1, y0, y1, z0, z1))
  contacts = contacts + (x1 == nx - 1 and sy * sz or boxSum(g, x1 + 1, x1 + 1, y0, y1, z0, z1))
  contacts = contacts + (z0 == 0 and sx * sy or boxSum(g, x0, x1, y0, y1, z0 - 1, z0 - 1))
  contacts = contacts + (z1 == nz - 1 and sx * sy or boxSum(g, x0, x1, y0, y1, z1 + 1, z1 + 1))
  contacts = contacts + (y0 == 0 and sx * sz or boxSum(g, x0, x1, y0 - 1, y0 - 1, z0, z1))
  local cx, cz = (x0 + x1 - nx + 1) / 2, (z0 + z1 - nz + 1) / 2
  return topCost(g, y1) + cost * W_COST - contacts * W_CONTACT + math.sqrt(cx * cx + cz * cz) * W_CENTRE
end

local function commit(g, rec, best)
  local node, pose = best.node, best.pose
  for _, off in ipairs(pose.cells) do
    local x, y, z = node[1] + off[1], node[2] + off[2], node[3] + off[3]
    g.occ[key(g, x, y, z)] = rec
    if y > g.top then g.top = y end
  end
  local own = {}
  for _, pt in ipairs(pose.ports) do
    local x, y, z = node[1] + pt.node[1], node[2] + pt.node[2], node[3] + pt.node[3]
    if free(g, x, y, z) then own[key(g, x, y, z)] = true end
  end
  local t0 = { node[1] + pose.tlo[1], node[2] + pose.tlo[2], node[3] + pose.tlo[3] }
  local t1 = { node[1] + pose.thi[1], node[2] + pose.thi[2], node[3] + pose.thi[3] }
  markTouched(g, t0, t1, own)
  markLean(g, t0, t1, { node[1] + pose.lo[1], node[2] + pose.lo[2], node[3] + pose.lo[3] },
    { node[1] + pose.hi[1], node[2] + pose.hi[2], node[3] + pose.hi[3] }, rec)
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
  rec.turn = math.max(rec.item.turn or 0, parentTurn(attach))
  local u = g.u
  rec.box = { min = { pose.box.min[1] + node[1] * u[1], pose.box.min[2] + node[2] * u[2], pose.box.min[3] + node[3] * u[3] },
    max = { pose.box.max[1] + node[1] * u[1], pose.box.max[2] + node[2] * u[2], pose.box.max[3] + node[3] * u[3] } }
  -- ports out of the footprint are kept apart: docks hang there after the pack
  rec.ports, rec.outPorts = {}, {}
  for _, pt in ipairs(pose.ports) do
    local n = { node[1] + pt.node[1], node[2] + pt.node[2], node[3] + pt.node[3] }
    local inside = n[1] >= 0 and n[1] < g.sx and n[3] >= 0 and n[3] < g.sz and n[2] >= 0
    local list = inside and rec.ports or rec.outPorts
    local port = { name = pt.name, node = n, di = pt.di }
    list[#list + 1] = port
    if inside then
      local k = key(g, n[1], n[2], n[3])
      g.portAt[k] = g.portAt[k] or {}
      table.insert(g.portAt[k], port)
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
  local taken, top, nx, nz = {}, g.top, g.sx, g.sz
  local crossNodes = {}
  local function take(x, y, z)
    taken[key(g, x, y, z)] = true
    if y > top then top = y end
  end
  -- the free arms of the crosses the placement adds, by cell
  local armsFree = {}
  local function newCross(n, used)
    local arms = {}
    for di = 1, 6 do arms[di] = not used[di] end
    armsFree[key(g, n[1], n[2], n[3])] = arms
  end
  for _, off in ipairs(pose.cells) do take(node[1] + off[1], node[2] + off[2], node[3] + off[3]) end
  if best.kind == "root" then
    take(node[1], node[2], node[3])
    crossNodes[1] = node
    newCross(node, { [best.di] = true })
  elseif best.kind == "new" then
    local path = best.path
    for i, step in ipairs(path) do
      take(step[1][1], step[1][2], step[1][3])
      crossNodes[#crossNodes + 1] = step[1]
      local ref, used = step[2], {}
      used[OPPOSITE[ref.kind == "port" and ref.port.di or ref.di]] = true
      used[i > 1 and path[i - 1][2].di or best.di] = true
      newCross(step[1], used)
    end
  end
  local ownPorts = {}
  for _, pt in ipairs(pose.ports) do
    ownPorts[#ownPorts + 1] = { node[1] + pt.node[1], node[2] + pt.node[2], node[3] + pt.node[3], pt.di }
  end
  -- faceTaken as it reads once the placement is committed
  local function faceBlocked(x, y, z, di)
    if faceTaken(g, x, y, z, di) then return true end
    local d = DIRS[di]
    local mx, my, mz = x + d[1], y + d[2], z + d[3]
    if mx >= 0 and mx < nx and mz >= 0 and mz < nz and my >= 0 then
      local A = armsFree[key(g, mx, my, mz)]
      if A and A[OPPOSITE[di]] then return true end
    end
    for _, p in ipairs(ownPorts) do
      if (p[4] == di and p[1] == mx and p[2] == my and p[3] == mz) or (p[4] == OPPOSITE[di] and p[1] == x and p[2] == y and p[3] == z) then
        return true
      end
    end
    return false
  end
  -- the module's touched cells as commit marks them: no new cross may stand there either
  local own, touched = {}, {}
  for _, pt in ipairs(pose.ports) do own[key(g, node[1] + pt.node[1], node[2] + pt.node[2], node[3] + pt.node[3])] = true end
  for x = math.max(0, node[1] + pose.tlo[1]), math.min(nx - 1, node[1] + pose.thi[1]) do
    for y = math.max(0, node[2] + pose.tlo[2]), node[2] + pose.thi[2] do
      for z = math.max(0, node[3] + pose.tlo[3]), math.min(nz - 1, node[3] + pose.thi[3]) do
        local k = key(g, x, y, z)
        if not own[k] then touched[k] = true end
      end
    end
  end
  -- the way up must be one distances can grow new crosses along
  local seen, queue, head = {}, {}, 1
  local function push(x, y, z, back)
    if x < 0 or x >= nx or z < 0 or z >= nz or y < 0 then return false end
    local k = key(g, x, y, z)
    if g.occ[k] or taken[k] or seen[k] or g.touched[k] or touched[k] then return false end
    for di = 1, 6 do
      if di ~= back and faceBlocked(x, y, z, di) then return false end
    end
    if y > top then return true end
    seen[k] = true
    queue[#queue + 1] = { x, y, z }
    return false
  end
  for _, X in pairs(g.crosses) do
    local n = X.node
    for di, d in ipairs(DIRS) do
      if not X.arms[di] and push(n[1] + d[1], n[2] + d[2], n[3] + d[3], OPPOSITE[di]) then return true end
    end
  end
  for _, n in ipairs(crossNodes) do
    for di, d in ipairs(DIRS) do
      if push(n[1] + d[1], n[2] + d[2], n[3] + d[3], OPPOSITE[di]) then return true end
    end
  end
  for _, M in ipairs(g.modules) do
    for _, pt in ipairs(M.ports) do
      if not pt.used and push(pt.node[1], pt.node[2], pt.node[3], OPPOSITE[pt.di]) then return true end
    end
  end
  for _, pt in ipairs(pose.ports) do
    if push(node[1] + pt.node[1], node[2] + pt.node[2], node[3] + pt.node[3], OPPOSITE[pt.di]) then return true end
  end
  while queue[head] do
    local q = queue[head]
    head = head + 1
    for di, d in ipairs(DIRS) do
      if push(q[1] + d[1], q[2] + d[2], q[3] + d[3], OPPOSITE[di]) then return true end
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
    rec.byDi, rec.bound, rec.minTop, rec.banned = { {}, {}, {}, {}, {}, {} }, math.huge, math.huge, {}
    for _, pose in ipairs(rec.poses) do
      table.insert(rec.byDi[pose.di], pose)
      rec.minTop = math.min(rec.minTop, pose.top)
      rec.bound = math.min(rec.bound, -pose.faces * W_CONTACT)
    end
  end
  local best
  local banned = rec.banned
  local turn = rec.item.turn or math.huge
  ---@async
  local function consider(kind, node, di, cost, extra)
    for _, pose in ipairs(rec.byDi[di]) do
      if (not best or topCost(g, node[2] + pose.top) + cost * W_COST - pose.faces * W_CONTACT < best.score)
          and not (banned[pose] and banned[pose][key(g, node[1], node[2], node[3])]) then
        local score = evaluate(g, node, pose, cost, extra and extra.path, extra and extra.module)
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
  local ylo, yhi = math.max(0, g.floor - g.tallest), math.max(g.floor, g.free) + g.tallest
  for _, X in pairs(g.crosses) do
    local n = X.node
    if n[2] >= ylo and n[2] <= yhi and (X.turn or 0) <= turn then
      for di = 1, 6 do
        if not X.arms[di] then consider("cross", n, di, 0, { cross = X }) end
      end
    end
  end
  for _, M in ipairs(g.modules) do
    for _, pt in ipairs((M.turn or 0) <= turn and M.ports or NONE) do
      if not pt.used and pt.node[2] >= ylo and pt.node[2] <= yhi then
        local d = DIRS[pt.di]
        consider("port", { pt.node[1] - d[1], pt.node[2] - d[2], pt.node[3] - d[3] }, pt.di, 0, { module = M, port = pt })
      end
    end
  end
  -- no new-cross node above yTop can beat the best so far; its paths reach at most maxPath - 1 floors higher
  local yTop = yhi
  if best then
    local room = best.score - rec.bound - W_COST
    yTop = room > 0 and math.min(yhi, math.floor(g.free - rec.minTop + room / W_TOP)) or -1
  end
  if yTop >= ylo then
    local dist, from = distances(g, ylo, math.min(yhi, yTop + g.maxPath - 1), turn)
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
      if not best or topCost(g, n[2] + rec.minTop) + rec.bound + d * W_COST < best.score then
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
        local lengths = exactSpan(kit.lengths, j * g.u[axisOf(di)])
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

local ZONE_MARGIN = sab.geo.zoneMargin
local function nearZone(a, z)
  for i = 1, 3 do
    if a.min[i] >= z.max[i] + ZONE_MARGIN or a.max[i] <= z.min[i] - ZONE_MARGIN then return false end
  end
  return true
end

-- The body and approach zone boxes of a pose around the cross it hangs on.
local function dockShape(macro, pose)
  local geo = sab.geo
  pose.body = pose.box
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
  local u, a, geo = g.u, g.a, sab.geo
  local cs = sab.sizes[kit.cross.macro]
  local D = { solid = {}, bodies = {}, zones = {}, crosses = {}, poses = {}, piers = 0, areas = 0,
    crossBox = cs and geo.worldBox(cs, { 0, 0, 0 }, IDENTITY) or { min = { -a[1], -a[2], -a[3] }, max = { a[1], a[2], a[3] } },
    F = { min = { -a[1], -a[2], -a[3] }, max = { (g.sx - 1) * u[1] + a[1], g.top * u[2] + a[2], (g.sz - 1) * u[3] + a[3] } },
    maxPlot = sab.maxPlotKm }
  -- grid frame to station frame: the root cross's origin sits at g.origin less its centre offset
  D.shift = { g.origin[1] - (cs and cs.cX or 0), g.origin[2] - (cs and cs.cY or 0), g.origin[3] - (cs and cs.cZ or 0) }
  local seen = {}
  for _, v in pairs(g.occ) do
    -- crosses, those a strut replaced included
    if v.arms and not seen[v] then
      seen[v] = true
      D.solid[#D.solid + 1] = shifted(D.crossBox, { v.node[1] * u[1], v.node[2] * u[2], v.node[3] * u[3] })
    end
  end
  ---@type number[]
  local sum = { 0, 0, 0 }
  local first, n = math.huge, 0
  for _, M in ipairs(g.modules) do
    if M.pose.box then
      M.box = shifted(M.pose.box, { M.node[1] * u[1], M.node[2] * u[2], M.node[3] * u[3] })
    else
      local p = { M.node[1] * u[1] + M.pose.pos[1], M.node[2] * u[2] + M.pose.pos[2], M.node[3] * u[3] + M.pose.pos[3] }
      M.box = geo.worldBox(sab.sizes[M.item.macro], p, M.pose.rows)
    end
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
  for _, z in ipairs(g.zones or {}) do D.zones[#D.zones + 1] = z end
  D.firstAt = n > 0 and { sum[1] / n, sum[2] / n, sum[3] / n } or { (D.F.min[1] + D.F.max[1]) / 2, 0, (D.F.min[3] + D.F.max[3]) / 2 }
  D.all = D.F
  -- solids lean past the footprint box by up to EPS
  D.hull = D.F
  for _, s in ipairs(D.solid) do D.hull = union(D.hull, s) end
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
  local b = shifted(D.crossBox, { x * g.u[1], y * g.u[2], z * g.u[3] })
  for _, o in ipairs(D.bodies) do if hit(b, o) then return false end end
  for _, o in ipairs(D.zones) do if nearZone(b, o) then return false end end
  return true
end

-- Nodes by steps from the tree: crosses' free arms and modules' outward ports are one step away.
---@async
local function dockReach(g, D, turn)
  local levels, from = {}, {}
  local function push(n, d, ref)
    local k = nkey(n)
    if from[k] or not dockNode(g, D, n) then return end
    from[k] = ref
    levels[d] = levels[d] or {}
    levels[d][#levels[d] + 1] = n
  end
  for _, X in pairs(g.crosses) do
    for di, d in ipairs((X.turn or 0) <= turn and DIRS or NONE) do
      if not X.arms[di] then push({ X.node[1] + d[1], X.node[2] + d[2], X.node[3] + d[3] }, 1, { kind = "cross", cross = X, di = di }) end
    end
  end
  for _, M in ipairs(g.modules) do
    for _, pt in ipairs((M.turn or 0) <= turn and M.outPorts or NONE) do
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
  local uMean = (u[1] + u[2] + u[3]) / 3
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
  local big = isPier and #(ExtraData and ExtraData.GetMacroDataEx(it.macro, "dockingbays") or {}) > sab.planner.bigPier
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
    local touch = isZone and nearZone or hit
    if touch(box, D.hull) then
      for _, s in ipairs(D.solid) do if touch(box, s) then return true end end
    end
    for _, b in ipairs(D.bodies) do if touch(box, b) then return true end end
    if not isZone then
      for _, z in ipairs(D.zones) do if nearZone(box, z) then return true end end
    end
    for _, n in ipairs(path) do
      if touch(box, shifted(D.crossBox, { n[1] * u[1], n[2] * u[2], n[3] * u[3] })) then return true end
    end
    return false
  end
  ---@async
  local function try(node, di, cost, extra)
    local ox, oy, oz = node[1] * u[1], node[2] * u[2], node[3] * u[3]
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
        local near = math.sqrt((bx - D.firstAt[1]) ^ 2 + (by - D.firstAt[2]) ^ 2 + (bz - D.firstAt[3]) ^ 2) / uMean
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
  local turn = it.turn or math.huge
  for _, X in pairs(g.crosses) do
    for di = 1, (X.turn or 0) <= turn and 6 or 0 do
      if not X.arms[di] then try(X.node, di, 0, { cross = X }) end
    end
  end
  local levels, from = {}, {}
  if not settled(1) then levels, from = dockReach(g, D, turn) end
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
      X = { node = n, key = "dock:" .. nkey(n), arms = { [OPPOSITE[ref.di]] = true }, parent = parent, modules = 0, turn = parentTurn(parent) }
      g.crosses[X.key] = X
      D.crosses[nkey(n)] = X
      D.bodies[#D.bodies + 1] = shifted(D.crossBox, { n[1] * u[1], n[2] * u[2], n[3] * u[3] })
    end
    D.newCrosses = (D.newCrosses or 0) + #best.path
  end
  local o = { best.node[1] * u[1], best.node[2] * u[2], best.node[3] * u[3] }
  local body = shifted(best.pose.body, o)
  D.bodies[#D.bodies + 1] = body
  for _, z in ipairs(best.pose.zones) do D.zones[#D.zones + 1] = shifted(z, o) end
  D.all = union(D.all, body)
  -- the item takes it only if this layout is kept (applyDocks)
  if best.free then
    local p = best.pose.pos
    g.dockOut[it] = { rows = best.pose.rows, pos = { o[1] + p[1], o[2] + p[2], o[3] + p[3] } }
  else
    X.arms[best.di] = true
    X.modules = X.modules + 1
    g.dockOut[it] = { gridRec = { item = it, attach = { kind = "cross", cross = X, di = best.di }, pose = best.pose, node = best.node, dock = true } }
  end
end

-- A detached grid's root pier hangs under the root cross, the pose with the most approach zones pointing down;
-- emit places it first, free, and the root cross on it.
local function rootUnder(g, D, it)
  local u, X = g.u, g.root
  if not X or X.arms[4] then return false end
  local o = { X.node[1] * u[1], X.node[2] * u[2], X.node[3] * u[3] }
  local function blocked(box)
    for _, s in ipairs(D.solid) do if hit(box, s) then return true end end
    return false
  end
  local best
  for _, pose in ipairs(poses(g, it.macro)) do
    if pose.di == 4 then
      dockShape(it.macro, pose)
      local up = #pose.zones - pose.down
      if not (best and up >= best.up) and not blocked(shifted(pose.body, o)) then
        local ok = true
        for _, z in ipairs(pose.zones) do
          if blocked(shifted(z, o)) then ok = false break end
        end
        if ok then best = { pose = pose, up = up } end
      end
    end
  end
  if not best then
    sab.Debug("grid: %s has no pose under the root cross, it docks as usual", it.macro)
    return false
  end
  local body = shifted(best.pose.body, o)
  D.bodies[#D.bodies + 1] = body
  for _, z in ipairs(best.pose.zones) do D.zones[#D.zones + 1] = shifted(z, o) end
  D.all = union(D.all, body)
  D.piers = D.piers + 1
  X.arms[4] = true
  g.rootPier = { item = it, pose = best.pose, body = body }
  sab.Debug("grid: root %s under the root cross, %d of %d approach zones down", it.macro, best.pose.down, #best.pose.zones)
  return true
end

-- Build modules first, then piers, then dock areas, each in bill order. g.dockFailed and g.dockFree count the
-- docks without a place and those dropped free.
---@async
local function docks(g, run)
  local D = dockState(g, run.kit)
  g.rootPier, g.dockOut, g.dockFailed, g.dockFree = nil, {}, 0, 0
  if run.rootPier then rootUnder(g, D, run.rootPier) end
  local list = {}
  for pass = 1, 3 do
    for _, it in ipairs(run.items) do
      local kind = IsMacroClass(it.macro, "buildmodule") and 1 or it.column and (IsMacroClass(it.macro, "pier") and 2 or 3)
      if kind == pass and not (g.rootPier and g.rootPier.item == it) then list[#list + 1] = it end
    end
  end
  if #list == 0 then return D end
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
      elseif IsMacroClass(it.macro, "dockarea") then
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
  g.dockFailed, g.dockFree = failed, dropped
  sab.Debug("grid: footprint %d x %d docking %d hung, %d free, %d without a place, %d new crosses, %d saved by struts", g.sx, g.sz, placed, dropped, failed, D.newCrosses or 0, saved)
  return D
end

-- The kept layout's docks onto their items: a hung dock its grid record, a free one its pose in the station frame.
local function applyDocks(g, D)
  for it, r in pairs(g.dockOut or {}) do
    if r.gridRec then
      it.gridRec = r.gridRec
    else
      it.pack, it.free, it.rows = nil, true, r.rows
      it.pos = { x = r.pos[1] + D.shift[1], y = r.pos[2] + D.shift[2], z = r.pos[3] + D.shift[3] }
    end
  end
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
    return { g.origin[1] + n[1] * u[1], g.origin[2] + n[2] * u[2], g.origin[3] + n[3] * u[3] }
  end
  -- a plan cross keeps its own arm names
  local function armName(X, di) return X and X.armNames and X.armNames[di] or geo.armOf(kit.cross.conns, DIRS[di]).name end
  for X, it in pairs(g.existing or {}) do crossItem[X] = it end
  local emitModule
  local function emitCross(X)
    if crossItem[X] then return crossItem[X] end
    local par, it = X.parent, nil
    if par.kind == "root" then
      local p, s = world(X.node), sab.sizes[kit.cross.macro]
      local R = X == g.root and g.rootPier
      if R then
        local pier, q = R.item, R.pose.pos
        pier.pack, pier.free, pier.alone, pier.rows, pier.emitted = nil, true, true, R.pose.rows, true
        pier.pos = { x = p[1] - (s and s.cX or 0) + q[1], y = p[2] - (s and s.cY or 0) + q[2], z = p[3] - (s and s.cZ or 0) + q[3] }
        items[#items + 1] = pier
        it = { macro = kit.cross.macro, pair = { entryIdx = pier, predecessorConnection = R.pose.conn, connection = armName(nil, 4) },
          isConnector = true, after = pier }
      else
        it = { macro = kit.cross.macro, free = true, alone = run.detached, isConnector = true,
          pos = { x = p[1] - (s and s.cX or 0), y = p[2] - (s and s.cY or 0), z = p[3] - (s and s.cZ or 0) } }
      end
    else
      local base, conn, di
      if par.kind == "cross" then
        base, conn, di = emitCross(par.cross), armName(par.cross, par.di), par.di
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
      it = { macro = kit.cross.macro, pair = { entryIdx = prev, predecessorConnection = prevConn, connection = armName(nil, OPPOSITE[di]) },
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
      base, conn = emitCross(M.attach.cross), armName(M.attach.cross, M.attach.di)
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
  -- a dock dropped free keeps its turn; items outside the grid go last, so they cannot take an arm the grid planned
  local outside = {}
  if g.root then emitCross(g.root) end
  for _, it in ipairs(run.items) do
    if it.gridRec then
      emitModule(it.gridRec)
    elseif it.free and it.pos and not it.emitted then
      it.emitted = true
      items[#items + 1] = it
    elseif not it.emitted then
      outside[#outside + 1] = it
    end
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

-- *** upgrades ***
-- A plan whose kit crosses stand on one lattice (axis-aligned, whole cells apart) seeds the grid: the lattice
-- holding most of them, its block (crosses and modules, columns aside) inside every footprint, every other entry
-- an obstacle. Free arms and free connections ending on a lattice node are the attach points.

local function axisAligned(rows)
  for i = 1, 3 do
    for j = 1, 3 do
      local v = math.abs(rows[i][j])
      if v > 1e-3 and math.abs(v - 1) > 1e-3 then return false end
    end
  end
  return true
end

-- Cells a world box reaches more than eps metres into (nil: EPS of the cell), relative to the lattice cross at c0.
local function cellRange(box, c0, u, eps)
  local lo, hi = {}, {}
  for i = 1, 3 do
    local e = eps or EPS * u[i]
    lo[i] = math.floor((box.min[i] - c0[i] + e) / u[i] + 0.5)
    hi[i] = math.floor((box.max[i] - c0[i] - e) / u[i] + 0.5)
  end
  return lo, hi
end

-- run.seed for pack, false when the plan has no lattice with a free attach point.
function grid.Seed(run)
  run.seed = nil
  local geo, kit = sab.geo, run.kit
  local u, a = kit.cell, kit.arms
  local cs = sab.sizes[kit.cross.macro]
  local cc = cs and { cs.cX, cs.cY, cs.cZ } or { 0, 0, 0 }
  local ids = {}
  for idx in pairs(run.macros) do ids[#ids + 1] = idx end
  table.sort(ids)
  local centres = {}
  for _, idx in ipairs(ids) do
    local pose = run.poses[idx]
    if run.macros[idx] == kit.cross.macro and pose and axisAligned(pose.rows) and not (run.stacked and run.stackedIdx[idx]) then
      local c = geo.rotate(cc, pose.rows)
      centres[#centres + 1] = { idx = idx, c = { pose.x + c[1], pose.y + c[2], pose.z + c[3] } }
    end
  end
  local function onLattice(p, c0)
    local r = {}
    for i = 1, 3 do
      local f = (p[i] - c0[i]) / u[i]
      r[i] = math.floor(f + 0.5)
      if math.abs(f - r[i]) * u[i] > 1 then return nil end
    end
    return r
  end
  local ref, members
  for _, A in ipairs(centres) do
    local list = {}
    for _, B in ipairs(centres) do
      local r = onLattice(B.c, A.c)
      if r then list[#list + 1] = { idx = B.idx, r = r } end
    end
    if not members or #list > #members then ref, members = A, list end
  end
  if not members then
    sab.Debug("grid: no %s on the plan, the upgrade packs without the grid", kit.cross.macro)
    return false
  end
  local c0 = ref.c
  -- modules, ports and zones count from where the arms meet (the cross's origin), as poses() does
  local p0 = run.poses[ref.idx]
  local o0 = { p0.x, p0.y, p0.z }
  local byEntry = {}
  for _, f in ipairs(run.conns) do
    byEntry[f.entryIdx] = byEntry[f.entryIdx] or {}
    table.insert(byEntry[f.entryIdx], f)
  end
  local S = { c0 = c0, o0 = o0, cc = cc, crosses = {}, entries = {}, lo = { math.huge, math.huge, math.huge }, hi = { -math.huge, -math.huge, -math.huge } }
  local attach, cells = 0, {}
  local function block(lo, hi)
    for x = lo[1], hi[1] do
      for y = lo[2], hi[2] do
        for z = lo[3], hi[3] do
          cells[x .. "," .. y .. "," .. z] = true
          local n = { x, y, z }
          for i = 1, 3 do
            if n[i] < S.lo[i] then S.lo[i] = n[i] end
            if n[i] > S.hi[i] then S.hi[i] = n[i] end
          end
        end
      end
    end
  end
  local lattice = {}
  for _, m in ipairs(members) do
    lattice[m.idx] = true
    local X = { idx = m.idx, macro = kit.cross.macro, r = m.r, armNames = {}, used = {} }
    for _, f in ipairs(byEntry[m.idx] or {}) do
      local di = dirIndex(f.dir)
      if di then
        X.armNames[di] = f.name
        if f.used then X.used[di] = true else attach = attach + 1 end
      end
    end
    S.crosses[#S.crosses + 1] = X
    block(m.r, m.r)
  end
  -- on a stacked station only the lattice's own part sizes the block and offers ports; the stack is an obstacle
  local ownPart = {}
  for _, m in ipairs(members) do ownPart[run.comp[m.idx] or m.idx] = true end
  for _, idx in ipairs(ids) do
    local box, pose, macro = run.boxes[idx], run.poses[idx], run.macros[idx]
    if not lattice[idx] and box and pose then
      -- docks and their approach zones are kept clear to the metre, as the dock stage keeps them
      local column = geo.column(macro)
      local lo, hi = cellRange(box, o0, u, column and 1 or nil)
      local tlo, thi = cellRange(box, o0, u, 1)
      local E = { idx = idx, macro = macro, pos = { pose.x, pose.y, pose.z }, rows = pose.rows, lo = lo, hi = hi, tlo = tlo, thi = thi, box = box, zones = run.zones[idx], ports = {}, zoneCells = {} }
      for _, z in ipairs(E.zones or {}) do
        local zlo, zhi = cellRange(z, o0, u, 1)
        E.zoneCells[#E.zoneCells + 1] = { zlo, zhi }
      end
      local own = not run.stacked or ownPart[run.comp[idx] or idx]
      for _, f in ipairs(own and byEntry[idx] or {}) do
        local di = not f.used and dirIndex(f.dir)
        local r = di and onLattice({ f.pos[1] + a[1] * f.dir[1], f.pos[2] + a[2] * f.dir[2], f.pos[3] + a[3] * f.dir[3] }, o0)
        if r then
          E.ports[#E.ports + 1] = { name = f.name, r = r, di = di }
          attach = attach + 1
        end
      end
      if own and not (column or IsMacroClass(macro, "connectionmodule")) then block(lo, hi) end
      S.entries[#S.entries + 1] = E
    end
  end
  if attach == 0 then
    sab.Debug("grid: the lattice of %d crosses has no free arm or port, the upgrade packs without the grid", #S.crosses)
    return false
  end
  S.size = { S.hi[1] - S.lo[1] + 1, S.hi[2] - S.lo[2] + 1, S.hi[3] - S.lo[3] + 1 }
  S.cells = 0
  for _ in pairs(cells) do S.cells = S.cells + 1 end
  sab.Debug("grid: upgrade on the lattice of %d of %d crosses, %d other entries, block %d x %d x %d cells, %d attach points",
    #S.crosses, #centres, #S.entries, S.size[1], S.size[2], S.size[3], attach)
  run.seed = S
  return true
end

-- The plan's entries in a new grid: the block centred in the footprint on floor 0, the origin on the lattice.
local function seedGrid(g, S)
  local u = g.u
  local d = { math.floor((g.sx - S.size[1]) / 2) - S.lo[1], -S.lo[2], math.floor((g.sz - S.size[3]) / 2) - S.lo[3] }
  g.origin = { S.c0[1] - d[1] * u[1], S.c0[2] - d[2] * u[2], S.c0[3] - d[3] * u[3] }
  g.existing, g.zones = {}, {}
  for _, E in ipairs(S.crosses) do
    local X = addCross(g, { E.r[1] + d[1], E.r[2] + d[2], E.r[3] + d[3] }, { kind = "existing" })
    X.armNames = E.armNames
    for di in pairs(E.used) do X.arms[di] = true end
    g.existing[X] = { macro = E.macro, placedIdx = E.idx }
    g.root = g.root or X
  end
  -- the dock stage's frame: the root cross's origin at g.origin less its centre offset
  local shift = { S.cc[1] - g.origin[1], S.cc[2] - g.origin[2], S.cc[3] - g.origin[3] }
  local function mark(lo, hi, M)
    for x = math.max(0, lo[1] + d[1]), math.min(g.sx - 1, hi[1] + d[1]) do
      for y = math.max(0, lo[2] + d[2]), hi[2] + d[2] do
        for z = math.max(0, lo[3] + d[3]), math.min(g.sz - 1, hi[3] + d[3]) do
          local k = key(g, x, y, z)
          if not g.occ[k] then g.occ[k] = M end
          if y > g.top then g.top = y end
        end
      end
    end
  end
  for _, E in ipairs(S.entries) do
    local M = { item = { macro = E.macro, placedIdx = E.idx, emitted = true }, node = { 0, 0, 0 }, ports = {}, outPorts = {}, existing = true,
      pose = { pos = { E.pos[1] + shift[1], E.pos[2] + shift[2], E.pos[3] + shift[3] }, rows = E.rows, cells = {} } }
    -- the box in grid metres: node 0 at 0
    M.box = { min = {}, max = {} }
    for i = 1, 3 do
      M.box.min[i] = E.box.min[i] - S.o0[i] + d[i] * u[i]
      M.box.max[i] = E.box.max[i] - S.o0[i] + d[i] * u[i]
    end
    mark(E.lo, E.hi, M)
    for _, zc in ipairs(E.zoneCells) do mark(zc[1], zc[2], M) end
    local own = {}
    for _, pt in ipairs(E.ports) do
      local n = { pt.r[1] + d[1], pt.r[2] + d[2], pt.r[3] + d[3] }
      local inside = n[1] >= 0 and n[1] < g.sx and n[3] >= 0 and n[3] < g.sz and n[2] >= 0
      local list = inside and M.ports or M.outPorts
      local port = { name = pt.name, node = n, di = pt.di }
      list[#list + 1] = port
      if inside then
        local k = key(g, n[1], n[2], n[3])
        own[k] = true
        g.portAt[k] = g.portAt[k] or {}
        table.insert(g.portAt[k], port)
      end
    end
    local t0 = { E.tlo[1] + d[1], E.tlo[2] + d[2], E.tlo[3] + d[3] }
    local t1 = { E.thi[1] + d[1], E.thi[2] + d[2], E.thi[3] + d[3] }
    markTouched(g, t0, t1, own)
    markLean(g, t0, t1, { E.lo[1] + d[1], E.lo[2] + d[2], E.lo[3] + d[3] }, { E.hi[1] + d[1], E.hi[2] + d[2], E.hi[3] + d[3] }, M)
    for _, z in ipairs(E.zones or {}) do g.zones[#g.zones + 1] = shifted(z, shift) end
    g.modules[#g.modules + 1] = M
  end
  g.existingCrosses = #S.crosses
  g.free = S.size[2] - 1
end

-- One layout of every module at the current weights; seed: the plan's entries (grid.Seed).
---@async
local function layout(kit, base, sx, sz, tallest, progress, seed)
  local g = { u = kit.cell, a = kit.arms, sx = sx, sz = sz, tallest = tallest, occ = {},
    crosses = {}, modules = {}, touched = {}, lean = {}, portAt = {}, top = 0, floor = 0, free = 0, work = 0, frames = 0, newCrosses = 0, maxPath = MAX_PATH, banned = 0, failed = {} }
  if seed then seedGrid(g, seed) end
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
  g.connectors = crosses - g.saved - (g.existingCrosses or 0)
  -- the used box, in cells
  local lo, hi, modCells = { math.huge, math.huge, math.huge }, { -1, -1, -1 }, 0
  for k in pairs(g.occ) do
    local c = { k % g.sx, math.floor(k / (g.sx * g.sz)), math.floor(k / g.sx) % g.sz }
    for i = 1, 3 do
      if c[i] < lo[i] then lo[i] = c[i] end
      if c[i] > hi[i] then hi[i] = c[i] end
    end
  end
  for _, M in ipairs(g.modules) do modCells = modCells + #M.pose.cells end
  g.used = { hi[1] - lo[1] + 1, hi[2] - lo[2] + 1, hi[3] - lo[3] + 1 }
  g.box = g.used[1] * g.used[2] * g.used[3]
  g.cost = W_COST
  sab.Debug("grid: footprint %d x %d, cost %g: %d placed, %d failed, connectors %d (%d crosses, %d saved by struts), used %.1f x %.1f x %.1f km, module cells %.0f%%, %d placements refused for closing the way up, %d frames",
    g.sx, g.sz, W_COST, #g.modules, #g.failed, g.connectors, crosses, g.saved, g.used[1] * g.u[1] / 1000, g.used[2] * g.u[2] / 1000, g.used[3] * g.u[3] / 1000,
    100 * modCells / g.box, g.banned, g.frames)
  return g
end

-- Fewest failed modules, then fewest connectors, then the smallest box.
local function better(a, b)
  if not b then return true end
  if #a.failed ~= #b.failed then return #a.failed < #b.failed end
  if a.connectors ~= b.connectors then return a.connectors < b.connectors end
  return a.box < b.box
end

-- the editor's largest snap radius: a free drop nearer to a free connection snaps onto it
local SNAP_REACH = 2000
local AXIS_NAMES = { "x", "y", "z" }

-- A detached layout moves out along an axis from the station: its bodies a cell off the station's and clear of
-- its approach zones, its free root out of snap reach, its own zones clear of the station; the side growing the
-- plot least wins.
---@async
local function detach(g, D, run)
  local u, cap = g.u, sab.maxPlotKm * 1000
  local st, zones, seen = nil, {}, {}
  for _, b in pairs(run.boxes) do st = st and union(st, b) or b end
  for _, list in pairs(run.zones) do
    for _, z in ipairs(list) do
      local k = string.format("%.0f %.0f %.0f %.0f %.0f %.0f", z.min[1], z.min[2], z.min[3], z.max[1], z.max[2], z.max[3])
      if not seen[k] then
        seen[k] = true
        zones[#zones + 1] = z
      end
    end
  end
  if not st then return true end
  local keep = { min = { st.min[1] - u[1], st.min[2] - u[2], st.min[3] - u[3] }, max = { st.max[1] + u[1], st.max[2] + u[2], st.max[3] + u[3] } }
  local R = SNAP_REACH
  local reach = { min = { st.min[1] - R, st.min[2] - R, st.min[3] - R }, max = { st.max[1] + R, st.max[2] + R, st.max[3] + R } }
  local n = g.root and g.root.node
  local root = g.rootPier and g.rootPier.body or n and shifted(D.crossBox, { n[1] * u[1], n[2] * u[2], n[3] * u[3] })
  local bodies, L = {}, nil
  for _, list in ipairs({ D.solid, D.bodies }) do
    for _, b in ipairs(list) do
      bodies[#bodies + 1] = b
      L = L and union(L, b) or b
    end
  end
  ---@async
  local function clear(o)
    work(g, #bodies * (#zones + 1) + #D.zones)
    if root and hit(shifted(root, o), reach) then return false, "the root in snap reach" end
    for _, b in ipairs(bodies) do
      local s = shifted(b, o)
      if hit(s, keep) then return false, "a body at the station" end
      for _, z in ipairs(zones) do if nearZone(s, z) then return false, "a body in a station zone" end end
    end
    for _, z in ipairs(D.zones) do if hit(shifted(z, o), keep) then return false, "an own zone at the station" end end
    return true
  end
  local base = {}
  for i = 1, 3 do base[i] = (st.min[i] + st.max[i]) / 2 - (L.min[i] + L.max[i]) / 2 end
  local best
  -- below or above: clear of approach lanes that block every side
  for _, side in ipairs({ { 1, 1 }, { 1, -1 }, { 3, 1 }, { 3, -1 }, { 2, -1 }, { 2, 1 } }) do
    local i, s = side[1], side[2]
    -- from the boxes just apart on the axis, outward until clear
    local t = (L.max[i] - L.min[i] + keep.max[i] - keep.min[i]) / 2
    local o = { base[1], base[2], base[3] }
    o[i] = base[i] + s * t
    local ok, why = clear(o)
    while t <= cap and not ok do
      t = t + u[i] / 4
      o[i] = base[i] + s * t
      ok, why = clear(o)
    end
    if t > cap then
      sab.Debug("grid: detached layout %s%s blocked up to the plot cap: %s", s > 0 and "+" or "-", AXIS_NAMES[i], why)
    else
      local f = sab.PlotFaces(union(st, shifted(L, o)))
      local km3 = f.uncapped[1] * f.uncapped[2] * f.uncapped[3]
      local fits = f.uncapped[1] <= sab.maxPlotKm and f.uncapped[2] <= sab.maxPlotKm and f.uncapped[3] <= sab.maxPlotKm
      if not best or (fits and not best.fits) or (fits == best.fits and km3 < best.km3) then
        best = { o = o, km3 = km3, fits = fits, axis = i, side = s, t = t }
      end
    end
  end
  if not best then return false end
  local delta = { best.o[1] - D.shift[1], best.o[2] - D.shift[2], best.o[3] - D.shift[3] }
  for i = 1, 3 do
    g.origin[i] = g.origin[i] + delta[i]
    D.shift[i] = best.o[i]
  end
  for _, it in ipairs(run.items) do
    if it.free and it.pos then it.pos = { x = it.pos.x + delta[1], y = it.pos.y + delta[2], z = it.pos.z + delta[3] } end
  end
  sab.Debug("grid: detached layout %s%s, %.1f km off the station's centre, plot %d km3", best.side > 0 and "+" or "-",
    AXIS_NAMES[best.axis], best.t / 1000, best.km3)
  return true
end

-- Packs once per new-cross cost in grid.costs and keeps the best layout.
---@async
local function pack(run)
  local kit = run.kit
  local probe = { u = kit.cell, a = kit.arms }
  local base, cells, spanXZ, tallest, byMacro = {}, 0, 1, 1, {}
  for _, it in ipairs(run.items) do
    it.gridRec = nil
    if not it.isConnector and not it.column and not IsMacroClass(it.macro, "buildmodule") then
      local m = byMacro[it.macro]
      if not m then
        local ps, minCells, minSpan = poses(probe, it.macro), math.huge, math.huge
        for _, p in ipairs(ps) do
          local v = #p.cells
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
  local S = run.seed
  local s, minSide = math.ceil((cells * FILL + (S and S.cells or 0)) ^ (1 / 3)), spanXZ + 2
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
        local sx = math.max(minSide, math.floor(side * math.sqrt(ratio) + 0.5), S and S.size[1] or 0)
        local sz = math.max(minSide, math.floor(side / math.sqrt(ratio) + 0.5), S and S.size[3] or 0)
        if not seen[sx .. "x" .. sz] then
          seen[sx .. "x" .. sz] = true
          shapes[#shapes + 1] = { sx, sz }
        end
      end
    end
  end
  local costs = grid.costs or { W_COST }
  sab.Debug("grid: cell %.0f x %.0f x %.0f m, estimated footprint %d x %d cells, %d footprints, %d modules, %.0f module cells", probe.u[1], probe.u[2], probe.u[3], s, s, #shapes, #base, cells)
  -- the layouts with the fewest failed modules
  local cands = {}
  local frames, packs, wCost = 0, 0, W_COST
  local centre = C.GetBuildPlotCenterOffset(sab.menu.container)
  run.packProgress = { pack = 0, packs = #shapes * #costs, module = 0, modules = #base }
  for _, shape in ipairs(shapes) do
    for _, cost in ipairs(costs) do
      W_COST = cost
      run.packProgress.pack = packs + 1
      local g = layout(kit, base, shape[1], shape[2], tallest, run.packProgress, S)
      frames, packs = frames + g.frames, packs + 1
      -- a seeded grid keeps the lattice's origin
      if not S then
        local H = g.top + 1
        g.origin = { centre.x - (g.sx - 1) * g.u[1] / 2, centre.y - (H - 1) * g.u[2] / 2, centre.z - (g.sz - 1) * g.u[3] / 2 }
      end
      if not cands[1] or #g.failed < #cands[1].failed then
        cands = { g }
      elseif #g.failed == #cands[1].failed then
        cands[#cands + 1] = g
      end
    end
  end
  W_COST = wCost
  -- best first, each with its docks until one hangs every dock: fewest docks without a place, then fewest free
  table.sort(cands, better)
  ---@type table
  local g
  ---@type table
  local D
  for _, c in ipairs(cands) do
    local cD = docks(c, run)
    if not g or c.dockFailed < g.dockFailed or (c.dockFailed == g.dockFailed and c.dockFree < g.dockFree) then g, D = c, cD end
    if c.dockFailed == 0 and c.dockFree == 0 then break end
  end
  grid.lastDocks = D
  for _, M in ipairs(g.modules) do M.item.gridRec = M end
  if run.detached and not detach(g, D, run) then error("no side of the stacked station keeps the layout clear within the plot cap", 0) end
  applyDocks(g, D)
  local box = layoutBox(D)
  -- per axis, a shift under half a km that puts the layout's low face on a whole km when that saves a plot km
  if box and not S and not run.detached then
    local shift = {}
    for i = 1, 3 do shift[i] = -1000 * math.floor(-box.min[i] / 1000 + 0.5) - box.min[i] end
    local alt = shifted(box, shift)
    local f0, f1 = sab.PlotFaces(box), sab.PlotFaces(alt)
    for i = 1, 3 do
      if f1.uncapped[i] < f0.uncapped[i] then
        g.origin[i] = g.origin[i] + shift[i]
        box.min[i], box.max[i] = alt.min[i], alt.max[i]
        for it in pairs(g.dockOut or {}) do
          if it.free and it.pos then it.pos[AXIS_NAMES[i]] = it.pos[AXIS_NAMES[i]] + shift[i] end
        end
        sab.Debug("grid: shifted %.0f m on axis %d to save a plot km", shift[i], i)
      end
    end
  end
  run.plotBox = box
  sab.Debug("grid: kept footprint %d x %d, cost %g: %d modules, %d failed, %d connectors, %.1f x %.1f x %.1f km, %d frames for %d packs",
    g.sx, g.sz, g.cost, #g.modules, #g.failed, g.connectors, g.used[1] * g.u[1] / 1000, g.used[2] * g.u[2] / 1000, g.used[3] * g.u[3] / 1000, frames, packs)
  run.grid = g
  grid.last = g
  run.items = emit(g, run)
  run.next = 1
end

-- Pack in the background, one budget of checks per frame.
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
