# FlatSat — Data Transfer & Display Fix Plan

**Status:** analysis only. No code has been changed.
**Constraints honoured:** the on-air protocol is **frozen** (packet layout, command
bytes, chunk header, CRC32, AX.25 wrapping, RSSI/SNR tail). The COMMU→GS radio
frame stays **≤ 64 bytes**. Nothing here can be tested on hardware right now, so
every fix below is justified from the code and includes a desk-check.

**Revision 2** — updated after receiving the EPS I2C address table, the
STM32duino/CubeProgrammer toolchain confirmation, and a re-read of the Lab 6
reference code. Changes are marked **[R2]**. The confirmations resolve open
questions 1–3 and force a correction to the COMMU buffer fix (see §6).

---

## 0a. Confirmed facts [R2]

**EPS I2C map (from the supplied hardware table) — now authoritative.**

| OBC `powerMonitors[]` index | Addr | Role |
|---|---|---|
| 0 | 0x40 | INA226 · Solar Cell 1 |
| 1 | 0x41 | INA226 · Solar Cell 2 |
| 2 | 0x42 | INA226 · Solar Cell 3 |
| 3 | 0x43 | INA226 · Solar Cell 4 |
| 4 | 0x47 | INA226 · **Battery Charging** |
| 5 | 0x48 | INA226 · **Battery Discharging** |

TMP102 `tempSensors[]`: 0 = 0x4A (Battery 1), 1 = 0x4B (Battery 2).
ADM1177 `powerControllers[]`: 0=0x58 OBC, 1=0x59 COMMS, 2=0x5A Payload1, 3=0x5B Payload2.

This matches the OBC's array ordering **exactly**, so the index-based fixes below
are safe. The battery voltage for the beacon comes from **index 5 (0x48, the
discharge rail)** — the battery's output under load, the correct SoC proxy.
(Note the OBC already calibrates indices 4 and 5 with a 0.01 Ω shunt at
`initEPS()` lines 333–334, consistent with these being the battery rails.)

**Still unknown:** battery chemistry and series count. Battery 1 + Battery 2
behind a BMS could be a 2S pack (≈6.0–8.4 V) rather than 1S (≈3.0–4.2 V). This
changes the SoC formula and the single-byte voltage in the beacon — see §5.1.

**Toolchain:** STM32duino (Arduino_Core_STM32) compiled to a binary, flashed
with STM32CubeProgrammer. This determines *how* the COMMU buffer fix must be
applied — see §6, which was **wrong in revision 1**.

**Architecture note — the new design is NOT Lab 6.** The Lab 6 firmware used a
**stop-and-wait ARQ**: COMMS waited up to 1 s for an RF `"ACK"` from the ground
station (`radio.receive(rfResponse, 1000)`), the GS `delay(50)` then transmitted
`"ACK"`, and the OBC waited `ACK_TIMEOUT_MS = 5000` for a UART ACK and *drove its
own retransmit*, with resume-after-reboot via `state.txt`. The new architecture
**deleted all of that**: COMMU and GS are now dumb transparent relays, so there
is **no link-layer ACK at all**. Reliability now rests entirely on two things:

* **push responses (EPS / health / image-list):** the OBC's `COPIES = 2`
  double-send.
* **pull responses (image download):** the PC bridge re-requesting via
  `REQ_CHUNK`.

Image download therefore has **no redundancy whatsoever** — a single lost
`IMAGE_DATA` frame is fatal unless the bridge re-requests it. That is exactly the
hole in D4, which is why it is the most important download fix.

---

## 0. Frame budget (the hard constraint, verified)

Every downlink frame on the COMMU→GS hop is:

```
AX.25 header            16 bytes
SYNC1 SYNC2 CMD LEN      4 bytes
payload                  N bytes
CRC32                    4 bytes
------------------------------------
total on air        = 24 + N bytes
```

With a 64-byte ceiling: **N ≤ 40 bytes**.

For chunked responses the payload is `[chunkIdx][totalChunks][data...]`, so:

**data per chunk ≤ 38 bytes.**

| Frame | payload N | on air | verdict |
|---|---|---|---|
| Beacon | 8 | 32 | OK |
| ACK (no data) | 0 | 24 | OK |
| ACK + filename `img_0000.jpg` | 12 | 36 | OK |
| GPS_DATA | 14 | 38 | OK |
| Chunked (EPS/health/list), `CHUNK_SIZE 32` | 34 | **58** | OK, 6 bytes margin |
| IMAGE_DATA, `CHUNK_SIZE 32` | 34 | **58** | OK, 6 bytes margin |

**Conclusion: the current sizing is already legal.** `CHUNK_SIZE` must stay at 32
in the OBC. No fix below is allowed to raise it.

Uplink (GS→COMMU) worst case is `REQ_CHUNK` with a filename:
`2 + len(filename)`. A 16-char filename → N=18 → 42 on air. OK. Filenames must
stay **≤ 30 chars** to remain safe; see F13.

---

## 1. Defect register

Severity: **S1** = breaks the feature, **S2** = visibly wrong / stalls, **S3** = latent or cosmetic.

