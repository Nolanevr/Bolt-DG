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
-- path" -- the question you ask when you are rushing a boss. This answers a
-- different one: you intend to open EVERY room, so WHICH rooms is settled and
-- only the ORDER is open. Order still matters, for three reasons:
--
--   1. Backtracking is the whole cost. Walking past a branch and coming back
--      for it later is the biggest time sink in a full clear, so a near-first
--      sweep beats a depth-first plunge.
--   2. Some frontier doors are not openable yet -- a key you have not found, a
--      skill door you may not pass, a guardian that wants a fight. Pointing you
--      at one of those is worse than pointing nowhere.
--   3. Rooms differ in how much they REVEAL. A room whose neighbours are all
--      already on your map can only ever be itself; a room with three blank
--      neighbours may open a whole wing. Learning the map early is what lets
--      you plan the rest of the sweep, so revealing rooms are worth a detour --
--      but only a small one.
--
-- WHAT "PATHING PROBABILITY" CAN HONESTLY MEAN HERE. We never see an unopened
-- room's doors; the map only says which side we would enter from. But we do
-- know which of its four grid neighbours are still blank, and a room can only
-- lead somewhere new through a blank one. So `expansion` -- blank on-grid
-- neighbours, 0..3 -- is a hard upper bound on how much new map the room can
-- reveal, and 0 means a GUARANTEED dead end rather than a guess. That is the
-- strongest claim available without opening the door, and it is what the
-- scoring uses. It is deliberately not dressed up as a probability.
--
-- The weights are the tunable part, named and in points, so a ranking can be
-- read as arithmetic instead of taken on faith.
return function (deps)
local cell_doors = deps.cell_doors
local key_lower  = deps.key_lower
local NEI_DELTA  = deps.NEI_DELTA
local NEI_OPP    = deps.NEI_OPP

local P = {}

-- ---- scoring weights (points) ----------------------------------------------
-- Distance dominates by design: on a floor you intend to clear completely the
-- cheapest next room is nearly always the right one, and the rest are
-- tie-breaks. Expansion can pull you at most about two rooms out of your way
-- (3 * W_EXPANSION / -W_STEP), roughly what a wing's worth of new map is worth.
local W_STEP      = -18   -- per room walked to reach the door
local W_EXPANSION =  22   -- per blank neighbour the room could open into (0..3)
local W_KEY_SPEND =  30   -- a lock you are carrying the key for: spend it while you are here
local W_GUARDIAN  = -45   -- costs a guardian fight
local W_SKILL     = -20   -- skill door: may want a level, resources, or a detour
local W_QUESTION  =  -6   -- "?" room: contents unknown, mild tiebreak against
-- A dead end (expansion 0) takes no penalty beyond scoring no expansion: on a
-- full clear you still have to open it, and if it is the nearest thing left it
-- genuinely IS the right next door.

P.W = { step = W_STEP, expansion = W_EXPANSION, key_spend = W_KEY_SPEND,
        guardian = W_GUARDIAN, skill = W_SKILL, question = W_QUESTION }

local function ck(gx, gz) return gx .. "," .. gz end

local function is_unopened(cell)
  for _, nm in ipairs(cell.images) do
    if nm:sub(1, 9) == "UNOPENED_" then return true end
  end
  return false
end

-- What stands between you and this unopened room, read off its own images.
local function gate_of(cell, held)
  local keyname, skill, question = nil, false, false
  for _, nm in ipairs(cell.images) do
    if nm:sub(1, 5) == "DOOR_" then skill = true
    elseif nm:find("_QUESTION", 1, true) then question = true
    else
      local k = key_lower(nm)
      if k then keyname = k end
    end
  end
  local blocked = nil
  if keyname and not held[keyname] then blocked = "key" end
  return keyname, skill, question, blocked
end

-- P.rank(model) -> candidates, best-first.
--
-- model = {
--   rooms            = rooms_by_cell,          -- "gx,gz" -> { gx, gz, images }
--   start            = "gx,gz",                -- the player's cell
--   held             = { [keyname] = true },   -- keys in the bag right now
--   guardian_targets = { ["gx,gz"] = true },   -- unopened cells behind a
--                                              -- detected guardian door
-- }
--
-- Each candidate: { from, dir, to, score, steps, expansion, blocked, keyname,
-- skill, question, guardian }. `blocked` non-nil means the door cannot be
-- opened right now; those are still ranked but flagged, so a caller can show
-- them differently rather than steer you into one.
P.rank = function (model)
  local rooms = model.rooms or {}
  local held  = model.held or {}
  local guard = model.guardian_targets or {}
  local out   = {}
  if not model.start or not rooms[model.start] then return out end

  -- Opened rooms only: you can only walk through what you have opened.
  local opened = {}
  for k, cell in pairs(rooms) do
    if not is_unopened(cell) then opened[k] = cell end
  end
  if not opened[model.start] then return out end

  -- BFS over the opened graph, so `steps` is rooms actually walked rather than
  -- a straight line through walls. A connection needs BOTH rooms to declare the
  -- door: a one-sided door is a map artefact, not a way through.
  local dist = { [model.start] = 0 }
  local queue, head = { model.start }, 1
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

  -- Frontier: every door from a REACHED opened room into an unopened one. A
  -- door out of a room you cannot walk to yet is not a next step.
  for k, steps in pairs(dist) do
    local cell = opened[k]
    for dir in pairs(cell_doors(cell)) do
      local d = NEI_DELTA[dir]
      local nk = ck(cell.gx + d[1], cell.gz + d[2])
      local u = rooms[nk]
      if u and is_unopened(u) then
        -- Expansion: blank on-grid neighbours of the unopened room. Anything
        -- already on the map is not new territory, whatever state it is in.
        local expansion = 0
        for _, dd in pairs(NEI_DELTA) do
          local ax, az = u.gx + dd[1], u.gz + dd[2]
          if ax >= 0 and ax <= 7 and az >= 0 and az <= 7 and not rooms[ck(ax, az)] then
            expansion = expansion + 1
          end
        end
        local keyname, skill, question, blocked = gate_of(u, held)
        local guardian = guard[nk] == true
        local score = steps * W_STEP
                    + expansion * W_EXPANSION
                    + ((keyname and not blocked) and W_KEY_SPEND or 0)
                    + (guardian and W_GUARDIAN or 0)
                    + (skill and W_SKILL or 0)
                    + (question and W_QUESTION or 0)
        out[#out + 1] = {
          from = k, dir = dir, to = nk, score = score, steps = steps,
          expansion = expansion, blocked = blocked, keyname = keyname,
          skill = skill, question = question, guardian = guardian,
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
    if a.steps ~= b.steps then return a.steps < b.steps end
    if a.to ~= b.to then return a.to < b.to end
    return a.dir < b.dir
  end)
  return out
end

-- The one door to point at: best OPENABLE candidate, or nil if every frontier
-- door is gated. Never returns a blocked door -- "go here" has to mean you can.
P.best = function (model)
  local ranked = P.rank(model)
  for _, c in ipairs(ranked) do
    if not c.blocked then return c, ranked end
  end
  return nil, ranked
end

return P
end
