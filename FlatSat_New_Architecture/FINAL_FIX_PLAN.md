# FlatSat — Final Data-Link Fix Plan (consolidated)

**This document supersedes `DATA_LINK_FIX_PLAN.md` and `DATA_LINK_REVIEW.md`.**
It merges the original defect fixes (D1–D16) with the review findings
(R1–R8, S3-*) into one ordered, self-contained plan.

**Status:** analysis only — **no code has been changed.** Nothing can be tested
on hardware yet, so every item is justified from the source and carries a
desk-check.

**Frozen (do NOT change):** packet layout `SYNC1 SYNC2 CMD LEN payload CRC32`,
command byte values, chunk header `[idx][total]`, CRC32, AX.25 wrapping, the
RSSI/SNR tail, `COPIES = 2` redundancy, `CHUNK_SIZE = 32`. The one *additive*
protocol touch that requires your approval is the EOT CRC in F19 — it is optional.

---

## 0. Confirmed facts

**EPS I2C map (authoritative, from the hardware table) — matches the OBC arrays exactly:**

| `powerMonitors[]` | Addr | Role | `tempSensors[]` | Addr | `powerControllers[]` | Addr | Role |
|---|---|---|---|---|---|---|---|
| 0 | 0x40 | Solar 1 | 0 | 0x4A | 0 | 0x58 | OBC (unswitchable) |
| 1 | 0x41 | Solar 2 | 1 | 0x4B | 1 | 0x59 | Communication (PD1) |
| 2 | 0x42 | Solar 3 | | | 2 | 0x5A | Payload 1 / GPS (PD2) |
| 3 | 0x43 | Solar 4 | | | 3 | 0x5B | Payload 2 / PC104 (PD3) |
| 4 | 0x47 | **Battery Charging** | | | | | |
| 5 | 0x48 | **Battery Discharging** | | | | | |

Beacon battery voltage/SoC comes from **index 5 (0x48, discharge rail)**.

**Toolchain:** STM32duino (Arduino_Core_STM32), flashed with STM32CubeProgrammer.
Determines how the COMMU buffer fix is applied (F17).

**Architecture:** COMMU and GS are **dumb transparent relays** — there is **no
link-layer ACK**. Reliability rests on: push responses (EPS/health/list) using
the OBC's `COPIES = 2` double-send; pull responses (image download) using the PC
bridge's `REQ_CHUNK` re-request. **Image download therefore has no redundancy at
all** — one lost frame is fatal unless the bridge re-requests it. That is why the
download fixes (F10–F16, F-R3) are the highest-value firmware-adjacent work.

---

## 1. Frame budget (the hard 64-byte constraint)

```
AX.25(16) + [SYNC SYNC CMD LEN](4) + payload(N) + CRC32(4) = 24 + N bytes on air
```

Ceiling 64 → **N ≤ 40**. Chunked payload is `[idx][total][data]` → **data ≤ 38**.

| Frame | N | on air | margin |
|---|---|---|---|
| Beacon | 8 | 32 | OK |
| GPS_DATA | 14 | 38 | OK |
| Chunked / IMAGE_DATA @ `CHUNK_SIZE 32` | 34 | 58 | 6 B |
| REQ_CHUNK + 30-char filename | 32 | 56 | 8 B |
| EOT + size32 + crc32 (F19, optional) | 10 | 34 | OK |

`CHUNK_SIZE = 32` stays. A unit assertion (F22) guards against anyone raising it.

---

## 2. Complete defect register (merged)

Severity: **S1** breaks a feature · **S2** visibly wrong / fragile · **S3** latent / polish.

