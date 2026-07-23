# FlatSat — Feature Plan (9 requested features)

Status: **plan only, no code changed.** Complexity: **S** small · **M** medium · **L** large.
"Reflash" = needs OBC/COMMU firmware re-flash. Everything else is PC-side (app + bridge)
and testable immediately.

Existing building blocks we reuse: `SettingsService` (shared_preferences), the reliable
`collect_*` chunk transfer + progress, the offset-addressed download state machine, the
port picker, `platform.dart` (`isDesktopPlatform`).

---

## Feature-by-feature

### F1 · Image size in KB **and** MB (toggle: KB-only / both)
- **Layer:** App only. **Complexity:** S. **Reflash:** no.
- Add `imageSizeUnit` (`kbOnly` | `both`) to `SettingsService`.
- `ImageEntry.sizeFormatted` (and download UI) reads the setting: `kbOnly` →
  `"48.2 KB"`; `both` → `"48.2 KB (0.05 MB)"`.
- Setting row in the Settings panel.

### F5 · Notification colours — green = success, red = error only
- **Layer:** App only. **Complexity:** S. **Reflash:** no.
- Today `_flash()` toasts use the red accent for everything. Add a `success` flavour:
  green for command-acked / data-received, red for errors/failures, (optional) neutral
  for "sent". Update `_CommandFeedback` SnackBar colour by flavour.