| # | Sev | Component | Defect |
|---|---|---|---|
| D1 | S1 | bridge + app | Bridge is launched twice → port 8080 conflict |
| D2 | S1 | bridge | Duplicate EPS chunk re-opens a phantom transfer → false "stalled" error |
| D3 | S2 | bridge | Same duplicate bug in `reassemble_simple` → double broadcast + stale-chunk corruption |
| D4 | S1 | bridge | Image download has no timeout and no retry — stalls forever |
| D5 | S2 | bridge | Download appends sequentially instead of writing by offset |
| D6 | S2 | bridge | `CHUNK_SIZE = 48` contradicts OBC's 32 (dead today, landmine tomorrow) |
| D7 | S1 | OBC | Beacon battery/temp/voltage are hardcoded mocks (80 / 25 / 12) |
| D8 | S2 | bridge + app | Download progress has no total → indeterminate bar, no % or ETA |
| D9 | S3 | OBC | EOT file size truncated to 16 bits |
| D10 | S2 | OBC | Blocking `delay()` in chunked sends starves UART + GPS |
| D11 | S2 | COMMU | 64-byte default UART RX buffer can overflow during TX |
| D12 | S3 | GS | `getSNR()` is LoRa-only; int8 scaling clips at ±12.7 dB |
| D13 | S3 | OBC/bridge | No filename length guard on the uplink |
| D14 | S3 | bridge | Path traversal via download filename |
| D15 | S2 | OBC | TAKE_PIC writes a 4-byte stub; `imageCounter` resets on reboot |
| D16 | S3 | app | `dart:io` import breaks web builds |

---

## 2. Root-cause detail for the S1 defects

### D1 — The bridge is started twice

`run_mission_control.bat` / `.sh` already does:

```
cd PC_Bridge
start "FlatSat Bridge" /min python gs_bridge.py
```

and then `WebSocketService._startPythonBridge()` (websocket_service.dart:82-114)
independently runs `Process.start('python3', ['gs_bridge.py'])`.

The second instance cannot bind port 8080 and dies with exactly the traceback
already recorded in `PC_Bridge/bridge_log.txt`:

```
OSError: [Errno 98] error while attempting to bind on address ('127.0.0.1', 8080)
```

Two extra problems in the same function:

* On **Windows** the executable is `python3`, which normally does not exist. It
  either throws or triggers the Microsoft Store stub.
* The search paths (`../PC_Bridge`, `../../../../../../PC_Bridge`) are relative
  to the process CWD, which differs between `flutter run` and a packaged build.

### D2 — Duplicate EPS chunk re-opens a phantom transfer

`sendChunked()` (OBC.ino:399-419) sends **every chunk twice** (`COPIES = 2`).
EPS payload is 75 bytes → 3 chunks → the wire sees:

```
c0 c0 c1 c1 c2 c2
```

`handle_eps_chunk()` (gs_bridge.py:451-502) completes on the **first** `c2` and
resets:

```python
eps_reassembly = {"total": 0, "chunks": {}}     # note: no "ts" key
```

The **second** `c2` then arrives. `eps_reassembly.get("total", 0)` is now `0`,
which `!= 3`, so the guard on line 470 treats it as a brand-new transfer:

```python
eps_reassembly = {"total": 3, "chunks": {}, "ts": now}
eps_reassembly["chunks"][2] = data      # 1 of 3
```

and broadcasts `eps_progress` at **33 %** — *after* the `eps` completion message.

Downstream in websocket_service.dart:237-266:

```dart
epsReceiving = epsProgress < 100;        // 33 < 100 → true again
```

so the "Receiving EPS telemetry…" bar reappears, and 8 s later the safety timer
fires **"EPS transfer stalled — try GET EPS again"**.

> **This is why a successful EPS fetch still ends in an error toast.**

### D3 — Same class of bug in `reassemble_simple`

`reassemble_simple()` (gs_bridge.py:380-404) does `del misc_reassembly[key]` on
completion. The duplicate copy then finds no buffer and builds a fresh one.

* **Single-chunk transfers** (device health = 25 bytes, small image lists):
  `len(chunks) >= total` is immediately `1 >= 1`, so the blob **completes a
  second time** and is broadcast twice → duplicate toast, duplicate log line.
* **Multi-chunk transfers**: the duplicate leaves a partial buffer holding the
  *last* chunk. It survives for 4 s. If the operator presses **LIST** again
  inside that window and the chunk count matches, the stale chunk is merged into
  the new blob → **silently corrupted image list**.

### D4 — Image download has no timeout and no retry

`handle_image_chunk()` (gs_bridge.py:507-568) is purely reactive: it only ever
sends the next `REQ_CHUNK` **in response to a received `IMAGE_DATA`**.

Consequences:

* If the initial `REQ_CHUNK` is lost on the uplink, **nothing ever happens** —
  no packet arrives, so no retry is triggered.
* If any `IMAGE_DATA` is lost, the state machine waits **forever**.
* `download_state["active"]` stays `True`, and the dashboard's `isDownloading`
  stays `true` with a spinner that never resolves.
* There is no overall deadline, so a download that is merely *slow* is
  indistinguishable from one that is *dead*.

Unlike EPS (which at least has an 8 s guard in the app), download has **no guard
on either side**.

### D7 — Beacon values are hardcoded