| ID | Sev | Layer | Defect | Phase |
|---|---|---|---|---|
| D1 | S1 | bridge+app | Bridge started twice → port 8080 conflict; `python3` on Windows | 1 |
| D16 | S2 | app | `dart:io` import breaks web build | 1 |
| D2 | S1 | bridge | Duplicate EPS chunk re-opens phantom transfer → false "stalled" | 2 |
| D3 | S2 | bridge | Same bug in `reassemble_simple` → double broadcast / stale-chunk corruption | 2 |
| **R2** | **S1** | bridge | `ser.write()` from two threads, no lock → corrupted frames | 3 |
| D4 | S1 | bridge | Download has no timeout / no retry → hangs forever | 4 |
| D5 | S2 | bridge | Download appends sequentially instead of by offset | 4 |
| D6 | S2 | bridge | `CHUNK_SIZE = 48` contradicts OBC's 32 | 4 |
| D14 | S3 | bridge | Path traversal via download filename | 4 |
| **R3** | **S1** | bridge | Filename only sent on chunk 0 → wrong file after OBC reset | 4 |
| **R4** | S2 | bridge+app | No arbitration between download and EPS/list/health | 4 |
| D8 | S2 | bridge+app | No total → indeterminate bar, no % / ETA | 4,5 |
| **R5** | S2 | bridge | Multi-send GPS/ACK not de-duplicated → repeated toasts | 4 |
| R1-app | S2 | app | Must handle new `download_failed` / `eps_failed` / `busy` | 5 |
| D7 | S1 | OBC | Beacon battery/temp/voltage hardcoded (80/25/12) | 6 |
| D10 | S2 | OBC | Blocking `delay()` in chunked sends starves UART/GPS | 6 |
| **R1** | **S1** | OBC | Non-blocking rewrite drops a 2nd command silently (regression) | 6 |
| D15 | S2 | OBC | TAKE_PIC writes 4-byte stub; counter resets on reboot | 6 |
| D13 | S3 | OBC | No filename-length guard on uplink | 6 |
| D9 | S3 | OBC | EOT size truncated to 16 bits | 6 |
| R7 | S2 | OBC | Error bitmask never sets I2C/CAM/GPS | 6 |
| S3-8 | S3 | OBC | `payloadPwrState`/`PAYLOAD_PWR_PIN` misnamed (really Communication) | 6 |
| D11 | S2 | COMMU | 64 B core UART buffer overflows mid-TX | 7 |
| D12 | S3 | GS | SNR meaningless in FSK; int8 clips at ±12.7 dB | 7 |
| R6 | S2 | app | Charts labelled "live" but never auto-update | 8 |
| R8 | S3 | proto | No end-to-end image CRC (optional additive) | 8 |

---

## 3. Fix phases

Ordered so **Phases 1–5 are PC-side only (no reflash)** and independently
shippable; Phases 6–7 are one firmware reflash; Phase 8 is optional polish.

---

### Phase 1 — One bridge, one owner (D1, D16)

**File:** `Dashboard/lib/services/websocket_service.dart`

Delete the app's auto-start and rely on the launcher scripts (which already start
*and* stop the bridge):

1. Remove `_startPythonBridge()` and its call in the constructor; call `connect()`
   directly.
2. Remove `Process? _bridgeProcess`, the `dispose()` kill, and `import 'dart:io'`
   (fixes D16 — the web build compiles again).
3. `ConnectionStage.bridgeOffline` is now the honest "you didn't use the launcher"
   signal. Update `connection_banner.dart` `bridgeOffline` copy: *"Start the app
   with `run_mission_control.bat` (Windows) or `run_mission_control.sh`
   (Linux/Pi)."*

**Desk-check:** `grep Process.start` → nothing; launch via `.bat` → one `python`,
no `Errno 98` in `bridge_log.txt`.

---

### Phase 2 — Duplicate-proof chunk reassembly (D2, D3)

**File:** `PC_Bridge/gs_bridge.py`

Replace `eps_reassembly`, `misc_reassembly`, `handle_eps_chunk`, and
`reassemble_simple` with **one** duplicate-aware reassembler plus a single
`_reassembly = {}` dict.