### F6 · Setting to disable the COMMS turn-off lock (+ warn before off)
- **Layer:** App only. **Complexity:** S–M. **Reflash:** no.
- Add `commsLockEnabled` (default **true**) to `SettingsService`.
- `SubsystemCard` for Communication: if lock disabled, show the toggle; on turn-**off**
  show a confirm dialog ("This cuts the radio link — you won't be able to command the
  satellite until it's power-cycled"). Turning on is unguarded.

### F3 · First-run guidance popup (what to install / access)
- **Layer:** App only. **Complexity:** M. **Reflash:** no.
- On first launch (a `firstRunDone` flag in settings), show a dialog. Auto-detect OS via
  `Platform` (Windows / macOS / Linux) **and** let the user switch tabs manually.
- Per-OS checklist: Python 3 (+PATH on Windows), USB-serial driver (CP210x/CH340/FTDI),
  Linux `dialout` group + "close Arduino Serial Monitor", how to pick the GS port.
- "Don't show again" + re-openable from Settings ("Setup guide").

### F2 · Selectable image save path (first-run default, editable in settings)
- **Layer:** App (folder picker) + Bridge (writes the file). **Complexity:** M.
- **New dep:** `file_picker` (folder selection). Default via `path_provider`
  (e.g. Documents/FlatSat) on first run; store `downloadDir` in settings.
- App sends the chosen absolute path to the bridge (`set_download_dir`), bridge saves
  downloads there (replaces the fixed `./downloads`). Re-sent on connect.
- Note: app & bridge run on the same PC, so a path string is enough.

### F4 · Pausable image download, state kept in the **app** (not the satellite)
- **Layer:** App + Bridge. **Complexity:** M–L. **Reflash:** no.
- The satellite is already **stateless** for downloads (it serves chunk *N* on request),
  so nothing is stored on the satellite — requirement already met by design.
- Add `pause` / `resume` WS commands. Pause = bridge stops requesting; the partial
  (chunks-by-index) stays in `download_state`. Resume = continue from the lowest missing
  chunk.
- Persist the partial to disk (a `.part` file + a small JSON of received indices) so a
  **paused download survives an app/bridge restart**; the app shows a "Resume" button.
- UI: pause/resume button on the download card; progress already has %/speed/ETA.

### F9 · Time sync (dashboard → satellite)  *(prerequisite for F8)*
- **Layer:** App + Bridge + **Firmware**. **Complexity:** M. **Reflash:** yes.
- New `CMD_SET_TIME` (0x12): payload = `uint32` UNIX epoch seconds (UTC). OBC sets its
  STM32 RTC. Optional: reply ACK with the OBC's new time for verification.
- App: "Sync time" action (and auto-sync on connect). Bridge just forwards.
- Caveat: without a coin-cell on VBAT the RTC resets on power loss — re-sync each session
  (auto-sync on connect covers this).

### F7 · Selectable picture quality & format (popup on Take Pic, remember last)
- **Layer:** App + Bridge + **Firmware**. **Complexity:** M–L. **Reflash:** yes.
- Camera is the Arducam Mega (5 MP). Expose resolution presets up to **2592×1944 (5 MP,
  4:3)** — e.g. 5 MP / 3 MP / 1080p(≈4:3 crop) / VGA — and format **JPEG** (quality
  low/med/high). *(SDK constrains exact modes — final list confirmed against the driver.)*
- Extend `CMD_TAKE_PIC` payload = `[resolutionId][format/quality]`; firmware sets the
  Arducam mode before capture.
- App: popup on Take Pic pre-filled with the **remembered** last choice (in settings);
  "Capture" / "Cancel".

### F8 · EPS state logging on the satellite (the big one)
Auto-save EPS with timestamp every 5 s (interval configurable from the dashboard);
memory-efficient; GET EPS pulls **all** saved states, then deletes the transferred ones
to free space; plus an enable/disable switch.
- **Layer:** Firmware **L** + Bridge **M** + App **M**. **Reflash:** yes.
  **Depends on F9** (timestamps need a real clock).
- **Storage (SD, append-only binary log)** — best space/robustness trade-off:
  - Compact record (**~20 bytes**), not the 75-byte live blob:
    `t(uint32) | battV(int16 mV) | battTemp(int16 c°C) | 6×INA(int16 mA) …` — tune to what
    the dashboard actually charts. At 5 s that's ~14 KB/hour — trivial for SD.
  - Append to `eps_log.bin`; a header/counter tracks record count.
- **Config commands:** `CMD_EPS_LOG_CFG` = `[enable][interval_s(uint16)]`.
- **Pull + delete (reliable):** `GET_EPS` (or a new `CMD_GET_EPS_LOG`) streams the log in
  radio-safe chunks via the existing collector; the OBC deletes/truncates the file **only
  after the bridge ACKs a complete, CRC-verified transfer** (never lose data on a dropped
  link). "Clear trash" = truncate the file and reset the counter.
- App: a history view (the EPS charts already exist — feed them the pulled series);
  enable/disable + interval controls; "pull now".
- Design decision needed: keep the current *live* GET EPS (one snapshot) **and** add the
  *logged history* pull as a separate action — recommended, so a quick snapshot stays fast.

---

## Suggested phases (each independently shippable)

| Phase | Features | Reflash | Notes |
|-------|----------|---------|-------|
| **A — App polish** | F1, F5, F6, F3 | no | Fast wins; settings + first-run UX |
| **B — Files & download** | F2, F4 | no | Needs `file_picker`; pause/resume + save path |
| **C — Firmware basics** | F9, F7 | **yes** | Time sync (small) + camera settings |
| **D — EPS logging** | F8 | **yes** | Largest; build after F9 (needs the clock) |

---

## New dependencies
- Flutter: **`file_picker`** (folder picker for F2). Possibly `path_provider` for the
  default folder (may already be transitively available).
- Firmware (F7/F8): the Arducam Mega driver (already used by the ported capture) and the
  STM32 RTC (built-in, no new lib).

## Protocol additions (frozen-friendly — all additive)
- `CMD_SET_TIME = 0x12` (F9)
- `CMD_TAKE_PIC` payload gains `[resId][fmt]` (F7) — back-compatible (empty = defaults)
- `CMD_EPS_LOG_CFG = 0x13`, `CMD_EPS_LOG_DATA = 0x14` (or reuse EPS_DATA with a "log" tag)
  and a `CMD_EPS_LOG_ACK`/delete step (F8)

## Open questions (please confirm)
1. **Order/scope:** OK to do Phase A first (ships today, no reflash), or is one feature
   top priority?
2. **F7 camera:** confirm Arducam Mega 5 MP; which resolution presets do you want exposed?
3. **F8:** which EPS values must be logged (all sensors, or battery+temp+key rails)? And
   should logged-history pull be a *separate* button from the live GET EPS?
4. **F8 timestamps / F9:** is there a VBAT coin-cell on the OBC RTC, or should we always
   auto-sync on connect (fine either way)?
5. **F2 default folder:** Documents/FlatSat OK as the first-run default?
