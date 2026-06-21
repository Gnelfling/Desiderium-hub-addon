# Desiderium

A modular GMod addon for injecting anomalous events into any map via a
hidden, fake-Valve-style server convar. Built incrementally - this README
tracks what exists, what's planned, and how the pieces connect.

## Current status: Exposure & containment online (v0.0.3)

The model changed. `sv_addendum_enable` no longer fires an anomaly the
instant you flip it. Think of it as a wound, not a switch:

- `sv_addendum_enable 1` opens the gate. A sound plays. Nothing fires yet.
- While open, **Exposure** (a single number, starts at 0) rises over time.
- A single shared tick loop (`sv_addendum_exposure.lua`) checks periodically
  whether to actually dispatch an anomaly - both how often it checks and
  how likely a check is to fire scale up as Exposure rises. Low Exposure =
  rare, unlikely checks. High Exposure = frequent, likely checks.
- `sv_addendum_enable 0` closes the gate. Exposure does NOT reset to zero -
  it decays slowly instead. Reopening before it's decayed picks up where
  it left off, not from zero. Closing also cleans up whatever anomaly was
  currently active.
- `sv_addendum_close` is a separate manual-close command (distinct from
  setting the convar to 0) with its own chat message + sound.
- If Exposure ever crosses a hard containment threshold, the system force-
  closes itself: active anomaly cleaned up, convar forced to 0, Exposure
  hard-cut (not fully reset), and a lockout window where re-opening is
  refused. This exists specifically so a long, unattended, escalating
  session can't snowball into real performance problems (too many
  concurrent anomalies/entities/timers) - it's a safety valve, not content
  designed to break anything.
- Gate open/close/containment all broadcast a colored chat message
  (red-tinted) and an alert sound to every connected client via net
  messages (server can't call chat.AddText directly - see
  `cl_addendum_broadcast.lua`).

What still works exactly as before: the registry, the loader, the
weighted dispatcher with per-anomaly cooldowns, and `anomaly_dummy_echo.lua`
proving the whole pipeline end to end.

## How to test it

1. Drop the contents of this folder into `garrysmod/addons/desiderium/`
   (so `lua/`, `addon.json`, `README.md` sit directly inside that folder -
   no extra nesting).
2. Launch a server (singleplayer works - it still runs a local server).
3. Watch console on map load for the boot lines (core, broadcast,
   dispatcher, exposure system, loader, and the dummy anomaly registering).
4. `sv_addendum_enable 1` - you should hear a sound and see "Server
   enabled!" in console. Nothing fires immediately - that's correct now.
5. Wait. Within roughly 8-ish seconds (tunable, see MIN_CHECK_INTERVAL in
   `sv_addendum_exposure.lua`) the system will start rolling chances to
   dispatch. With only `dummy_echo` registered (5s cooldown, always
   eligible), you should eventually see it fire on its own.
6. Leave it enabled for a while and watch console - check frequency and
   fire chance should visibly increase as time passes (faster dispatch
   attempts, more frequent "fired" lines).
7. `sv_addendum_close` (or `sv_addendum_enable 0`) - chat should show a
   red "[ADDENDUM] Network gate manually closed." message with a sound.
8. To see containment trip deliberately for testing, you can temporarily
   lower `CONTAINMENT_THRESHOLD` in `sv_addendum_exposure.lua` to something
   small (e.g. 10) and leave the gate open - it should force-close itself
   with a more severe-sounding chat message.

## File structure

```
desiderium/
  addon.json                          - Workshop manifest (title/type/tags)
  README.md                           - this file
  lua/
    autorun/
      server/
        sv_addendum_broadcast.lua     - colored chat + sound broadcast (server side send)
        sv_addendum_core.lua          - convar + registry + RegisterAnomaly() + gate open/close
        sv_addendum_dispatch.lua      - picks + runs an eligible anomaly
        sv_addendum_exposure.lua      - rise/decay curve + containment threshold gate
        sv_addendum_loader.lua        - auto-includes everything in lua/desiderium/anomalies/
      client/
        cl_addendum_broadcast.lua     - receives broadcast, shows chat.AddText + plays sound
    desiderium/
      anomalies/
        anomaly_dummy_echo.lua        - placeholder, proves the pipeline works
```

Important: `desiderium/anomalies/` lives **inside** `lua/`, not next to it. GMod's
`"LUA"` file search path (used by both `file.Find` and `include()`) only ever
looks inside `lua/` folders - a folder sitting next to `lua/` at the addon root
is invisible to it, full stop, regardless of what path string you pass in.
An earlier draft of this addon got this wrong; if you're holding an older zip,
re-download or move `desiderium/anomalies/` inside `lua/` manually.

Files under `lua/autorun/`, `lua/autorun/server/`, and `lua/autorun/client/`
are auto-sent and auto-run by the engine - no manual `include()` or
`AddCSLuaFile()` needed for these specific folders.

## The plan (not yet built)

- **Real anomaly content.** The pipeline and the exposure-driven timing are
  both proven; `anomaly_dummy_echo.lua` does nothing scary on purpose. Next
  step is writing the first actual anomaly using this same registration
  contract.
- **Concurrency cap.** Right now `DESIDERIUM.ActiveAnomaly` is a single
  value, so only one anomaly can be "active" at a time even at high
  Exposure. Once we want multiple anomalies stacking simultaneously at
  high Exposure (the "things are spiraling" feeling), `ActiveAnomaly`
  needs to become a list with its own hard concurrency cap, separate
  from the containment threshold.
- **Exploit-memory tracker.** A planned system that notices when players
  reliably dodge an anomaly (hiding behind props, breaking line of sight,
  standing on un-navmeshed furniture) and feeds that back into future
  anomaly behavior. Not started yet - this is a core differentiator for
  the addon, not an afterthought.
- **Eventual admin gating.** `sv_addendum_enable` and `sv_addendum_close`
  are deliberately wide open right now for testing. Locking them down
  (admin-only, or removing client-side execution rights) is a planned
  later step, not forgotten.
- **NPC-reaction tells.** Using ordinary map NPCs' behavior (fleeing,
  freezing, ignoring) as an environmental signal rather than relying
  purely on jumpscare-style entities.
- **Tuning pass.** The rise/decay rates, containment threshold, check
  interval range, and fire chance range in `sv_addendum_exposure.lua` are
  first-guess numbers, not playtested. Expect to adjust these once real
  anomaly content exists and the pacing can actually be felt.

## Design notes / constraints to remember

- Avoid per-entity infinite timers (`timer.Create` per spawned NPC/anomaly
  instance) - this is a known FPS-killer pattern in other GMod horror
  addons as entity count grows. Use one shared scheduler/Think hook
  instead once real anomaly dispatch exists.
- Nextbot-style entities are heavily navmesh-dependent and have well-known
  player-side cheese strategies (prop blocking, line-of-sight breaking,
  exploiting the "stuck for 15s -> reposition" behavior, standing on
  un-meshed furniture). Desiderium's anomalies should be designed with
  these in mind from the start, not patched around them later.
