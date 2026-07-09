# Handoff: Vineyard Map Status Bar Redesign (Option 1A — "Field Dock")

## Overview
This replaces the floating top-left `.controls` panel in the SwagriTech Vineyard Maps PWA
(`swagritech/vineyard-map-app`, single-file `index.html`) with a thumb-anchored **bottom
sheet** designed for one-handed use in bright-sun field conditions.

The chosen direction is **Option 1A ("Field Dock")**. The design file also contains a
rejected alternative (1B — "Glance HUD") for reference only; **do not implement 1B.**

Goals this redesign addresses (from the customer brief):
- Panel no longer covers the map — collapsed state hugs the bottom edge only.
- GPS Walking promoted to a first-class action instead of a small button in a row.
- High-contrast, large-type, on-brand refresh (dated look fixed).
- Hero readout = **block name + grape variety + the zone you're standing in.**

## About the Design Files
The bundled file `Status Bar Redesign.dc.html` is a **design reference created in HTML** —
a static prototype showing the intended look, layout, and states. It is **not** production
code to paste in. It is authored in a proprietary "Design Component" wrapper (`<x-dc>`,
inline styles only) and will not run as-is in the app.

**The task is to recreate this design inside the existing app** — the app is a single
`index.html` using vanilla JS + Google Maps JS API, no build step, no framework. Match the
existing code style (a `<style>` block in `<head>`, plain DOM APIs). Do **not** introduce
React, a bundler, or a CSS framework.

## Fidelity
**High-fidelity.** Colors, typography, spacing, radii, and states below are final. Recreate
pixel-accurately using the exact tokens in the Design Tokens section.

---

## ⚠️ Critical: preserve all existing JS hooks
The app's JavaScript reads and writes specific element IDs and calls specific functions.
The redesign is a **re-skin + re-layout of the same controls** — every hook below MUST
survive (same `id`, same `onclick`, same checkbox semantics). Reuse them; do not rename.

Element IDs the JS touches (keep every one):
- `statusLabel` — load/OK text ("Loading 3/8…", "OK"). Move to expanded sheet; keep the id.
- `customerLabel` — customer name (expanded).
- `blockLabel` — detected block text; this is the hero "You're in" line. Set by GPS + taps.
- `zoneLabel` — the **zone pill** element. `setZonePill()` sets its `textContent`,
  `style.background`, and `style.color` directly (Red/Orange/Green/Outside/—). Keep it a
  single element that can take an arbitrary background + text color.
- `gpsLabel` — "OFF"/"ON"/"ERROR".
- `accLabel` — accuracy string (e.g. "±4 m"). *(App currently sets a value like `—`; see note.)*
- `followLabel` — "ON"/"OFF" for follow mode.
- `blockSelect` — the **jump-to-block** `<select>`. Populated by `populateDropdown()`;
  MUST remain a real `<select id="blockSelect">` (options are appended and `.value` is
  read/written). Style it, but keep it a native select.
- Collapsed mirror ids used by `syncCollapsedSummary()`: `customerLabelCollapsed`,
  `blockLabelCollapsed`, `zoneLabelCollapsed`. These mirror the primary labels into the
  collapsed view. In the new design the hero readout is **always visible** (see Collapse
  behavior), so you can either (a) keep these three ids on the always-visible hero elements
  and drop the separate `.controlsStatusMini` block, or (b) keep a hidden mirror. Simplest:
  point `customerLabelCollapsed`/`blockLabelCollapsed`/`zoneLabelCollapsed` at the hero
  elements themselves. `syncCollapsedSummary()` copies text + the pill's inline
  background/color — keep those assignments working.
- Zone filter checkboxes: `zAll`, `z1` (Red), `z2` (Orange), `z3` (Green). MUST remain
  `<input type="checkbox">` with these ids — `zoneEnabled()` reads `.checked`, and existing
  change listeners restyle the map. You may visually present them as segmented pill buttons,
  but back each pill with a real (visually-hidden) checkbox that toggles on tap, OR keep the
  checkboxes and restyle via `:checked` + a `<label>`. Do not replace with a JS-only control
  that never sets `.checked`.

Functions/handlers (keep the calls):
- `startGPS()`, `stopGPS()`, `toggleFollow()` — wire to the GPS controls.
- `returnToLauncher()` — "Back to launcher".
- `toggleControlsPanel()` / `setControlsCollapsed(bool)` — the expand/collapse toggle.
  Currently toggles `.is-collapsed` on `.controls` and swaps `panelToggleBtn` text
  ("Hide"/"Show") + `aria-expanded`, and persists to `localStorage["vineyardMapsControlsCollapsed"]`.
  Keep this contract; just restyle what collapsed/expanded look like (bottom sheet, below).
- `syncCollapsedSummary()` — keep it functional (see collapsed ids above).