OBC.ino:498-513:

```c
beaconData[4] = 80;   // Battery % (mock/read from EPS)
beaconData[5] = 25;   // OBC Temp (mock/read from sensor)
beaconData[6] = 12;   // Solar Voltage (mock/read from EPS)
```

The dashboard therefore displays **80 % / 25 °C / 12 V permanently**, regardless
of the actual hardware. The EPS sensors that hold the real values are already
initialised and read elsewhere in the same file.

---

## 3. Fix plan

Ordered so each phase is independently testable.

### Phase 1 — Stop the bridge fighting itself (D1)

**File:** `Dashboard/lib/services/websocket_service.dart`

1. **Delete the auto-start entirely** and rely on the launcher scripts, which
   already start the bridge and already kill it on exit. This is the smallest,
   most predictable change and removes the port conflict at its source.
   * Remove `_startPythonBridge()` (lines 82-114).
   * Remove `Process? _bridgeProcess` (line 15) and `_bridgeProcess?.kill()` in
     `dispose()` (line 512).
   * Change the constructor to call `connect()` directly.
   * Remove the now-unused `import 'dart:io'` — this also fixes **D16**.
2. Because the app no longer starts the bridge, `ConnectionStage.bridgeOffline`
   becomes the honest signal when the launcher wasn't used. Update the banner
   copy in `connection_banner.dart` (case `bridgeOffline`) to say: *"Start the
   app with `run_mission_control.bat` (Windows) or `run_mission_control.sh`
   (Linux/Pi)."*

**Alternative if auto-start must be kept** (only if the app is ever launched
without the script): probe first, launch second —
attempt a WebSocket connection, and only spawn the bridge if the connect fails;
use `Platform.isWindows ? 'python' : 'python3'`; resolve the script path from
`Platform.resolvedExecutable` rather than the CWD. This is strictly more code
and more failure modes, so **option 1 is recommended**.

**Desk-check:** grep for `Process.start` → must return nothing. Launch via the
`.bat`, confirm only one `python` process and no `Errno 98` in `bridge_log.txt`.

---

### Phase 2 — Make chunk reassembly duplicate-proof (D2, D3)

This is the highest-value fix and it needs **no protocol change** — it only
changes how the bridge interprets frames it already receives.

**File:** `PC_Bridge/gs_bridge.py`

Introduce one shared, duplicate-aware reassembler and use it for **all three**
chunked types (EPS, image list, health).

**2.1 Add a module-level constant**

```python
# The OBC sends every chunk twice (sendChunked COPIES=2). After a transfer
# completes, the redundant copies keep arriving for roughly
# (chunks * 90ms). Hold the finished transfer for a short window and drop
# anything that belongs to it, instead of mistaking it for a new transfer.
DUPLICATE_GUARD_S = 2.5
REASSEMBLY_STALE_S = 4.0
```

**2.2 Replace the buffer shape**

Each reassembly entry becomes:

```python
{
    "total": int,
    "chunks": {idx: bytes},
    "ts": float,        # last chunk seen
    "done": bool,       # transfer already delivered
}
```

**2.3 New unified function** (replaces both `reassemble_simple` and the
reassembly half of `handle_eps_chunk`):

```python
def reassemble(key, payload, payload_len, on_progress=None):
    """
    Chunk = [chunkIdx][totalChunks][data...].
    Returns the complete blob exactly once, else None.

    Handles the OBC's duplicate sends:
      - a repeat of an already-stored chunk is ignored (no progress spam)
      - chunks arriving after completion are dropped for DUPLICATE_GUARD_S
        instead of starting a phantom transfer
    """
    if payload_len < 2:
        return None
    chunk_idx = payload[0]
    total     = payload[1]
    if total == 0:
        return None
    data = bytes(payload[2:payload_len])
    now  = time.time()

    buf = _reassembly.get(key)

    # Drop the tail of a transfer we already delivered.
    if buf and buf["done"]:
        if now - buf["ts"] <= DUPLICATE_GUARD_S:
            buf["ts"] = now          # keep swallowing the echo
            return None
        buf = None                   # guard expired → genuinely new transfer

    # Start fresh on: no buffer, changed chunk count, or a stale buffer.
    if buf is None or buf["total"] != total or now - buf["ts"] > REASSEMBLY_STALE_S:
        buf = {"total": total, "chunks": {}, "ts": now, "done": False}
        _reassembly[key] = buf

    is_new_chunk = chunk_idx not in buf["chunks"]
    buf["chunks"][chunk_idx] = data
    buf["ts"] = now

    if on_progress and is_new_chunk:
        on_progress(len(buf["chunks"]), total,
                    sum(len(v) for v in buf["chunks"].values()))

    if all(i in buf["chunks"] for i in range(total)):
        buf["done"] = True                       # keep the entry as a tombstone
        buf["chunks"] = {i: buf["chunks"][i] for i in range(total)}
        return b"".join(buf["chunks"][i] for i in range(total))
    return None
```

Key behaviours, and why each matters:

* `done` acts as a **tombstone** rather than deleting the entry — this is what
  stops the duplicate from being read as a new transfer (fixes D2 and D3).
