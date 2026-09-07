# Bolt-DG

[Bolt-launcher](https://codeberg.org/Adamcake/Bolt) plugin for RuneScape 3 Dungeoneering.

## Features

- Automatic Guide Mode
- Key and door tracking
- Resource and ground key highlights
- Party Sync (unstable)
- Built in settings panel

## Setup

- In Bolt's plugin manager, install from URL:

  `https://raw.githubusercontent.com/nolanevr/Bolt-DG/main/meta.json`

- Drag the three capture zones for MAP, KEYBAG, and WORLD MAP over the
  in-game DG map, keybag, and world map icon respectively.
- Toggle capture zone display off from settings panel when done.
- Start a new dungeon and everything should be working.
- Render resolutions other than 100% are not supported.
- Interactable and loot drop highlights must be disabled.
- Bloom must be disabled.

## Releasing

The install URL above serves `meta.json` from the default branch; Bolt reads
the `url` in it, downloads that tarball, and checks it against the `sha256`.
So a release is two things that must agree: the asset, and the pointer to it.

Tag it and CI does both:

```
git tag v1.0-pre6 && git push origin v1.0-pre6
```

`.github/workflows/release.yml` checks the tag against
`plugins/dg-map-tracker/bolt.json`, runs the test suite, builds the tarball
with `tools/make_release.py`, publishes it as the release asset at exactly the
URL `meta.json` names, and corrects `meta.json` if the bytes disagree. Bump
`bolt.json`'s version and run `python tools/make_release.py` in the same commit
as the code, so `meta.json` lands reviewed rather than as a bot commit; the
build is byte-reproducible, so the runner rebuilding it changes nothing.

`bolt.json`'s version is also what an installed plugin reports to Bolt, so an
unbumped version means no update is ever offered, however new the asset is.

**A pointer at the wrong repo is the dangerous failure.** A stale `sha256`
fails the install loudly, but a stale `url` succeeds and silently installs a
different build. This repo shipped that for a while -- `meta.json` kept naming
the previous owner's `v1.0-pre5` tarball, so anyone installing from the README
got that build, with the map alive and half its features missing. The URL is
now derived from the `origin` remote, never typed, and `test/spec.py` fails if
`meta.json` points outside this repo or disagrees with `bolt.json`.

## Development

- Canonical / seed data lives in `data/` -- read via
  `bolt.loadfile("data/<key>")` or seeded into user config on first run.
- All runtime settings consolidate into a single `settings.json` in the
  plugin's config dir.
- The settings panel is self-contained (`settings_panel.lua` + its two HTML
  pages); rows are declared in the registry table at the top of that module.
- Diagnostics are always on; the plugin writes its state files into its
  config dir.

Plugin source lives at `plugins/dg-map-tracker/`. Bolt loads from
`%APPDATA%\bolt-launcher\data\plugins\` (see `config\plugins.json` for the
authoritative path) -- deploy by copying the plugin folder there, or use a
directory junction:
`mklink /J "%APPDATA%\bolt-launcher\data\plugins\dg-map-tracker" "<repo>\plugins\dg-map-tracker"`

Note: bolt records a plugin's install path at import time. If you switch from
a real directory to a junction, re-import from the bolt UI so it picks up the
new path.
