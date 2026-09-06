# DG Map Tracker

Bolt plugin for RuneScape 3 Dungeoneering. Watches the game's minimap
icons, tile geometry, and world position each frame and builds a live
room-graph of the current floor. Shows a compact map panel with room
parity (critical / bonus / unknown), key ownership, connecting
corridors, and skill-door tiers. A keys panel tracks every key spawn
seen on the floor and where its matching door is. In-world overlays
highlight resources, ground keys, door-adjacent tiles, and puzzle
ghosts, and a line-draw feature points at tracked keys.

Settings live in a built-in panel: the draggable CTRL button opens it.

## Capture zones

The plugin reads three screen regions, shown as draggable labeled
boxes when "Show capture zones" is on (default on for new installs):

- **MAP** (red) -- the DG map interface.
- **KEYBAG** (blue) -- the key inventory.
- **WORLD MAP** (green) -- the floor icon area.

Align each once; positions persist in config.

## What ships in `data/`

Canonical / seed data bundled with the plugin. On first run the plugin
seeds the user's config dir from these files; subsequent user
modifications live in config and are never overwritten by plugin
updates.

| File                  | Purpose                                              |
|-----------------------|------------------------------------------------------|
| `icons_data.txt`      | Mesh rasterization catalog for classified 3D icons   |
| `img_signatures.txt`  | 2D image signatures for room-body / door / passage icons |
| `mm_signatures.txt`   | Minimap signature name list (for classifier UX)      |
| `shape_rot.txt`       | Default per-shape camera calibration for icon render |
| `skill_doors.txt`     | Skill-door tier lookup (crit / bonus / unresolvable) |
| `resource_types.txt`  | Max resource tier per skill                          |
| `resources.txt`       | 3D resource fingerprint catalog (v1 + v2 prints)     |
| `guardian_doors.txt`, `ghosts.txt`, `dino_colors.txt` | Guardian-door / puzzle-ghost / dino-tier catalogs |
| `icons.txt`, `img_ignored.txt`, `resource_ignored.txt`, etc. | Starter curated lists |

## Configuration