```python
DUPLICATE_GUARD_S  = 2.5    # swallow the COPIES=2 echo after completion
REASSEMBLY_STALE_S = 4.0    # abandon a transfer missing a chunk

def reassemble(key, payload, payload_len, on_progress=None):
    if payload_len < 2:
        return None
    chunk_idx, total = payload[0], payload[1]
    if total == 0:
        return None
    data = bytes(payload[2:payload_len])
    now  = time.time()
    buf  = _reassembly.get(key)

    # Drop the tail of an already-delivered transfer (kills the D2/D3 phantom).
    if buf and buf["done"]:
        if now - buf["ts"] <= DUPLICATE_GUARD_S:
            buf["ts"] = now
            return None
        buf = None
    if buf is None or buf["total"] != total or now - buf["ts"] > REASSEMBLY_STALE_S:
        buf = {"total": total, "chunks": {}, "ts": now, "done": False}
        _reassembly[key] = buf

    is_new = chunk_idx not in buf["chunks"]
    buf["chunks"][chunk_idx] = data
    buf["ts"] = now
    if on_progress and is_new:
        on_progress(len(buf["chunks"]), total,
                    sum(len(v) for v in buf["chunks"].values()))
    if all(i in buf["chunks"] for i in range(total)):
        buf["done"] = True                     # tombstone, not delete
        return b"".join(buf["chunks"][i] for i in range(total))
    return None
```

Wire EPS / IMAGE_LIST / HEALTH through it (EPS passes an `on_progress` that emits
`eps_progress`; on complete, emit `eps`; on parse-fail emit `eps_failed`).

**Reassembly + tombstone watchdog** in the serial thread's periodic section:

```python
for k, b in list(_reassembly.items()):
    if b["done"] and time.time() - b["ts"] > DUPLICATE_GUARD_S:
        del _reassembly[k]                     # reap tombstone (S3-2)
    elif not b["done"] and time.time() - b["ts"] > REASSEMBLY_STALE_S:
        missing = [i for i in range(b["total"]) if i not in b["chunks"]]
        del _reassembly[k]
        if k == "eps":
            schedule_broadcast({"type": "eps_failed",
                                "data": f"Lost chunk(s) {missing} — press GET EPS again"})
```

**Desk-check:** feed `c0 c0 c1 c1 c2 c2` → exactly one `eps`, progress 1/3→2/3→3/3,
**no** 4th message, no phantom restart. Single-chunk health twice → one `health`.

---

### Phase 3 — Serial write lock (R2)

**File:** `PC_Bridge/gs_bridge.py`

`send_command()` is called from the WebSocket thread (user actions) **and** the
serial thread (chunk requests/retries). Guard the write:

```python
_serial_write_lock = threading.Lock()

def send_command(cmd_type, payload=b''):
    if ser and ser.is_open:
        data = build_packet(cmd_type, payload)
        with _serial_write_lock:
            ser.write(data)
        log.info(...)
```

Trivial, and it removes the last frame-corruption path once retries (Phase 4)
raise the write rate.

**Desk-check:** stress two threads calling `send_command` in a loop against a
loopback serial → every frame decodes intact.

---

### Phase 4 — Robust image download (D4, D5, D6, D8, D14, R3, R4, R5)

**File:** `PC_Bridge/gs_bridge.py`

**4.1 Correct chunk size (D6).** `IMAGE_CHUNK_SIZE = 32` (must equal OBC
`CHUNK_SIZE`); delete the stray `CHUNK_SIZE = 48`.

**4.2 Offset-addressed state (D5).**
```python
download_state = {
    "active": False, "filename": "", "current_chunk": 0,
    "expected_size": 0, "chunks": {}, "highest_chunk": -1,
    "start_time": 0, "last_rx_time": 0, "retries": 0, "deadline": 0,
}
```
Store each chunk by index; assemble on EOT via
`b"".join(chunks[i] for i in sorted(chunks))`.

**4.3 Timeouts (D4).**
```python
CHUNK_TIMEOUT_S       = 2.5   # tune to 4–5x measured median RTT
CHUNK_MAX_RETRIES     = 5
DOWNLOAD_ABSOLUTE_CAP_S = 1800
```
Sizing: a 32 B chunk ≈ 150–250 ms round trip ⇒ ~130–210 B/s ⇒ a 50 KB JPEG ≈
4–7 min. Lab 6's per-chunk ACK window was 1 s, and the new design has no ACK, so
2.5 s comfortably means "lost", not "slow".

**4.4 `service_download()`** runs in the serial thread's 10 ms loop: abort past
`deadline`; on `now - last_rx_time > CHUNK_TIMEOUT_S`, retry the current chunk (up
to `CHUNK_MAX_RETRIES`) then `abort_download(reason)` → broadcast
`download_failed`. This closes the "spinner forever" hole even if the very first
`REQ_CHUNK` was lost.