* Progress fires **only on genuinely new chunks**, so the duplicate copies no
  longer produce redundant `eps_progress` messages.
* `DUPLICATE_GUARD_S = 2.5` comfortably covers the echo window
  (3 chunks × 2 copies × 90 ms ≈ 540 ms) while still allowing a deliberate
  re-request a few seconds later.

**2.4 Rewire the three call sites**

```python
elif cmd_type == CMD_IMAGE_LIST:
    blob = reassemble("image", payload, payload_len)
    if blob is not None:
        ...

elif cmd_type == CMD_HEALTH_DATA:
    blob = reassemble("health", payload, payload_len)
    if blob is not None:
        ...

elif cmd_type == CMD_EPS_DATA:
    def _progress(received, total, nbytes):
        schedule_broadcast({"type": "eps_progress", "data": {
            "received": received, "total": total,
            "percent": int(received * 100 / total), "bytes": nbytes}})
    blob = reassemble("eps", payload, payload_len, on_progress=_progress)
    if blob is not None:
        eps = parse_eps_payload(blob)
        if eps:
            latest_telemetry["eps"] = eps
            schedule_broadcast({"type": "eps", "data": eps})
        else:
            schedule_broadcast({"type": "eps_failed",
                                "data": "EPS payload could not be decoded"})
```

Delete the old `eps_reassembly` / `misc_reassembly` globals and
`handle_eps_chunk`, replacing them with a single `_reassembly = {}`.

**2.5 Add a reassembly watchdog**

A transfer that loses a chunk entirely never completes. Add to the serial
thread's periodic section (next to the existing link-timeout check):

```python
for key, buf in list(_reassembly.items()):
    if not buf["done"] and time.time() - buf["ts"] > REASSEMBLY_STALE_S:
        missing = [i for i in range(buf["total"]) if i not in buf["chunks"]]
        log.warning(f"{key} transfer abandoned, missing chunks {missing}")
        del _reassembly[key]
        if key == "eps":
            schedule_broadcast({"type": "eps_failed",
                                "data": f"Lost chunk(s) {missing} — press GET EPS again"})
```

**Desk-check:** simulate `c0 c0 c1 c1 c2 c2` → exactly one `eps` broadcast,
progress at 1/3 → 2/3 → 3/3 with no fourth message, and no phantom restart.

---

### Phase 3 — Give the image download a real state machine (D4, D5, D6, D8)

**File:** `PC_Bridge/gs_bridge.py`

**3.1 Correct the chunk size**

```python
# MUST match CHUNK_SIZE in OBC.ino. The 48 here was inherited from the
# Lab 6 script, where the OBC used a different value.
IMAGE_CHUNK_SIZE = 32
```

Remove the old `CHUNK_SIZE = 48`.

**3.2 Extend `download_state`**

```python
download_state = {
    "active": False,
    "filename": "",
    "current_chunk": 0,
    "expected_size": 0,        # from the image list, 0 = unknown
    "chunks": {},              # idx -> bytes  (offset-addressed, like Lab 6)
    "highest_chunk": -1,
    "start_time": 0,
    "last_rx_time": 0,         # for the per-chunk timeout
    "retries": 0,              # consecutive retries of the current chunk
    "deadline": 0,             # absolute overall deadline
}
```

**3.3 Timeout / retry constants**

```python
# One chunk is 32 bytes. On air a frame is 58 bytes at 9.6 kbps ≈ 48 ms each
# way, plus OBC SD read and turnaround, so a healthy round trip is well under
# 1 s. 2.5 s therefore means "lost", not "slow".
CHUNK_TIMEOUT_S       = 2.5
CHUNK_MAX_RETRIES     = 5      # per chunk before aborting
DOWNLOAD_MAX_STALL_S  = 30     # no forward progress at all → abort
DOWNLOAD_ABSOLUTE_CAP_S = 1800 # 30 min hard ceiling
```

Sizing rationale, so these can be re-tuned with confidence:

* A 32-byte chunk needs one uplink `REQ_CHUNK` (42 bytes on air) and one
  downlink `IMAGE_DATA` (58 bytes on air) ≈ **~90 ms of pure airtime** at
  9.6 kbps, plus SD seek/read and two UART hops.
* Realistic throughput is therefore **~150–250 ms per chunk ⇒ 130–210 B/s**.
* A 50 KB JPEG ⇒ **~1600 chunks ⇒ 4–7 minutes**. The 30-minute cap is
  deliberately generous; the per-chunk timeout is what actually detects failure.

**[R2] Cross-check against Lab 6 timing.** The Lab 6 reference budgeted **1 s**
for the RF ACK window per chunk (`radio.receive(rfResponse, 1000)`) and **5 s**
for the OBC's UART ACK wait (`ACK_TIMEOUT_MS`). Those numbers included a full
reliable-ARQ handshake that the new architecture no longer performs, so the new
per-chunk round trip should be *shorter* than Lab 6's 1 s. `CHUNK_TIMEOUT_S =
2.5` therefore sits comfortably above the expected round trip with margin for SD
latency — a safe starting value. Once hardware is available, measure the real
median round trip and set the timeout to roughly **4–5× the median** (this is
open question 4).

**3.4 Store by offset, not by append** (adopts the Lab 6 pattern)

```python
chunk_id   = struct.unpack('>H', payload[:2])[0]
chunk_data = bytes(payload[2:payload_len])