> Note on `accLabel`: the current `watchPosition` handler updates `gpsMarker`/`gpsCircle`
> but does not appear to write `accLabel` (it's initialized to "—"). If you want the "±N m"
> readout shown in the design to be live, add one line in the GPS success callback:
> `$("accLabel").textContent = "±" + Math.round(pos.coords.accuracy) + " m";`
> Flag this to the customer as a tiny functional add, not a redesign requirement.

---

## Screens / Views
One component, two states. The panel is fixed to the bottom of the viewport, full width.

### State 1 — Collapsed (default)
- **Purpose:** at-a-glance readout while walking; map owns the screen.
- **Layout:** bottom sheet pinned to `bottom:0; left:0; right:0`. Rounded top corners
  (26px). Contains only: a drag grabber, then a single row.
  - Grabber: 42×5px, radius 3, `rgba(29,35,28,0.16)`, centered, 14px below top padding.
  - Row (space-between, align flex-start, gap 12):
    - Left column: label "YOU'RE IN" (12px/700, uppercase, letter-spacing .04em,
      `rgba(29,35,28,0.5)`); **block name** `#blockLabel` (24px/900, -0.02em, line-height
      1.05); **variety** (14px/500, `rgba(29,35,28,0.62)`).
    - Right: **zone pill** `#zoneLabel` (see Zone Pill component).
  - **No GPS button in collapsed state** (explicit customer decision — removed).
- **Sheet padding:** `9px 16px 22px` (bottom padding uses safe-area — see Interactions).

### State 2 — Expanded (drag up / tap grabber)
Same bottom sheet, taller, revealing (top to bottom):
1. **Header row** (space-between): customer lockup on the left — a 26×26 rounded-8 green
   `#40914C` square with white "S" (900), then stacked "CUSTOMER" (10px/700 uppercase muted)
   + customer name `#customerLabel` (14px/800). On the right: "← Launcher" ghost pill
   (32px tall, 12px radius-999 by border, 1.5px border `rgba(29,35,28,0.14)`, 12px/700).
   → calls `returnToLauncher()`.
2. **Hero readout** (repeat of collapsed row) with a 1px top divider `rgba(29,35,28,0.09)`,
   12px padding-top.
3. **GPS row** (flex, gap 8):
   - Status chip (flex:1, 48px tall, radius 14, bg `#E9F3EA`, border 1.5px
     `rgba(64,145,76,0.28)`): a 11px green dot with a 3px halo, "GPS on" (14px/800), and
     right-aligned accuracy `#accLabel` (13px/600 muted). When GPS is off, show a
     "Start GPS Walking" affordance here instead (green fill) → `startGPS()`; when on, this
     chip + a "Stop" button (48px, white, 1.5px border, 14px/800) → `stopGPS()`.
   - Follow toggle → `toggleFollow()`, reflect `#followLabel`.
4. **Jump to block:** the native `<select id="blockSelect">`, styled as a 46px, radius-13,
   1.5px-border `rgba(29,35,28,0.14)`, white field, 14px/600 text, with a custom chevron.
5. **Zones + Follow header row:** "ZONES" label (12px/800 uppercase muted) on the left;
   "Follow" + a segmented On/Off toggle on the right (On = `#40914C` fill white text).
6. **Zone filter segmented control** (flex, gap 7), four pills each 40px tall, radius 11,
   1.5px border, 12px/700–800:
   - **All** (`zAll`): neutral/unselected style when off — border `rgba(29,35,28,0.14)`,
     text `rgba(29,35,28,0.55)`, white bg.
   - **Red** (`z1`): dot `#E1352B`, border `#E1352B`, text `#E1352B`, bg `rgba(225,53,43,0.08)`.
   - **Org** (`z2`): dot `#F59E0B`, border `#E68A00`, text `#B86e00`, bg `rgba(245,158,11,0.12)`.
   - **Grn** (`z3`): dot `#2F9E44`, border `#2F9E44`, text `#2F9E44`, bg `rgba(47,158,68,0.1)`.
   Selected = the colored/filled style shown; unselected = neutral outline (border
   `rgba(29,35,28,0.14)`, muted text, white bg). Each pill toggles its backing checkbox.

### Zone Pill component (`#zoneLabel`)
Inline-flex, align center, gap 7, padding `9px 14px`, radius 999, 13px/800, letter-spacing
.02em, white-space nowrap, a 9px white dot on the left, shadow `0 3px 10px rgba(zone,0.35)`.
Background + text color are set by `setZonePill()` at runtime — **do not hardcode green**;
just ensure the element renders a colored pill with a leading dot. Reference states:
Green `bg #2F9E44 / #fff`, Orange `bg #F59E0B / #111`, Red `bg #E1352B / #fff`,
Outside/none `bg #eee / #111`.

---

## Interactions & Behavior
- **Collapse/expand:** reuse `toggleControlsPanel()`. Collapsed = hero row only; expanded =
  full sheet slides up. Animate `max-height`/`transform: translateY` ~220ms ease. Grabber
  and the existing `panelToggleBtn` both trigger it (keep `panelToggleBtn`, "Hide"/"Show"
  text + `aria-expanded`; you may visually hide it and use the grabber as the affordance,
  but keep the element so the JS setter doesn't null-deref). Persist via existing
  `localStorage["vineyardMapsControlsCollapsed"]`.
- **Safe areas (iOS + Android — required):**
  - Add `viewport-fit=cover` to the existing viewport meta:
    `<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">`
  - Sheet: `padding-bottom: max(22px, env(safe-area-inset-bottom));` so it clears the iPhone
    home indicator and Android gesture bar.
- **Tap targets:** all interactive elements ≥44px (meets Apple HIG + Material). Current
  values above already satisfy this; keep them.
- **GPS pill/dot** on the map and all map behavior are UNCHANGED — this task only touches
  the controls panel markup + CSS (+ the optional one-line `accLabel` add).
- **Landing/app switching** (`showApp()`/`showLanding()`) toggles `.controls`
  `display`. Keep the top-level container class `.controls` (or update those two functions'
  selector if you rename it).

## State Management
No new state. Existing state variables (`gpsWatch`, `followMode`, `activeSurveyIds`,
`allZonesChecked`, zone checkbox `.checked`, collapsed flag in localStorage) are untouched.
The redesign only re-renders existing values.

## Design Tokens
Brand (already in the repo's `:root`, reuse):
- `--swat-green: #40914C`  (primary; hover/pressed `#34763d`)
- `--swat-ink: #1D231C`    (text)
- `--swat-sand: #E1DFD9`
- `--swat-paper: #F7F4EE`  (sheet background)
- `--swat-border: rgba(29,35,28,0.12)`

Zone colors (pills + filters):
- Red `#E1352B` (on-map polygons stay `#ff0000` — do not change map styling)
- Orange `#F59E0B` (text `#B86e00`, border `#E68A00`)
- Green `#2F9E44`
- GPS blue dot `#2f6bff`

Neutrals / text: strong ink `#1D231C`; muted `rgba(29,35,28,0.62)`; faint label
`rgba(29,35,28,0.5)`; hairline `rgba(29,35,28,0.09)`.

Typography: **Roboto** (already loaded), weights 500 / 700 / 800 / 900.
- Block name 24/900, -0.02em · variety 14/500 · section labels 12/700–800 uppercase .04em
- pill 13/800 · buttons 14–16/800 · select 14/600

Radii: sheet top 26 · chips/fields 12–15 · filter pills 11 · pill/toggle 999 · grabber 3.
Shadows: sheet `0 -10px 30px rgba(29,35,28,0.22)` (deeper when expanded, `…0.26`);
pill `0 3px 10px rgba(47,158,68,0.35)`; GPS status halo `0 0 0 3px rgba(64,145,76,0.22)`.
Spacing: sheet padding `9px 16px [safe-area]`; inter-row gaps 10–16; control gaps 7–8.

## Assets
None new. Reuse the existing SWAT logo already in the repo (`images/SWAT_Logo_june2025.png`)
if a full logo is ever wanted; the compact "S" mark in the header is CSS text, no asset.

## Files
- `Status Bar Redesign.dc.html` (this bundle) — the visual reference. **Option 1A only.**
  Ignore the 1B ("Glance HUD") column and the on-canvas "Handoff spec" callout box (its
  content is folded into this README).
- Target for edits in the repo: `index.html` — the `.controls` block (markup) and its CSS
  in the `<head>` `<style>` (search for `.controls`, `.controlsToggle`, `.controlsStatusMini`,
  `.is-collapsed`, `.row`, `.btnRow`, `.pill`, `.checkRow`). The `<script>` hooks listed
  above are further down the same file.

## Suggested implementation order
1. Add `viewport-fit=cover` to the viewport meta.
2. Rewrite the `.controls` markup to the bottom-sheet structure, keeping every id/handler.
3. Replace the `.controls` / collapse CSS with the tokens above (bottom-anchored sheet,
   safe-area padding, new type scale). Keep `.is-collapsed` as the collapsed selector.
4. Verify `syncCollapsedSummary()`, `setZonePill()`, `populateDropdown()`, zone checkboxes,
   and GPS/follow buttons all still resolve their ids.
5. (Optional) add the one-line `accLabel` update in the GPS success callback.
6. Test on iOS Safari + Android Chrome (installed PWA), collapsed + expanded, GPS on/off,
   zone filter toggles, jump-to-block.
