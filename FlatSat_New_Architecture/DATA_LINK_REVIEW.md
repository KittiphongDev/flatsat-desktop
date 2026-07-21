# FlatSat — Post-Fix System Review

**Premise:** this review assumes the whole `DATA_LINK_FIX_PLAN.md` (Rev 2) has
**already been applied**, and asks: *what is still wrong, what did the plan miss,
and what new problems does the plan itself create?* No code has been changed.

Severity: **S1** breaks a feature · **S2** visibly wrong / fragile · **S3** latent / polish.

**Headline:** the plan fixes the acute failures (double bridge, false EPS
"stall", dead downloads). But three things still stop the system being solid:

* **R1 [S1]** — the plan's own non-blocking OBC rewrite can now **silently drop a
  command**. This is a *regression the plan introduces* and must be fixed with it.
* **R2 [S1]** — the bridge writes to the serial port from **two threads with no
  lock**; the plan's retries make the existing race more likely to bite.
* **R3 [S1]** — after an **OBC watchdog reset mid-download**, every later chunk
  serves the wrong file, because the filename is only sent with chunk 0.

Everything else is S2/S3. Details below.

---

## 1. Verified correct (so these are NOT the problem)

Worth stating plainly, because it narrows where bugs can hide.

* **Endianness is consistent end-to-end.** GPS lat/lon/alt floats and EPS floats
  are little-endian on both OBC (`memcpy`) and bridge (`<f`); ADM voltage/current
  are LE `<H`; image-list sizes and CRC32 are big-endian `>I` on both sides; the
  RSSI/SNR tail is big-endian `>h`/`b`. No mismatches.
* **CRC32 matches.** OBC's bit-banged CRC (reflected, init `0xFFFFFFFF`, poly
  `0xEDB88320`, final XOR) equals Python `binascii.crc32`. Confirmed by inspection.
* **The power-channel mapping is behaviourally correct** despite misleading
  names. Trace: UI "Communication" = `payloadPwrState` = PD1 = ADM 0x59 (locked,
  correct — never cut comms); UI "Payload 1/GPS" = `gpsPwrState` = PD2 = 0x5A =
  toggle(1); UI "Payload 2/PC104" = `camPwrState` = PD3 = 0x5B = toggle(2). The
  UI never sends subsystem 0, so the link can't be cut from the ground. Works —
  see S3-8 for the naming cleanup.
* **KISS empty/again-FEND framing** is handled in every decoder (OBC, COMMU, GS,
  bridge): a stray `FEND FEND` starts an empty frame that is ignored.
* **Zero-image list** round-trips: OBC forces `totalChunks = 1`, sends a 2-byte
  `[0][1]` chunk, bridge reassembles an empty blob → empty list. The plan
  preserves this.

---

## 2. Gaps the plan did NOT cover

### R1 [S1] — Non-blocking OBC TX can silently drop a command *(regression introduced by the plan)*

The plan's §5.2 replaces blocking `sendChunked()` with a single-slot job:

```c
void queueChunked(...) {
  if (txJob.active) return;      // <-- silently drops the new request
  ...
}
```

The **old blocking** code processed each chunked response to completion before
`handleCommand` returned, so two commands arriving close together were naturally
serialised. The **new non-blocking** code has exactly one job slot, so this
sequence now fails:

1. User presses **STATUS** → `queueChunked(HEALTH…)` starts, `txJob.active = true`.
2. ~200 ms later user presses **GET EPS** → `handleCommand` calls
   `queueChunked(EPS…)` → `txJob.active` is still true → **the EPS request is
   dropped with no response.**
3. The dashboard's 8 s EPS watchdog fires: *"EPS transfer timed out."*

So a fix aimed at *removing* false timeouts can *create* a real one. GPS
(also moved off blocking in §5.2) collides the same way.

**Required addition to the plan:** give `queueChunked` a small FIFO of pending
requests (2–3 deep is plenty — health, eps, image-list, gps are the only
producers), and start the next job when `txJob.active` goes false. Alternatively,
if a request arrives while busy, reply `CMD_NACK` immediately so the dashboard
surfaces "satellite busy, try again" instead of a silent timeout. A queue is
better UX; a NACK is the minimal safe version.

**Desk-check to add:** enqueue HEALTH then EPS back-to-back → both complete in
order; nothing is dropped.

---

### R2 [S1] — `ser.write()` is called from two threads with no lock

`send_command()` (bridge) is invoked from:

* the **asyncio/WebSocket thread** — every user action (`ping`, `get_eps`,
  `download`, `toggle_pwr`, …) in `ws_handler`, and
* the **serial reader thread** — `handle_image_chunk` requesting the next chunk,
  and (after the plan) `service_download`'s retries.

Both ultimately do `ser.write(...)`. pyserial does **not** guarantee atomicity
when two threads write concurrently; a user pressing PING mid-download can
interleave bytes into the middle of a `REQ_CHUNK` frame. The result is a
corrupted KISS frame that the GS/OBC drops → a mystery stalled chunk.