# Absolute addressing tolerates duplicates and out-of-order arrival.
download_state["chunks"][chunk_id] = chunk_data
download_state["highest_chunk"] = max(download_state["highest_chunk"], chunk_id)
download_state["last_rx_time"] = time.time()

if chunk_id == download_state["current_chunk"]:
    # Advance past anything already buffered (handles a late duplicate
    # filling a gap we had skipped).
    while download_state["current_chunk"] in download_state["chunks"]:
        download_state["current_chunk"] += 1
    download_state["retries"] = 0
    request_chunk(download_state["current_chunk"])
```

On EOT, assemble in index order:

```python
blob = b"".join(download_state["chunks"][i]
                for i in sorted(download_state["chunks"]))
```

**3.5 The timeout driver**

`handle_image_chunk` stays reactive, but a **new periodic check runs in the
serial thread** (which already loops every 10 ms):

```python
def service_download():
    if not download_state["active"]:
        return
    now = time.time()

    if now > download_state["deadline"]:
        abort_download("Download exceeded the maximum allowed time")
        return

    if now - download_state["last_rx_time"] > CHUNK_TIMEOUT_S:
        if download_state["retries"] >= CHUNK_MAX_RETRIES:
            abort_download(
                f"No response for chunk #{download_state['current_chunk']} "
                f"after {CHUNK_MAX_RETRIES} retries")
            return
        download_state["retries"] += 1
        log.warning(f"Chunk #{download_state['current_chunk']} timed out, "
                    f"retry {download_state['retries']}/{CHUNK_MAX_RETRIES}")
        request_chunk(download_state["current_chunk"])
        download_state["last_rx_time"] = now   # restart the timer
```

`request_chunk(idx)` sends the filename **only on chunk 0** (matching the
existing OBC behaviour, which caches `downloadFilename`) — but on a **retry of
chunk 0** the filename must be re-sent, because the OBC may never have received
the original.

`abort_download(reason)` clears the state and broadcasts:

```python
schedule_broadcast({"type": "download_failed",
                    "data": {"filename": ..., "reason": reason,
                             "bytes_received": ...}})
```

This closes the "stuck spinner forever" hole.

**3.6 Progress with a real percentage (D8)**

The bridge already learns each file's size in `parse_image_list`. Cache it:

```python
known_image_sizes = {}   # filename -> size, filled in by CMD_IMAGE_LIST
```

On download start, set `download_state["expected_size"] = known_image_sizes.get(filename, 0)`.
Then broadcast:

```python
{"type": "download_progress", "data": {
    "chunk": chunk_id,
    "bytes_received": total,
    "total_size": download_state["expected_size"],   # 0 = unknown
    "percent": pct,                                  # -1 when unknown
    "speed_bps": speed,
    "eta_s": eta,                                    # -1 when unknown
    "filename": ...,
}}
```

This uses the **image list** for the size rather than the EOT field, which
sidesteps D9 (the EOT size is truncated to 16 bits and would be wrong for any
file over 64 KB). No protocol change either way.

**3.7 Guard the filename (D14)**

```python
safe_name = os.path.basename(filename).replace("\\", "").replace("/", "")
if not safe_name:
    reject