Every runtime setting lives in one flat JSON file -- `settings.json` --
inside this plugin's config dir
(`%APPDATA%\bolt-launcher\config\plugins\<uuid>\`). Use the settings
panel rather than editing it by hand; it covers party sync, map size,
scan range, the capture-zone toggle, and per-panel visibility. Panel
positions and the capture-zone rectangles save themselves when dragged.

Runtime catalog data stays in its own files (`icons.txt`,
`img_signatures.txt`, `resources.txt`, `img_ignored.txt`, etc.) --
those are large / append-heavy and don't fit the flat-JSON shape.

## Guardian doors

Guardian doors are recognised from a 3D-mesh fingerprint
(`guardian_doors.txt`, one print per floor type) and painted magenta,
with a second red outline on every other door of the same room until
the `?` room behind them is opened. In-world, a recognised guardian door's
floor tiles are filled and outlined magenta, overriding the parity and
key-door colouring for that door.

**RuneScape's own entity highlighting can be left on.** The border pass
repaints a highlighted door's vertex colours -- and when the border
clips through the door it can hand the plugin the border's inflated
copy of the mesh instead of the door itself -- which used to push the
door past a colour-equality test and leave it unread. Matching now
leads with geometry and lets colour corroborate, in three tiers:

| Tier | Accepts when | Covers |
|------|--------------|--------|
| `exact` | the original strict position + colour test | an unhighlighted door |
| `tinted` | geometry matches under one uniform scale, and colours match up to a per-channel gain + offset | border tint, lighting drift, an inflated outline copy |
| `flooded` | geometry matches tightly and the border has left no colour signal at all | a door washed flat or saturated by the highlight |

The two tolerant tiers give up some colour evidence, so a hit from
either must be seen on two separate frames at the same tile before it
sticks; an `exact` hit still binds on sight. Detection also runs every
frame and is not culled by the resource scan range -- a guardian door
is room structure, not scenery you walk up to.

## Camera FOV cone

The white wedge on the map panel shows which way the camera is facing. It is a
compass bearing pushed from Lua (0 = north, 90 = east); when no bearing has
arrived yet the map draws **no cone at all** rather than one pointing north,
because 0 is a real direction and a confident wrong answer is worse than none.

**Camera FOV cone** in the settings panel (default on) turns it off. Off also
stops the per-frame angle push and the repaints it triggers, so it is a real
cost saving and not just a visual one -- see Map render cost below.

## Next-door hint

With **Next-door hint** on (settings panel, default on), the frontier door the
plugin thinks you should open next gets a pulsing cyan ring in-world, drawn
*outside* the door's normal parity/key colouring so it adds an answer rather
than replacing one.

The ranking (`pathing.lua`) is built for **clearing a whole floor**, not for
rushing the boss -- which rooms you open is settled, only the order is open, so
it scores:

| Term | Points | Why |
|------|--------|-----|
| rooms walked, **including any key detour** | -18 each | backtracking is the whole cost of a full clear |
| `sqrt(expected rooms behind the door)` | +7 each | how much map it can reveal |
| lock whose key is in your bag | +30 | spend the key while you are standing there |
| guardian door | -45 | costs a fight |
| skill door | -20 | may want a level, resources, or a detour |
| `?` room | -6 | contents unknown |

**Reach** is how much territory is actually behind a door. The blank in-bounds
cells are flooded into connected regions and each region is handed to the
unopened rooms touching it -- and because the floor graph is a *tree*, a region
lies behind exactly ONE of them even when several sit beside it, so each toucher
is credited `size / touchers`: the expected value, not the full size. Crediting
every toucher in full would rank a door onto a big *shared* region above one
that privately owns a smaller one, which is backwards.

It enters as a square root at a small weight because on a full clear it is a
**tie-breaker, not a driver**: you open everything eventually, so a big region
buys information and an earlier frontier rather than extra rooms, and that
saturates fast. Nearest-first is close to optimal for a completionist sweep, so
reach separates doors of similar cost without marching you past a cheap one -- a
sealed dead end two rooms away still beats half the floor six rooms away,
because you must come back for it either way.

**Keys have three states, not two:**

| State | Meaning |
|---|---|
| `held` | in your bag -- open it where you stand, and it scores `+30` |
| `found` | seen on the ground in explored space, so fetchable at will: the door costs a **detour** (walk to the key, then to the door, less the direct walk), folded into the distance term so it competes on cost |
| *unseen* | genuinely blocked; ranked and flagged, but never the recommendation |

That middle state is the one that changed. The scorer used to call any door
whose key you weren't carrying "blocked", which hid every door whose key was
lying two rooms back -- and disagreed with the parity engine, whose `openable()`
has always treated a found key as fetchable.

**Picking a key up re-ranks immediately.** The hint normally recomputes at 4 Hz,
but a change to the keybag kicks it that frame, so the marker moves the moment
you grab a key rather than up to 250 ms later.

Crit/bonus deliberately does **not** feed the score. On a full clear the room set
is fixed, so parity cannot change what you must open, and its one predictive use
-- crit rooms tend to lead onward -- is measured directly and better as reach.

With dev tools on, `pathing_diag.txt` lists the top frontier doors with their
score breakdown, so the marker can be audited rather than trusted.

## Map render cost

The map is rendered in an off-DOM canvas and the whole surface is exported to
Lua on every repaint, so repaint cost is the map's latency. Two numbers worth
knowing if you touch that path (measured in headless Chromium, 17-room floor):

| | before | after |
|---|---|---|
| repaint (drives the FOV cone) | 75 ms -> ~13/s | 2.2 ms -> capped 30/s |
| room opens -> pixels exported | 76 ms | 7 ms |

Both had the same cause: icon shadows were drawn under `ctx.filter:
drop-shadow(...)`. *Setting* a canvas filter is free; *drawing* beneath one
costs ~20 ms per icon, and the bill arrives at the next `getImageData` -- so
the export, not the drawing, appeared to be slow. `ctx.shadow*` is the same
effect about 290x cheaper.

Angle-only repaints are coalesced to one per animation frame and capped
(`FAST_MIN_MS`, 33 ms). The cap is about bandwidth, not drawing: every repaint
ships the entire surface, which is 0.56 MB at the default map size and 2.2 MB
at a large map on a HiDPI screen, so an uncapped cone is a ~130 MB/s stream of
pixels for motion that reads as smooth at 30 Hz.

On the Lua side the room graph is rebuilt every frame but pushed to the panel
on a 4 Hz dump; a change to the graph (a room opening, a key icon appearing)
now kicks that push in the same frame, so opening a room no longer costs up to
250 ms of staleness.

## Diagnostics

Always on. The plugin writes state files into its config dir
(`draw_dbg.txt`, `floor_diag.txt`, `obs_diag.txt`, `parity_dump.txt`,
`rooms.txt`, queue snapshots, and per-floor death reports). These are
the first place to look when something silently stops tracking --
`draw_dbg.txt`'s `floor_gate:` / `gates:` / `anchor=` lines in
particular.

With dev tools on, `guardian_diag.txt` logs each guardian door as it
binds (with the tier and score that bound it) and one `MISS` line per
vertexcount that reached the matcher and failed -- the score on that
line says how far off the print it was. `pathing_diag.txt` carries the
scored frontier-door ranking behind the next-door hint.

## Panels

- **Rooms panel** -- the floor grid. Tile colour = parity (tan crit,
  near-black bonus / unknown, yellow = crit with key held, red = floor
  dead); corridors drawn between connected rooms; door icons show the
  key or skill required.
- **Keys panel** -- every colour x shape key. Cell parity border,
  found / lock coordinates if seen, dim if unseen.
- **Line Draw panel** -- toggles the in-world line to tracked ground
  keys, colour / opacity / thickness, grid-aligned routing.
- **Image Tracker / Resources / Icons panels** -- cataloguing tools,
  hidden behind Show Dev Tools in the settings panel.