This already exists in the current code, but the plan's per-chunk **retries
raise the write rate from the serial thread**, making the collision materially
more likely.

**Required addition:** a single `threading.Lock` taken around every `ser.write()`
in `send_command`. Cheap, and it closes the last data-corruption path that
survives the plan.

---

### R3 [S1] — Download breaks permanently after an OBC watchdog reset mid-transfer

The bridge sends the filename **only with chunk 0** (`ws_handler` download
handler), and the OBC *caches* it in `downloadFilename`, which defaults to
`"photo.jpg"` and is reset to that default on every boot.

The OBC has a **10 s hardware watchdog** and, in the Lab-6 lineage, is explicitly
designed to reset under fault. If the OBC resets after, say, chunk 40:

1. `downloadFilename` reverts to `"photo.jpg"`.
2. The bridge, unaware, keeps requesting `REQ_CHUNK(41, 42, …)` **without a
   filename**.
3. The OBC serves those offsets **from `photo.jpg`**, not the file the user asked
   for → the assembled image is silently a Frankenstein of two files, and the
   per-chunk CRC won't catch it (each chunk is internally valid).

The plan's §3.5 already says "re-send the filename on a **retry of chunk 0**",
but that does not cover a reset at chunk 40.

**Required change:** include the filename on **every** `REQ_CHUNK`, not just
chunk 0. Budget check: `2 + len(name)` with the §5.4 cap of 30 chars → N ≤ 32 →
56 bytes on air → within the 64-byte ceiling. This makes downloads reset-proof
and costs nothing on the wire.

---

### R4 [S2] — No arbitration between overlapping link activities

Even with R1's queue, the **radio link is one shared half-duplex channel** and
the bridge tracks download and EPS/list/health state independently. If a user
starts a download and then presses GET EPS, the OBC will interleave
`IMAGE_DATA` and `EPS_DATA` frames on the link. The bridge's separate reassembly
keys mean it *may* cope, but:

* the two transfers compete for airtime, so both slow down and are more likely to
  hit their timeouts;
* a `REQ_CHUNK` retry and an EPS chunk can arrive at the GS overlapping in time
  and one is lost (half-duplex).

**Recommendation:** the bridge should enforce **one active transfer at a time** —
while `download_state["active"]`, reject `get_eps` / `list_image` / `status` with
a `{"type":"busy"}` message; the dashboard disables those buttons and shows
"Downloading…". Simple, and it removes a whole class of flaky-under-load bugs.

---

### R5 [S2] — Redundant multi-send produces duplicate UI events

`CMD_GPS_DATA` is sent **3×** and, post-plan, EPS/health/list chunks 2×. The
bridge does **not** de-duplicate idempotent whole-packet responses like GPS:

* `process_packet` handles each of the 3 GPS copies → 3 `gps` broadcasts → 3
  `"GPS position received"` toasts and 3 log lines.
* The plan's `reassemble()` fixes the *chunked* duplicates (EPS/health/list), but
  **GPS is not chunked** — it is three full packets, so it slips past that fix.

Not harmful (last write wins, SnackBar coalesces visually), but it clutters the
event log and fires the toast repeatedly.

**Recommendation:** in the bridge, drop a GPS/ACK packet whose payload is
byte-identical to the previous one within a ~1 s window. One-line guard.

---

### R6 [S2] — Charts are labelled "live" but never update on their own

`EpsDashboard` renders "live line charts", but `epsHistory` only grows when a
`CMD_EPS_DATA` arrives, which only happens when the user presses **GET EPS**.
There is no periodic poll, so the charts are effectively static snapshots.

**Decision needed:**
* If live is intended → add an opt-in auto-poll (e.g. GET EPS every 5–10 s) — but
  gate it behind R4's arbitration so it never fires mid-download.
* If on-demand is intended → relabel from "live" to "last reading" so the UI
  isn't promising something it doesn't do.

---

### R7 [S2] — Error bitmask only ever reports EPS and SD

`checkHardware()` sets only `ERR_EPS` and `ERR_SD`. `ERR_I2C`, `ERR_CAM`,
`ERR_GPS` are defined and decoded by the dashboard (`errorString`) but **never
set anywhere in the firmware**. So a dead GPS or camera is invisible in the
beacon, while the dashboard implies it would show them.

**Recommendation:** set `ERR_GPS` when `gps.charsProcessed()` stalls or no fix
for N seconds; set `ERR_CAM` once the camera is real. Until then, note in the UI
that only EPS/SD faults are reported so operators don't trust a false "all clear".

---

### R8 [S3] — No end-to-end integrity check on a downloaded image

Each `IMAGE_DATA` frame is CRC-protected, and offset-addressed reassembly
(plan §3.4) prevents ordering errors, so corruption is unlikely. But there is no
*whole-file* check. Lab 6 deliberately printed a final CRC32 for the operator to
compare. The new EOT carries only a **16-bit truncated size** (plan D9), which is
both lossy and weak.