save_path = os.path.join(DOWNLOAD_DIR, safe_name)
```

---

### Phase 4 — Dashboard side of downloads (D8, D17)

**File:** `Dashboard/lib/models/telemetry_data.dart`

Extend `DownloadProgress`:

```dart
final int totalSize;    // 0 = unknown
final int percent;      // -1 = unknown
final double speedBps;
final int etaSeconds;   // -1 = unknown
bool get hasTotal => totalSize > 0 && percent >= 0;
```

**File:** `Dashboard/lib/services/websocket_service.dart`

1. Handle the new `download_failed` message: clear `isDownloading`, clear
   `downloadProgress`, `_flash(reason, error: true)`, log it.
2. Handle the new `eps_failed` message the same way (clears `epsReceiving`).
3. Add a **client-side watchdog** mirroring the EPS one, so a dead bridge (not
   just a dead radio link) also resolves the spinner:

```dart
Timer? _downloadWatchdog;
// armed in sendDownload / refreshed on every download_progress
_downloadWatchdog = Timer(const Duration(seconds: 40), () {
  if (isDownloading) {
    isDownloading = false;
    _flash('Download stalled — no progress from the bridge', error: true);
    notifyListeners();
  }
});
```

Cancel it in `download_complete`, `download_failed`, and `dispose()`.

4. **Fix the fragile `epsReceiving` derivation.** Replace
   `epsReceiving = epsProgress < 100` with explicit lifecycle:
   * `sendGetEps()` → `epsReceiving = true`
   * `eps` → `false`
   * `eps_failed` → `false`
   * `eps_progress` → leave as-is, only update numbers.

   This removes the last way a stray progress message can resurrect the bar.

**File:** `Dashboard/lib/screens/dashboard_screen.dart`

`_downloadCard` currently hardcodes `LinearProgressIndicator(value: null)`.
Change to:

```dart
value: dl.hasTotal ? dl.percent / 100.0 : null,
```

and show `"$percent% · ${speed} B/s · ETA ${eta}"` when known, falling back to
the current byte counter when not.

---

### Phase 5 — OBC firmware (D7, D10, D15, D9)

**File:** `OBC/OBC.ino`

**5.1 Real beacon values (D7)** — the sensors are already initialised.

```c
void sendBeacon() {
  checkHardware();

  // Battery: derive from the discharge-rail INA226 (index 5, 0x48).
  float battV = powerMonitors[5].getBusVoltage_V();
  // Li-ion 3.0 V (empty) .. 4.2 V (full), clamped to 0..100.
  int pct = (int)((battV - 3.0f) / 1.2f * 100.0f);
  if (pct < 0)   pct = 0;
  if (pct > 100) pct = 100;

  float obcTemp = tempSensors[0].readTemperatureC();

  uint8_t beaconData[8];
  beaconData[0] = systemErrors;
  beaconData[1] = payloadPwrState ? 1 : 0;
  beaconData[2] = gpsPwrState ? 1 : 0;
  beaconData[3] = camPwrState ? 1 : 0;
  beaconData[4] = (uint8_t)pct;
  beaconData[5] = (uint8_t)constrain((int)obcTemp, 0, 255);
  beaconData[6] = (uint8_t)constrain((int)(battV + 0.5f), 0, 255);
  beaconData[7] = (millis() - lastAckTime < LINK_TIMEOUT) ? 1 : 0;

  sendPacket(CMD_BEACON, beaconData, 8);
}
```

Payload stays **exactly 8 bytes** — the wire format is unchanged, only the
values become real.

> **[R2] Battery-rail index is now confirmed** by the hardware table: index 5 =
> 0x48 = "Battery Discharging", the correct rail. What is **still unconfirmed** is
> the pack chemistry / series count. The `3.0f` and `1.2f` constants above assume
> a **1S Li-ion** pack. If Battery 1 + Battery 2 behind the BMS form a **2S** pack
> the true range is ≈6.0–8.4 V, so both constants (and the `constrain` on the raw
> voltage byte) must change. Until confirmed, treat the percentage as
> provisional; the *raw* discharge voltage from GET EPS is exact regardless.
>
> The beacon carries voltage as a **whole number of volts** in one byte, so it
> reads `4` for a 4.1 V cell (or `8` for a 2S pack). The precise value is already
> available via GET EPS; the dashboard should prefer the EPS discharge-rail
> voltage (index 5) when present and fall back to the beacon byte otherwise — no
> firmware or protocol change needed, only a display tweak in `dashboard_screen.dart`.

**5.2 Non-blocking chunked send (D10)**

`sendChunked()` currently blocks for `chunks × 2 × 90 ms` (EPS ≈ 540 ms, a large
image list ≈ 1.26 s). During that window `processIncomingUART()` never runs and
`GpsUART` is never drained — at 9600 baud that discards **hundreds of NMEA
bytes**, degrading the GPS fix.

Convert to a scheduled queue that `loop()` services:

```c
struct ChunkTxJob {
  bool     active;
  uint8_t  cmdType;
  uint8_t  blob[200];
  uint16_t blobLen;
  uint8_t  totalChunks;
  uint8_t  chunkIdx;
  uint8_t  copy;            // 0 or 1
  unsigned long nextSendAt;
};
ChunkTxJob txJob = {0};

void queueChunked(uint8_t cmdType, const uint8_t *blob, uint16_t blobLen) {
  if (txJob.active) return;               // one transfer at a time
  memcpy(txJob.blob, blob, blobLen);
  txJob.blobLen     = blobLen;
  txJob.cmdType     = cmdType;
  txJob.totalChunks = (blobLen + EPS_CHUNK_SIZE - 1) / EPS_CHUNK_SIZE;
  if (txJob.totalChunks == 0) txJob.totalChunks = 1;
  txJob.chunkIdx = 0;
  txJob.copy     = 0;
  txJob.nextSendAt = millis();
  txJob.active   = true;
}