**4.5 Filename on EVERY REQ_CHUNK (R3).** `request_chunk(idx)` always appends the
(sanitized, ≤30-char) filename, not just on chunk 0. This makes downloads
**reset-proof**: after an OBC watchdog reboot, chunk N still resolves to the right
file. Budget: 2 + 30 = 32 → 56 B on air. OK.

**4.6 Filename safety (D14).**
`safe = os.path.basename(name).replace("\\","").replace("/","")`; reject empty;
save under `DOWNLOAD_DIR/safe`.

**4.7 Real progress (D8).** Cache sizes from the image list
(`known_image_sizes[name] = size` in `parse_image_list`). On start set
`expected_size`. Broadcast:
```python
{"type":"download_progress","data":{
  "chunk":idx,"bytes_received":n,"total_size":expected,   # 0 = unknown
  "percent":pct,"speed_bps":spd,"eta_s":eta,"filename":name}}
```

**4.8 Single-transfer arbitration (R4).** While `download_state["active"]`,
reject `get_eps` / `list_image` / `status` in `ws_handler` with
`{"type":"busy","data":"Download in progress"}`. Prevents two transfers fighting
for the half-duplex link.

**4.9 De-dup idempotent multi-sends (R5).** For `CMD_GPS_DATA` (and bare `ACK`),
drop a packet whose payload is byte-identical to the previous one within ~1 s, so
the 3× GPS send yields one `gps` broadcast, not three toasts.

**Desk-check:** dropped-chunk → retry then complete; dead link → `download_failed`
after 5 retries; reset mid-download (filename re-sent) → correct file; GET EPS
during download → `busy`.

---

### Phase 5 — Dashboard consumption (D8, R1-app)

**Files:** `models/telemetry_data.dart`, `services/websocket_service.dart`,
`screens/dashboard_screen.dart`

1. Extend `DownloadProgress` with `totalSize`, `percent`, `speedBps`,
   `etaSeconds`, `bool get hasTotal`.
2. Handle new messages: `download_failed` and `eps_failed` (clear the relevant
   in-progress flag + error toast + log); `busy` (info toast "Satellite busy —
   finish the current transfer first").
3. **Client-side download watchdog** (mirrors the EPS one): 40 s, refreshed on
   each `download_progress`, cancelled on complete/failed/dispose — so a dead
   *bridge* (not just a dead radio) also resolves the spinner.
4. **Fix the fragile `epsReceiving` derivation:** drive it explicitly
   (`sendGetEps`→true; `eps`/`eps_failed`→false) instead of
   `epsProgress < 100`, closing the last way a stray progress message revives the
   bar.
5. `_downloadCard`: `value: dl.hasTotal ? dl.percent/100 : null`, and show
   `"$percent% · $speed B/s · ETA $eta"` when known.

**Desk-check:** simulate each new message → spinner always resolves; no ghost
"stalled" after a good EPS.

---

### Phase 6 — OBC firmware (D7, D10, R1, D15, D13, D9, R7, S3-8)

**File:** `OBC/OBC.ino`

**6.1 Real beacon (D7).** Use the confirmed sensors:
```c
float battV = powerMonitors[5].getBusVoltage_V();   // 0x48 discharge rail
int pct = (int)((battV - 3.0f) / 1.2f * 100.0f);    // 1S Li-ion — see open Q1
pct = constrain(pct, 0, 100);
float obcTemp = tempSensors[0].readTemperatureC();
beaconData[4] = (uint8_t)pct;
beaconData[5] = (uint8_t)constrain((int)obcTemp, 0, 255);
beaconData[6] = (uint8_t)constrain((int)(battV + 0.5f), 0, 255);
```
Payload stays exactly 8 bytes. If the pack is 2S, only the `3.0f`/`1.2f`
constants change (open Q1). The dashboard should prefer the EPS discharge-rail
voltage when present and fall back to this byte (display-only).

**6.2 Non-blocking chunked TX WITH A QUEUE (D10 + R1).** Convert `sendChunked`
into a scheduled `txJob` serviced by `loop()` — **but back it with a small FIFO**
so a second command during a transfer is not dropped:

```c
struct ChunkJob { uint8_t cmdType; uint8_t blob[200]; uint16_t blobLen; };
ChunkJob jobQueue[3]; uint8_t jobHead=0, jobTail=0;   // ring of pending jobs

bool enqueueChunked(uint8_t cmd, const uint8_t* blob, uint16_t len) {
  uint8_t next = (jobTail + 1) % 3;
  if (next == jobHead) return false;                  // full → caller sends NACK
  jobQueue[jobTail].cmdType = cmd;
  memcpy(jobQueue[jobTail].blob, blob, len);
  jobQueue[jobTail].blobLen = len;
  jobTail = next;
  return true;
}
```
`serviceChunkedTx()` sends the active job's chunks (2 copies, 90 ms apart, byte
-for-byte identical to today), and when a job finishes it pulls the next from the
queue. `sendEPSData` / `sendDeviceHealth` / `CMD_LIST_IMAGE` call
`enqueueChunked`; if it returns false, reply `CMD_NACK` so the dashboard shows
"busy" instead of timing out. **This is the fix for R1 — without the queue the
non-blocking rewrite silently drops the 2nd command.**

