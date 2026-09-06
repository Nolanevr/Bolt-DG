-- ============================================================================
-- pathing.lua -- "which door should I open next?" for a FULL CLEAR.
-- ============================================================================
-- Loaded with  local pathing = require("pathing")({ ... deps ... })
--
-- DEPENDENCIES ARE INJECTED, NEVER READ FROM GLOBALS, for the reason parity.lua
-- gives: test/spec.py loads THIS SHIPPED FILE with stubs rather than slicing
-- text out of main.lua by string markers.
--
-- WHAT THIS IS FOR. The parity engine answers "which rooms are on the critical
-- path" -- the question you ask when rushing a boss. This answers a different
-- one: you intend to open EVERY room, so WHICH rooms is settled and only the
-- ORDER is open. Order still matters, because backtracking is the whole cost of
-- a full clear, and because some doors cannot be opened yet.
--
-- WHAT THE FLOOR GUARANTEES. The room graph is a TREE -- acyclic, one path from
-- base to anywhere (parity.lua depends on the same fact). Two consequences the
-- scoring leans on:
--   * everything behind a door is a SUBTREE: opening it is the only way to
--     reach any of it, so "how much is back there" is a real quantity;
--   * an undiscovered region of the grid lies behind EXACTLY ONE frontier door,
--     even when several sit next to it -- which is what makes the expected-value
--     split in reach_of sound rather than arbitrary.
--
-- WHY NOT PARITY. Crit/bonus deliberately does not feed the score. On a full
-- clear the room set is fixed, so parity cannot change what you must open, and
-- its one predictive use -- crit rooms tend to lead onward -- is measured here
-- directly and better, as reach. A parity term would look principled and decide
-- nothing.
return function (deps)
local cell_doors = deps.cell_doors
local key_lower  = deps.key_lower
local NEI_DELTA  = deps.NEI_DELTA
local NEI_OPP    = deps.NEI_OPP

local P = {}

-- ---- scoring weights (points) ----------------------------------------------
local W_STEP      = -18   -- per room walked, INCLUDING any key detour
local W_REACH     =   7   -- per sqrt(room) of expected territory behind the door
local W_KEY_SPEND =  30   -- a lock you are already carrying the key for
local W_GUARDIAN  = -45   -- costs a guardian fight
local W_SKILL     = -20   -- skill door: may want a level, resources, or a detour
local W_QUESTION  =  -6   -- "?" room: contents unknown, mild tiebreak against

-- Reach enters as a SQUARE ROOT, and at a deliberately small weight, because on
-- a full clear it is a TIE-BREAKER and not a driver. You open every room
-- eventually, so a big region behind a door buys information and an earlier
-- frontier, not extra rooms -- and both saturate hard: 1 -> 5 rooms behind a
-- door is a large difference, 30 -> 35 is not.
--
-- Weighted to be worth about two rooms of walking across its WHOLE range
-- (sqrt spans roughly 1..7.5 on an 8x8 floor, so ~45 points against W_STEP's
-- 18/room). Nearest-first is close to optimal for a completionist sweep -- it
-- is a greedy TSP -- so reach must separate doors of similar cost without ever
-- marching you past a cheap one. Tuned against exactly that: a sealed dead end
-- two rooms away still beats half the floor six rooms away, because you have to
-- come back for the dead end either way and passing it twice is pure loss.
local function reach_score(n) return math.sqrt(n) end

P.W = { step = W_STEP, reach = W_REACH, key_spend = W_KEY_SPEND,
        guardian = W_GUARDIAN, skill = W_SKILL, question = W_QUESTION }

local function ck(gx, gz) return gx .. "," .. gz end

local function is_unopened(cell)
  for _, nm in ipairs(cell.images) do
    if nm:sub(1, 9) == "UNOPENED_" then return true end
  end
  return false
end