**Recommendation (needs a tiny, backward-compatible protocol extension, so flag
for approval):** have the OBC put the **full 32-bit file CRC** in the EOT payload
(EOT currently sends 4 bytes: `FF FF sizeHi sizeLo`; extend to
`FF FF crc32(4)` or `FF FF size32(4) crc32(4)` — still one frame, well under 64
bytes). The bridge verifies after assembly and reports pass/fail. If the "frozen
protocol" rule forbids even additive EOT changes, skip and rely on per-chunk CRC.

---

## 3. Smaller issues (S3)

* **S3-1 — ACK is overloaded and guessed at.** `CMD_ACK` means pong (ping),
  power-state echo (toggle), *and* filename (take_pic). The dashboard
  disambiguates by "is a ping pending?" and "does it parse as hex?". Edge case:
  taking a picture while a ping is outstanding makes the pic's ACK be recorded as
  the ping RTT. Low-probability, but the overloading is fragile — consider
  distinct response commands if the protocol is ever revised.
* **S3-2 — Reassembly tombstones aren't garbage-collected.** The plan's
  `reassemble()` keeps a `done=True` entry as a duplicate-guard tombstone, and
  the stale-transfer watchdog only reaps `not done` entries. Bounded (3 fixed
  keys) so not a leak, but add tombstone reaping to the watchdog for tidiness.
* **S3-3 — `build_opt.h` may be silently ignored** depending on how this project
  is compiled. The plan already says to print `SERIAL_RX_BUFFER_SIZE` in `setup()`
  to confirm; treat that check as mandatory, and keep §6 Fix B (ring buffer)
  ready.
* **S3-4 — 16-bit chunk id caps images at ~2 MB** (`>H` chunk index × 32 B). Fine
  for the placeholder and typical JPEGs; document the ceiling.
* **S3-5 — `checkHardware()` runs every beacon (~1 s)** and does `sd.exists("/")`,
  which touches the SD bus the download also uses. Same thread so no race, but it
  adds latency during a download. Cache the result and refresh every ~10 s.
* **S3-6 — Reconnect loses non-telemetry state.** On WebSocket reconnect the
  bridge re-sends only telemetry + bridge_status, not the last eps/gps/list/health.
  After an app restart those panels are blank until re-requested. Minor.
* **S3-7 — GS SNR is meaningless in FSK** (already in plan §6). Restating because
  the dashboard must actively **hide** the SNR line, not just show 0.0.
* **S3-8 — Misleading firmware names.** `payloadPwrState` actually controls
  *Communication* (PD1/0x59); `PAYLOAD_PWR_PIN` likewise. Behaviour is correct
  (see §1) but the names invite a future edit that cuts the comms link. Rename to
  `commPwrState` / `COMM_PWR_PIN` when touching that file.
* **S3-9 — Download `expected_size` unknown if the user never lists first.** Bar
  falls back to indeterminate. Acceptable; could seed from the EOT size.

---

## 4. Does the plan actually close the original complaints?

| Original symptom | Root cause | Closed by | Residual |
|---|---|---|---|
| Dashboard won't start / window vanishes | double bridge, `python3` on Windows | Plan Phase 1 | none |
| EPS ends in a "stalled" error despite success | duplicate chunk phantom-restart (D2) | Plan Phase 2 `reassemble()` | none |
| Health/list occasionally duplicated or corrupt | same class in `reassemble_simple` (D3) | Plan Phase 2 | none |
| Image download hangs forever | no timeout/retry (D4) | Plan Phase 3 | **R3** (reset mid-download), **R4** (contention) |
| Telemetry values look fake (80/25/12) | hardcoded beacon (D7) | Plan Phase 5.1 | 1S/2S chemistry unconfirmed |
| No download %, no ETA | no size/progress (D8) | Plan Phase 3.6 + 4 | seed size needs a LIST first |
| GPS degraded during big transfers | blocking `delay()` (D10) | Plan Phase 5.2 | **R1** (dropped command) |
| COMMU drops bytes mid-TX | 64 B core buffer (D11) | Plan §6 Fix A/B | S3-3 confirm build_opt |

**Net:** the plan is directionally right and closes every original complaint, but
**R1, R2, R3 must be folded into it** or the download path and command handling
will still be flaky under real use.

---

## 5. Biggest non-code caveat, restated

Even with everything above fixed, **the image feature has no image**. `TAKE_PIC`
writes a 4-byte JPEG stub (`OBC.ino` `CMD_TAKE_PIC`, camera read is still a
`TODO`). So an end-to-end download test returns a 4-byte file. To exercise the
download path meaningfully before the camera exists, **place a real `.jpg` on the
SD card** and download that by name. This is the single most important thing to
know before judging whether "downloads work".

---

## 6. Suggested order once you do apply fixes

1. **Fold R1 + R2 + R3 into the plan first** — they are S1 and cheap, and without
   them Phase 3/5 don't actually deliver a reliable download.
2. Then the plan's Phase 1→4 (all PC-side, no reflash) — verify against the
   replay harness.
3. Then Phase 5→6 (firmware reflash), with R1's queue and S3-8 rename included.
4. Add to the replay harness: a command-overlap test (R1), a serial-write-lock
   test (R2), and a reset-mid-download test (R3).