Apply the same "send one now, queue the rest" idea to `CMD_GET_GPS` (currently
`3 × 80 ms` blocking).

**Desk-check:** log every `sendPacket`; the emitted byte stream must be identical
to the blocking version for a single transfer, and HEALTH-then-EPS back-to-back
must both complete in order.

**6.3 TAKE_PIC counter + placeholder (D15).** On boot, scan SD for the highest
`img_NNNN.jpg` and set `imageCounter` past it (stops reboot overwrites). Keep the
4-byte stub but log loudly that the camera read is a `TODO` — see §5 caveat.

**6.4 Uplink filename guard (D13).** In `CMD_REQ_CHUNK`, NACK if
`payloadLen - 2 > 30` (keeps the uplink ≤ 64 B; pairs with R3/4.5).

**6.5 EOT size (D9).** Optional: widen the EOT size field to 32-bit (feeds F19).
Skip if staying strictly protocol-frozen; the bridge uses the image-list size
anyway.

**6.6 Error bitmask (R7).** Set `ERR_GPS` when there's no fix / no NMEA for N s;
reserve `ERR_CAM` for when the camera is real. Otherwise the dashboard's
GPS/CAM/I2C error strings can never light up.

**6.7 Rename (S3-8).** `payloadPwrState`→`commPwrState`,
`PAYLOAD_PWR_PIN`→`COMM_PWR_PIN` (they drive Communication/0x59, not a payload).
Pure rename; behaviour is already correct. Prevents a future edit from cutting
the link.

---

### Phase 7 — COMMU / GS robustness (D11, D12)

**File:** `COMMU/COMMU.ino` (+ new `COMMU/build_opt.h`)

**7.1 UART buffer (D11).** `radio.transmit()` blocks ~48 ms; during a transfer a
beacon (~32 B) plus a chunk copy (~44 B) exceeds the 64 B default core buffer.

* **Fix A (supported):** create `COMMU/build_opt.h` with
  `-DSERIAL_RX_BUFFER_SIZE=256 -DSERIAL_TX_BUFFER_SIZE=256`. STM32duino applies
  it when it recompiles the core (a sketch `#define` does **not** work — the core
  is a separate translation unit). CubeProgrammer only flashes the result, so
  nothing changes there. **Verify** by printing `SERIAL_RX_BUFFER_SIZE` once in
  `setup()`.