void serviceChunkedTx() {
  if (!txJob.active || (long)(millis() - txJob.nextSendAt) < 0) return;

  uint16_t off = (uint16_t)txJob.chunkIdx * EPS_CHUNK_SIZE;
  uint8_t  len = (txJob.blobLen - off > EPS_CHUNK_SIZE)
                 ? EPS_CHUNK_SIZE : (uint8_t)(txJob.blobLen - off);
  uint8_t part[EPS_CHUNK_SIZE + 2];
  part[0] = txJob.chunkIdx;
  part[1] = txJob.totalChunks;
  memcpy(&part[2], &txJob.blob[off], len);
  sendPacket(txJob.cmdType, part, len + 2);

  txJob.nextSendAt = millis() + 90;
  if (++txJob.copy >= 2) {
    txJob.copy = 0;
    if (++txJob.chunkIdx >= txJob.totalChunks) txJob.active = false;
  }
}
```

`loop()` gains `serviceChunkedTx();` and `sendEPSData` / `sendDeviceHealth` /
`CMD_LIST_IMAGE` call `queueChunked` instead of `sendChunked`.

**The emitted byte stream is byte-for-byte identical** — same chunks, same two
copies, same 90 ms spacing. Only the blocking is removed.

Apply the same treatment to `CMD_GET_GPS` (currently `3 × 80 ms` blocking): send
the first copy immediately and queue the other two.

**5.3 TAKE_PIC placeholder + counter (D15)**

* On boot, scan the SD root once and set `imageCounter` to
  `highest existing img_NNNN + 1`, so a reboot stops overwriting images.
* Leave the 4-byte JPEG stub, but **log loudly** that it is a placeholder — the
  camera FIFO read is still a `TODO`. Note in the plan that any download test
  will therefore return a 4-byte file until the camera is implemented; use a
  real file copied onto the SD card to exercise the download path.

**5.4 Filename guard (D13)**

In `CMD_REQ_CHUNK`, reject `payloadLen - 2 > 30` with a NACK, keeping the uplink
frame inside the 64-byte budget.

---

### Phase 6 — COMMU / GS robustness (D11, D12)

**File:** `COMMU/COMMU.ino` (+ a new `COMMU/build_opt.h`)

**The problem.** `radio.transmit()` blocks while a frame goes out
(~48 ms for a 58-byte frame at 9.6 kbps). STM32duino's default
`SERIAL_RX_BUFFER_SIZE` is **64 bytes**. During a transfer the OBC sends beacons
(every ~1 s) and chunk copies down the *same* `CommsUART`; if a beacon
(~32 B KISS) lands while COMMU is finishing a previous frame and the next chunk
copy (~44 B KISS) arrives, 32 + 44 = 76 B > 64 B and the tail is dropped
silently. The OBC's 90 ms pacing keeps this rare, but it is real.

**[R2] Correction to revision 1.** Rev 1 said to `#define SERIAL_RX_BUFFER_SIZE`
in the sketch. **That does not work on STM32duino.** The core's
`HardwareSerial.cpp` is compiled as a *separate translation unit* from the
`.ino`, so a `#define` in the sketch never reaches it. Verified against the
[stm32duino HardwareSerial source](https://github.com/stm32duino/Arduino_Core_STM32/blob/main/cores/arduino/HardwareSerial.cpp)
and [issue #778](https://github.com/stm32duino/Arduino_Core_STM32/issues/778):
the value **is** honoured, but only when supplied as a **compiler define** that
applies to the whole core.

**Fix A — the supported way (do this first).** Add a `build_opt.h` next to
`COMMU.ino` containing:

```
-DSERIAL_RX_BUFFER_SIZE=256 -DSERIAL_TX_BUFFER_SIZE=256
```

STM32duino automatically picks up `build_opt.h` and applies these flags when it
recompiles the core, so `ObcUART`'s ring buffer becomes 256 bytes. In Arduino
IDE the file simply lives in the sketch folder; if the project is ever moved to
PlatformIO the same flags go under `build_flags`. 256 B holds ~5 worst-case
frames, which the 90 ms pacing cannot outrun.

> Toolchain caveat: `build_opt.h` is consumed by the **Arduino/STM32duino build**,
> not by STM32CubeProgrammer. CubeProgrammer only flashes the resulting binary,
> so nothing changes there — but it does mean the flag must be present at
> *compile* time. After adding it, confirm the larger buffer took effect (e.g.
> print `SERIAL_RX_BUFFER_SIZE` once in `setup()`); if the build system ignores
> `build_opt.h`, fall through to Fix B.

**Fix B — the guaranteed fallback the user asked for: a custom RX ring buffer.**
If `build_opt.h` is not honoured in this setup, do not rely on the core buffer at
all. Attach an interrupt-fed software ring buffer to the OBC UART so bytes are
captured even while `radio.transmit()` blocks:

```c
// 512-byte power-of-two ring, lock-free single-producer/single-consumer.
static volatile uint8_t  obcRing[512];
static volatile uint16_t obcHead = 0;   // written by RX interrupt
static volatile uint16_t obcTail = 0;   // read by loop()
static const uint16_t   OBC_RING_MASK = 511;

void obcRxISR() {
  while (ObcUART.available()) {
    uint16_t next = (obcHead + 1) & OBC_RING_MASK;
    if (next != obcTail) {           // drop on full rather than clobber
      obcRing[obcHead] = (uint8_t)ObcUART.read();
      obcHead = next;
    } else {
      (void)ObcUART.read();          // discard + bump a dropped-byte counter
    }
  }
}
```

Register it with `ObcUART.attachInterrupt(obcRxISR)` (STM32duino supports a
per-instance RX callback), and have the KISS decoder in `loop()` consume from the
ring (`obcTail`) instead of calling `ObcUART.read()` directly. The ISR keeps
draining the hardware FIFO during the blocking transmit, so nothing is lost.
This is strictly more code than Fix A, hence "fallback".

> Either fix, also add a **dropped-frame / dropped-byte counter** surfaced in the
> debug print, so an overflow becomes visible instead of a silently truncated
> frame that later fails CRC on the OBC.

* Optional, non-protocol: check the AX.25 destination callsign in `unwrapAX25`
  and ignore frames not addressed to `FLTSAT` (COMMU) / `GROUND` (GS). This
  prevents cross-talk when several kits share 433.0 MHz in a classroom.

**File:** `GS/GS.ino`

* **[R2] Confirmed:** the Lab 6 GroundStation reference **never read RSSI or SNR
  at all** — it only decoded KISS and checked an XOR-8 checksum. The whole
  RSSI/SNR tail is a *new-architecture invention with no validated precedent*,
  which is why it deserves scrutiny.
* `radio.getSNR()` is a **LoRa** measurement; on the SX1278 in **FSK** mode it is
  not meaningful (RadioLib returns a placeholder). The protocol tail is frozen,
  so keep sending the byte, but make it honest: send a deliberate sentinel and
  have the dashboard **hide the SNR line** rather than show a fabricated figure.
* `int8_t snrInt = (int8_t)(snr * 10)` clips at **±12.7 dB**; a raw SNR beyond
  that wraps sign. If the byte is kept, `constrain` before the cast.
* **RSSI is genuine in FSK on the SX127x** (RadioLib exposes current-packet RSSI
  in FSK) and is worth keeping. Only SNR is the questionable field.

---

## 4. Execution order

| Phase | Fixes | Why this order |
|---|---|---|
| 1 | D1, D16 | Nothing else can be observed reliably while two bridges fight for port 8080 |
| 2 | D2, D3 | Pure bridge logic, no hardware needed, removes the false error everyone sees |
| 3 | D4, D5, D6, D8, D14 | Download becomes recoverable and reports real progress |
| 4 | D8, D17 | Dashboard consumes the new messages |
| 5 | D7, D9, D10, D13, D15 | Firmware reflash required — batch it |
| 6 | D11, D12 | Robustness; reflash COMMU/GS together with Phase 5 |

Phases 1–4 are **PC-side only** and need no reflash, so they can be validated as
soon as a GS board is connected.

---

## 5. Verification without hardware

Since nothing can be tested on the bench right now:

1. **Offline replay harness.** Add `PC_Bridge/test_replay.py` that feeds
   synthetic KISS frames into `process_packet()` and asserts the broadcast
   sequence. Cases that must pass:
   * `c0 c0 c1 c1 c2 c2` → exactly one `eps`, progress 1/3→2/3→3/3, **no**
     phantom restart (this is the D2 regression test).
   * single-chunk health sent twice → exactly one `health` broadcast.
   * EPS with `c1` missing → no `eps`, one `eps_failed` after the stale timeout.
   * Image download with a dropped chunk → retry fires, then completes.
   * Image download with a permanently dead link → `download_failed` after
     `CHUNK_MAX_RETRIES`.
2. **Frame-budget assertion.** A unit check that
   `24 + 2 + CHUNK_SIZE <= 64` for every chunked command, so a future edit to
   `CHUNK_SIZE` fails loudly instead of silently truncating on air.
3. **Byte-stream equivalence for Phase 5.2.** Before/after the non-blocking
   rewrite, log every `sendPacket` call and diff the sequences — they must be
   identical.
4. **CRC cross-check.** `binascii.crc32` vs the OBC's bit-banged CRC32 were
   compared by inspection and **match** (reflected, init `0xFFFFFFFF`, poly
   `0xEDB88320`, final XOR). Add one test vector to lock this in.

---

## 6. Deliberately NOT changed

To be explicit about the constraints given:

* **Packet layout** — `SYNC1 SYNC2 CMD LEN payload CRC32` is untouched.
* **Command byte values** — untouched.
* **Chunk header** `[idx][total]` — untouched.
* **`COPIES = 2` redundancy** — kept; the bridge is fixed to tolerate it rather
  than the firmware being changed to stop it.
* **`CHUNK_SIZE = 32`** — kept. It is already inside the 64-byte budget with
  6 bytes of margin. Raising it to 38 would still fit but would remove the
  margin, and is not required to fix any defect here.
* **AX.25 wrapping and the RSSI/SNR tail** — untouched.
* **`radio.transmit` / `readData` call pattern** — untouched.

---

## 7. Open questions

**Resolved in R2:**

1. ~~Which INA226 index is the battery rail?~~ **Answered:** index 5 (0x48,
   Battery Discharging). Only the pack **chemistry / series count** remains open
   — it sets the SoC constants in §5.1 (1S vs 2S). *Confirm on hardware.*
2. ~~Does the STM32 core honour `SERIAL_RX_BUFFER_SIZE`?~~ **Answered:** yes, but
   only via `build_opt.h` (`-DSERIAL_RX_BUFFER_SIZE=256`), not a sketch
   `#define`. §6 now has Fix A (build_opt.h) and Fix B (custom ring buffer)
   accordingly.
3. ~~Does `getSNR()` work in FSK?~~ **Answered:** no — it is LoRa-only on the
   SX1278, and Lab 6 never used it. RSSI is valid in FSK; SNR should be hidden.

**Still to confirm on hardware:**

4. Battery pack chemistry / series count (1S vs 2S) — finalises §5.1.
5. Actual measured median round-trip time per image chunk — set
   `CHUNK_TIMEOUT_S` to ~4–5× that median (currently 2.5 s as a safe default).
6. Whether this project's build path actually consumes `build_opt.h`; if not,
   §6 Fix B (ring buffer) is mandatory rather than a fallback.