-- The key this unopened room's door wants, plus its other gates.
local function gate_of(cell)
  local keyname, skill, question = nil, false, false
  for _, nm in ipairs(cell.images) do
    if nm:sub(1, 5) == "DOOR_" then skill = true
    elseif nm:find("_QUESTION", 1, true) then question = true
    else
      local k = key_lower(nm)
      if k then keyname = k end
    end
  end
  return keyname, skill, question
end

-- BFS over OPENED rooms only, requiring both sides to declare the door: a
-- one-sided door is a map artefact, not a way through. Returns steps-from-src.
local function walk(opened, src)
  local dist = { [src] = 0 }
  if not opened[src] then return dist end
  local queue, head = { src }, 1
  while head <= #queue do
    local k = queue[head]; head = head + 1
    local cell = opened[k]
    for dir in pairs(cell_doors(cell)) do
      local d = NEI_DELTA[dir]
      local nk = ck(cell.gx + d[1], cell.gz + d[2])
      local nb = opened[nk]
      if nb and dist[nk] == nil and cell_doors(nb)[NEI_OPP[dir]] then
        dist[nk] = dist[k] + 1
        queue[#queue + 1] = nk
      end
    end
  end
  return dist
end

-- Expected rooms behind each unopened room.
--
-- Flood the blank in-bounds cells into connected regions, then hand each region
-- out to the unopened rooms touching it. Because the floor is a tree the region
-- really lies behind exactly ONE of them, we just cannot see which -- so each
-- toucher is credited size/touchers, the expected value, rather than the full
-- size. Crediting every toucher in full (which the parity engine does on
-- purpose, because over-counting only makes ITS rule fire less often) would
-- rank a door onto a big SHARED region above one that privately owns a smaller
-- one, which is backwards.
--
-- This replaces a count of blank NEIGHBOURS (0..3), which could not tell a door
-- onto a one-cell pocket from a door onto half the floor.
local function reach_of(rooms)
  local region_of, region_size, nreg = {}, {}, 0
  for gx = 0, 7 do
    for gz = 0, 7 do
      local k = ck(gx, gz)
      if not rooms[k] and not region_of[k] then
        nreg = nreg + 1
        local stack, n = { k }, 0
        region_of[k] = nreg
        while #stack > 0 do
          local cur = table.remove(stack)
          n = n + 1
          local sx, sz = cur:match("^(%-?%d+),(%-?%d+)$")
          sx, sz = tonumber(sx), tonumber(sz)
          for _, d in pairs(NEI_DELTA) do
            local ax, az = sx + d[1], sz + d[2]
            local nk = ck(ax, az)
            if ax >= 0 and ax <= 7 and az >= 0 and az <= 7
               and not rooms[nk] and not region_of[nk] then
              region_of[nk] = nreg
              stack[#stack + 1] = nk
            end
          end
        end
        region_size[nreg] = n
      end
    end
  end
  local touchers, touched = {}, {}
  for k, cell in pairs(rooms) do
    if is_unopened(cell) then
      local hit = {}
      for _, d in pairs(NEI_DELTA) do
        local id = region_of[ck(cell.gx + d[1], cell.gz + d[2])]
        if id then hit[id] = true end
      end
      touched[k] = hit
      for id in pairs(hit) do touchers[id] = (touchers[id] or 0) + 1 end
    end
  end
  local reach = {}
  for k, hit in pairs(touched) do
    local n = 1                              -- the room itself
    for id in pairs(hit) do n = n + region_size[id] / touchers[id] end
    reach[k] = n
  end
  return reach
end

-- P.rank(model) -> candidates, best-first.
--
-- model = {
--   rooms            = rooms_by_cell,          -- "gx,gz" -> { gx, gz, images }
--   start            = "gx,gz",                -- the player's cell
--   held             = { [keyname] = true },   -- keys in the bag right now
--   keys             = { [keyname] = { found = ck|nil, lock = ck|nil } },
--   guardian_targets = { ["gx,gz"] = true },
-- }
--
-- Each candidate: { from, dir, to, score, steps, detour, reach, blocked,
-- keyname, key_state, skill, question, guardian }.
--
-- KEY STATES, and why there are three rather than two. A door wanting a key you
-- are not carrying is not automatically a dead end:
--   "held"    you can open it where you stand.
--   "found"   the key has been SEEN on the ground in explored space, so it is
--             fetchable at will -- the door costs a DETOUR, not a refusal.
--             parity.lua's openable() has always treated found keys this way;
--             this module used to disagree with it and call them blocked, which
--             hid every door whose key was lying a couple of rooms back.
--   nil       never seen. Genuinely blocked; never recommended.
-- The detour is priced as a real route -- walk to the key, then on to the door,
-- less the direct walk you would have made anyway -- and folded into steps, so
-- a fetchable door competes on cost instead of being tiered out of contention.
P.rank = function (model)
  local rooms = model.rooms or {}
  local held  = model.held or {}
  local keys  = model.keys or {}
  local guard = model.guardian_targets or {}
  local out   = {}
  if not model.start or not rooms[model.start] then return out end

  local opened = {}
  for k, cell in pairs(rooms) do
    if not is_unopened(cell) then opened[k] = cell end
  end
  if not opened[model.start] then return out end

  local dist  = walk(opened, model.start)
  local reach = reach_of(rooms)
  local from_key = {}                        -- memoised BFS from each key's cell

  for k, steps in pairs(dist) do
    local cell = opened[k]
    for dir in pairs(cell_doors(cell)) do
      local d = NEI_DELTA[dir]
      local nk = ck(cell.gx + d[1], cell.gz + d[2])
      local u = rooms[nk]
      if u and is_unopened(u) then
        local keyname, skill, question = gate_of(u)
        local key_state, blocked, detour = nil, nil, 0
        if keyname then
          if held[keyname] then
            key_state = "held"
          else
            local info = keys[keyname]
            local found = info and info.found
            -- "found" has to mean FETCHABLE, not merely recorded: a pickup cell
            -- we cannot walk to buys nothing.
            if found and opened[found] then
              if not from_key[found] then from_key[found] = walk(opened, found) end
              local back, togo = from_key[found][k], dist[found]
              if back ~= nil and togo ~= nil then
                key_state = "found"
                detour = math.max(0, (togo + back) - steps)
              else
                blocked = "key"
              end
            else
              blocked = "key"
            end
          end
        end
        local guardian = guard[nk] == true
        local eff = steps + detour
        local score = eff * W_STEP
                    + reach_score(reach[nk] or 1) * W_REACH
                    + ((key_state == "held") and W_KEY_SPEND or 0)
                    + (guardian and W_GUARDIAN or 0)
                    + (skill and W_SKILL or 0)
                    + (question and W_QUESTION or 0)
        out[#out + 1] = {
          from = k, dir = dir, to = nk, score = score, steps = steps,
          detour = detour, reach = reach[nk] or 1, blocked = blocked,
          keyname = keyname, key_state = key_state, skill = skill,
          question = question, guardian = guardian,
        }
      end
    end
  end

  -- Openable first, then score, then nearer, then a stable name order: a
  -- flashing marker that hops between two equally good doors frame to frame is
  -- worse than no marker, so ties must resolve the same way every time.
  table.sort(out, function (a, b)
    local ab, bb = a.blocked ~= nil, b.blocked ~= nil
    if ab ~= bb then return bb end
    if a.score ~= b.score then return a.score > b.score end
    local ae, be = a.steps + a.detour, b.steps + b.detour
    if ae ~= be then return ae < be end
    if a.to ~= b.to then return a.to < b.to end
    return a.dir < b.dir
  end)
  return out
end

-- The one door to point at: best candidate that is not blocked, or nil if every
-- frontier door wants a key nobody has seen. Never returns a blocked door --
-- "go here" has to mean you can.
P.best = function (model)
  local ranked = P.rank(model)
  for _, c in ipairs(ranked) do
    if not c.blocked then return c, ranked end
  end
  return nil, ranked
end

return P
end