* **Fix B (fallback, if build_opt.h isn't honoured):** an interrupt-fed 512-byte
  ring buffer on `ObcUART` (single-producer/single-consumer, drop-on-full with a
  counter), consumed by the KISS decoder in `loop()`, so bytes survive the
  blocking transmit.
* Either way, add a **dropped-byte/frame counter** to the debug print.

**File:** `GS/GS.ino`

**7.2 SNR honesty (D12).** `getSNR()` is LoRa-only; in FSK it is a placeholder
(Lab 6 never used it). Keep the byte (frozen tail) but send a deliberate sentinel
and **hide the SNR line in the dashboard** rather than show a fake number.
`constrain` before the `int8` cast to avoid ±12.7 dB sign-wrap. RSSI is genuine
in FSK — keep it.

---

### Phase 8 — Optional polish (R6, R8)

* **R6 — "live" charts.** Either add an opt-in EPS auto-poll (5–10 s, gated by the
  Phase 4.8 arbitration so it never fires mid-download), or relabel "live" →
  "last reading". Decide based on intended UX.
* **R8 — end-to-end image CRC (needs approval — additive protocol change).** Put
  the full 32-bit file CRC in the EOT payload (`FF FF size32 crc32`, still one
  frame ≤ 64 B); the bridge verifies the assembled file and reports pass/fail. If
  the protocol must stay strictly frozen, skip and rely on per-chunk CRC.

---

## 4. Execution order & shippability

| Step | Phases | Reflash? | Delivers |
|---|---|---|---|
| 1 | 1, 2, 3 | no | One bridge; EPS/health/list stop lying; no frame races |
| 2 | 4, 5 | no | Downloads that recover, report %, and never hang |
| 3 | 6, 7 | **yes** | Real telemetry; non-blocking + queued firmware; buffer safe |
| 4 | 8 | maybe | Live charts / image CRC (optional) |

Steps 1–2 are entirely PC-side and can be validated the moment a GS board is
connected — no firmware flash required.

---

## 5. Verification without hardware

Add `PC_Bridge/test_replay.py` feeding synthetic KISS frames into
`process_packet()` / the download state machine and asserting the broadcast
sequence:

1. `c0 c0 c1 c1 c2 c2` → exactly one `eps`, progress 1/3→2/3→3/3, no phantom
   restart. *(D2 regression test.)*
2. Single-chunk health sent twice → one `health`.
3. EPS with a missing chunk → no `eps`, one `eps_failed` after the stale timeout.
4. Download with a dropped chunk → retry, then complete.
5. Download with a dead link → `download_failed` after `CHUNK_MAX_RETRIES`.
6. **Command overlap (R1):** enqueue HEALTH then EPS → both complete in order;
   nothing dropped (or a clean NACK if the queue is full).
7. **Serial-write lock (R2):** two threads hammering `send_command` on a loopback
   → every frame decodes intact.
8. **Reset mid-download (R3):** filename present on chunk 41 → resolves to the
   right file.
9. **Frame-budget assertion (F22):** `24 + 2 + CHUNK_SIZE <= 64` for every
   chunked command, so a future edit to `CHUNK_SIZE` fails loudly.
10. **CRC vector:** one fixed packet, assert OBC-style CRC == `binascii.crc32`.

For Phase 6.2, diff the `sendPacket` byte stream before/after the non-blocking
rewrite — must be identical for a single transfer.

---

## 6. Deliberately NOT changed (protocol frozen)

Packet layout · command byte values · chunk header `[idx][total]` · CRC32 ·
`COPIES = 2` · `CHUNK_SIZE = 32` · AX.25 wrapping · RSSI/SNR tail ·
`radio.transmit`/`readData` call pattern. The bridge is made tolerant of the
existing wire format rather than the firmware changing what it emits. The only
optional additive touch is the EOT CRC (F19/R8), gated behind your approval.

---

## 7. Open questions (confirm on hardware)

1. **Battery chemistry / series count (1S vs 2S).** Sets the `3.0f`/`1.2f`
   constants and the voltage byte in 6.1. Everything else about the battery rail
   is confirmed (index 5 = 0x48).
2. **Measured median round-trip per chunk** → set `CHUNK_TIMEOUT_S` to ~4–5× it
   (2.5 s is a safe default until then).
3. **Does this build path consume `build_opt.h`?** If not, Phase 7.1 Fix B (ring
   buffer) is mandatory, not a fallback.

---

## 8. Non-code caveat that dominates everything

**The image feature has no image yet.** `TAKE_PIC` writes a 4-byte JPEG stub
(camera read is a `TODO`). An end-to-end download test returns a 4-byte file. To
exercise the download path before the camera exists, **put a real `.jpg` on the
SD card and download it by name.** Know this before judging whether "downloads
work".
