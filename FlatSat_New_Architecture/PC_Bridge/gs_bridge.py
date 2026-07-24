"""
FlatSat New Architecture
PC Bridge: GS Serial (KISS) <-> WebSocket (JSON) for Flutter Dashboard

Features:
- KISS decode/encode over serial to the GS STM32
- CRC32 verification of all application packets
- Resumable image download state machine
- Link timeout detection
- RSSI/SNR extraction from GS-injected metadata
- Full command support: ping, status, take_pic, get_gps, toggle_pwr,
  list_image, remove_image, download, beacon
- WebSocket server on ws://localhost:8080
"""

import serial
from serial.tools import list_ports
import sys
import time
import struct
import binascii
import asyncio
import websockets
import json
import threading
import os
import logging

# ====================================================================
# LOGGING
# ====================================================================
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s: %(message)s',
    datefmt='%H:%M:%S'
)
log = logging.getLogger("gs_bridge")

# ====================================================================
# CONFIGURATION
# ====================================================================
# Fallback port if auto-detection finds nothing. You can also override the
# port without editing this file, in priority order:
#   1. Command-line arg:   python3 gs_bridge.py /dev/ttyACM0   (or COM4, etc.)
#   2. Env var:            FLATSAT_SERIAL_PORT=/dev/ttyACM0 python3 gs_bridge.py
#   3. Auto-detect         (STM32 native-USB shows up as ttyACM* / usbmodem*)
SERIAL_PORT = '/dev/ttyUSB0'
BAUD_RATE = 115200


def _is_usb_serial(dev: str) -> bool:
    """Keep only real USB serial ports. Drop legacy motherboard UARTs
    (/dev/ttyS0..31) and the Pi's own UART (/dev/ttyAMA*) — they are never the
    Ground Station, always error on open, and just slow the probe down 20 s."""
    if not dev:
        return False
    base = dev.lower().rsplit('/', 1)[-1]
    if base.startswith('ttys') and base[4:].isdigit():
        return False
    if base.startswith('ttyama'):
        return False
    return True


def autodetect_serial_port():
    """Resolve the GS serial port. Explicit override wins; otherwise scan the
    connected serial devices and prefer STM32-style native-USB (CDC ACM)."""
    # 1. Explicit overrides
    if len(sys.argv) > 1 and sys.argv[1].strip():
        return sys.argv[1].strip()
    env_port = os.environ.get("FLATSAT_SERIAL_PORT", "").strip()
    if env_port:
        return env_port

    # 2. Scan available ports
    ports = list(list_ports.comports())
    if not ports:
        return None

    def rank(dev: str) -> int:
        d = dev.lower()
        if 'acm' in d or 'usbmodem' in d:   # STM32 native USB (most likely GS)
            return 0
        if 'usbserial' in d or 'slab' in d or 'wch' in d or 'ttyusb' in d:
            return 1                         # FTDI / CP210x / CH340 adapters
        if d.startswith('com'):              # Windows
            return 1
        return 2

    # Filter out Bluetooth ports (opening them can hang on Windows) and legacy
    # motherboard UARTs (/dev/ttyS*, which error and waste ~20 s of probing).
    valid_ports = [p for p in ports
                   if "bluetooth" not in (p.description or "").lower()
                   and _is_usb_serial(p.device)]
    
    devices = sorted((p.device for p in valid_ports), key=lambda dev: rank(dev))
    if not devices:
        return None
    # A name-based guess is not enough: OBC/COMMU *debug* consoles also show up
    # as ttyACM*, and the GS KISS link may be a USB-UART adapter (ttyUSB*).
    # Probe each candidate for real KISS traffic and pick the first that talks.
    if len(devices) > 1:
        proven = probe_ports_for_kiss(devices)
        if proven:
            return proven
        log.warning("No port produced KISS data during probing — "
                    f"falling back to {devices[0]}. If that is a debug console, "
                    "pick the GS port manually in the dashboard's port selector.")
    return devices[0]


def _looks_like_kiss(buf: bytes) -> bool:
    """True if buf contains a KISS frame with our AA BB sync inside."""
    return b'\xc0' in buf and b'\xaa\xbb' in buf


def probe_ports_for_kiss(devices, listen_s=3.0):
    """Open each port, send a PING and listen briefly for a valid KISS frame.
    Two passes: a quick one, then a long one covering the 10 s beacon interval."""
    for pass_listen in (listen_s, 11.0):
        for dev in devices:
            try:
                with serial.Serial(dev, BAUD_RATE, timeout=0.2) as s:
                    s.reset_input_buffer()
                    try:
                        s.write(build_packet(CMD_PING))
                    except Exception:
                        pass
                    deadline = time.time() + pass_listen
                    buf = bytearray()
                    while time.time() < deadline:
                        buf += s.read(256)
                        if _looks_like_kiss(bytes(buf)):
                            log.info(f"Probe: KISS traffic detected on {dev}")
                            return dev
                    log.info(f"Probe: no KISS data on {dev} "
                             f"({len(buf)} bytes seen — likely a debug console)")
            except Exception as e:
                log.info(f"Probe: cannot open {dev}: {e}")
    return None
WS_HOST = 'localhost'
WS_PORT = 8080
DOWNLOAD_DIR = './downloads'
LINK_TIMEOUT_S = 15  # Seconds without a packet before link is "LOST"

# Image download tuning. IMAGE_CHUNK_SIZE MUST equal the OBC's CHUNK_SIZE (32).
IMAGE_CHUNK_SIZE = 32
# Frame-budget guard (F22): AX.25(16)+header/CRC(8)+[idx][total](2)+data must
# stay within the 64-byte radio frame. Fails loudly if anyone raises the size.
assert 24 + 2 + IMAGE_CHUNK_SIZE <= 64, "Chunk too large for the 64-byte radio frame"
CHUNK_TIMEOUT_S = 2.5           # no chunk within this -> retry (~4-5x median RTT)
CHUNK_MAX_RETRIES = 5
DOWNLOAD_ABSOLUTE_CAP_S = 1800  # hard ceiling for one download

# Image sizes learned from the last LIST, so downloads can show a real %.
known_image_sizes = {}

# ====================================================================
# KISS PROTOCOL CONSTANTS
# ====================================================================
FEND  = 0xC0
FESC  = 0xDB
TFEND = 0xDC
TFESC = 0xDD

# ====================================================================
# COMMAND BYTE DEFINITIONS (Must match OBC firmware)
# ====================================================================
CMD_PING         = 0x01
CMD_ACK          = 0x02
CMD_BEACON       = 0x03
CMD_TAKE_PIC     = 0x04
CMD_GET_GPS      = 0x05
CMD_TOGGLE_PWR   = 0x06
CMD_LIST_IMAGE   = 0x07
CMD_REMOVE_IMAGE = 0x08
CMD_REQ_CHUNK    = 0x09
CMD_STATUS       = 0x0A
CMD_IMAGE_DATA   = 0x0B
CMD_GPS_DATA     = 0x0C
CMD_IMAGE_LIST   = 0x0D
CMD_NACK         = 0x0E
CMD_GET_EPS      = 0x0F
CMD_EPS_DATA     = 0x10
CMD_HEALTH_DATA  = 0x11
CMD_SET_TIME     = 0x12
CMD_EPS_LOG_CFG  = 0x13
CMD_GET_EPS_LOG  = 0x14
CMD_EPS_LOG_DATA = 0x15
CMD_EPS_LOG_CLEAR = 0x16

# ====================================================================
# APPLICATION STATE
# ====================================================================
latest_telemetry = {
    "system_errors": 0,
    "payload_pwr": False,
    "gps_pwr": False,
    "cam_pwr": False,
    "battery_pct": 0,
    "temperature": 0,
    "voltage": 0,
    "link_status": "LOST",
    "rssi": 0.0,
    "snr": 0.0,
    "last_packet_time": 0,
    "eps": None,
}

# WebSocket clients
connected_clients = set()

# Download Manager (offset-addressed: store each chunk by index, assemble on EOT)
download_state = {
    "active": False,
    "filename": "",
    "current_chunk": 0,     # next in-order chunk we still need
    "expected_size": 0,     # from the image list (0 = unknown)
    "chunks": {},           # idx -> bytes
    "highest_chunk": -1,
    "start_time": 0,
    "last_rx_time": 0,      # last request or receipt (drives the retry timer)
    "retries": 0,
    "deadline": 0,          # absolute time to give up
    "paused": False,        # user paused — stop requesting, keep the partial
}

# Chunked responses (EPS / image list / health) are split into small radio
# frames [idx][total][data]. One duplicate-aware reassembler handles them all,
# keyed by a short name. Completed transfers are kept as a short-lived tombstone
# so the COPIES=2 echo of the last chunk cannot re-open a phantom transfer.
DUPLICATE_GUARD_S = 2.5   # swallow the redundant re-send after completion
REASSEMBLY_STALE_S = 4.0  # abandon a transfer that is missing a chunk
_reassembly = {}          # key -> {"total","chunks","ts","done"}

# De-dup identical single-frame responses (e.g. the 3x GPS send) so the app
# doesn't get three toasts for one reply.
_dedup = {}               # cmd_type -> (payload_bytes, ts)

def _is_duplicate(cmd_type, payload, window=1.0):
    now = time.time()
    cur = bytes(payload)
    prev = _dedup.get(cmd_type)
    _dedup[cmd_type] = (cur, now)
    return bool(prev and prev[0] == cur and now - prev[1] < window)

# Serial port handle
ser = None
serial_connected = False       # True while the GS serial port is open
current_port = None            # Port name currently in use / attempted
requested_port = None          # User-selected port override (from the app)
detected_port = None           # Cached auto-detect (probing is slow — do it once)
_port_open_time = 0.0          # When the current port was opened
_no_rx_hint_sent = False       # Warned once about a silent (wrong) port
reconnect_event = threading.Event()  # Set to force a serial reconnect

# Event loop reference for cross-thread broadcasting
main_loop = None

# ====================================================================
# CRC32 CALCULATION
# ====================================================================
def calculate_crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF

# ====================================================================
# KISS ENCODE / PACKET BUILDER
# ====================================================================
def kiss_encode(payload: bytes) -> bytes:
    """Wrap raw bytes in KISS framing."""
    encoded = bytearray()
    encoded.append(FEND)
    for b in payload:
        if b == FEND:
            encoded.extend([FESC, TFEND])
        elif b == FESC:
            encoded.extend([FESC, TFESC])
        else:
            encoded.append(b)
    encoded.append(FEND)
    return bytes(encoded)

def build_packet(cmd_type: int, payload: bytes = b'') -> bytes:
    """Build application packet with sync, cmd, length, payload, and CRC32."""
    packet = bytearray([0xAA, 0xBB, cmd_type, len(payload)])
    packet.extend(payload)
    crc = calculate_crc32(bytes(packet))
    packet.extend(struct.pack('>I', crc))
    return kiss_encode(bytes(packet))

# send_command runs from both the WebSocket thread (user actions) and the serial
# thread (chunk re-requests), so the actual write must be serialized.
_serial_write_lock = threading.Lock()

def bridge_log(line: str):
    """Mirror a serial-traffic line to the dashboard's bridge terminal."""
    schedule_broadcast({"type": "bridge_log", "data": line})

def send_command(cmd_type: int, payload: bytes = b''):
    """Send a command to the GS over serial (thread-safe)."""
    if ser and ser.is_open:
        data = build_packet(cmd_type, payload)
        with _serial_write_lock:
            ser.write(data)
        log.info(f"TX -> CMD 0x{cmd_type:02X} payload={payload.hex() if payload else 'none'}")
        bridge_log(f"TX >> CMD 0x{cmd_type:02X} len={len(payload)}"
                   + (f" {payload.hex()}" if payload else ""))

# ====================================================================
# PACKET PROCESSOR
# ====================================================================
def process_packet(raw_bytes: bytearray):
    """
    Process a decoded KISS frame.
    The GS firmware appends 3 bytes of RSSI/SNR metadata after the
    application packet, so we need to strip those first.
    """
    global download_state

    # The GS appends 3 bytes: [RSSI_H, RSSI_L, SNR]
    # Minimum: 8 (app packet) + 3 (metadata) = 11 bytes
    if len(raw_bytes) < 11:
        log.warning(f"Packet too short: {len(raw_bytes)} bytes")
        return

    # Extract RSSI/SNR metadata from the tail
    rssi_raw = struct.unpack('>h', raw_bytes[-3:-1])[0]
    snr_raw = struct.unpack('b', bytes([raw_bytes[-1]]))[0]
    latest_telemetry["rssi"] = rssi_raw / 10.0
    latest_telemetry["snr"] = snr_raw / 10.0

    # The actual application packet (without metadata)
    app_packet = raw_bytes[:-3]

    if len(app_packet) < 8:
        log.warning("App packet too short after stripping metadata")
        return

    # Verify sync bytes
    if app_packet[0] != 0xAA or app_packet[1] != 0xBB:
        log.warning(f"Bad sync bytes: 0x{app_packet[0]:02X} 0x{app_packet[1]:02X}")
        return

    cmd_type = app_packet[2]
    payload_len = app_packet[3]

    # Verify packet length
    expected_len = 4 + payload_len + 4  # header + payload + CRC32
    if len(app_packet) != expected_len:
        log.warning(f"Length mismatch: expected {expected_len}, got {len(app_packet)}")
        return

    # Verify CRC32
    payload = app_packet[4:4 + payload_len]
    expected_crc = struct.unpack('>I', app_packet[4 + payload_len:8 + payload_len])[0]
    calc_crc = calculate_crc32(bytes(app_packet[:4 + payload_len]))

    if calc_crc != expected_crc:
        log.error(f"CRC32 Mismatch! Expected 0x{expected_crc:08X}, got 0x{calc_crc:08X}")
        bridge_log(f"ERROR: CRC mismatch on CMD 0x{cmd_type:02X} — frame dropped")
        return

    # Valid packet -> Link is active
    latest_telemetry["link_status"] = "ACTIVE"
    latest_telemetry["last_packet_time"] = time.time()

    log.info(f"RX <- CMD 0x{cmd_type:02X} payload_len={payload_len}")
    bridge_log(f"RX << CMD 0x{cmd_type:02X} len={payload_len}"
               + (f" {bytes(payload).hex()}" if payload_len else "")
               + f"  rssi={latest_telemetry['rssi']}dBm")

    # ---- Handle by command type ----

    if cmd_type == CMD_BEACON:
        if payload_len >= 8:
            latest_telemetry["system_errors"] = payload[0]
            latest_telemetry["payload_pwr"] = bool(payload[1])
            latest_telemetry["gps_pwr"] = bool(payload[2])
            latest_telemetry["cam_pwr"] = bool(payload[3])
            latest_telemetry["battery_pct"] = payload[4]
            latest_telemetry["temperature"] = payload[5]
            latest_telemetry["voltage"] = payload[6]
            # payload[7] is the OBC's own link status byte
            log.info(f"BEACON: Bat={payload[4]}% Temp={payload[5]}C "
                     f"V={payload[6]} Errors=0x{payload[0]:02X} "
                     f"RSSI={latest_telemetry['rssi']}dBm")
        schedule_broadcast({"type": "telemetry", "data": latest_telemetry})

    elif cmd_type == CMD_ACK:
        ack_payload = payload.hex() if payload else ""
        log.info(f"ACK received: {ack_payload}")
        schedule_broadcast({"type": "ack", "data": ack_payload})

    elif cmd_type == CMD_NACK:
        log.warning("NACK received - command failed on OBC")
        schedule_broadcast({"type": "nack", "data": "Command failed"})

    elif cmd_type == CMD_GPS_DATA:
        _gps_pending["active"] = False  # got a reply — stop retrying
        if _is_duplicate(cmd_type, payload):
            return  # 2nd/3rd copy of a 3x GPS send — link already marked active
        if payload_len >= 13:
            lat = struct.unpack('<f', payload[0:4])[0]
            lon = struct.unpack('<f', payload[4:8])[0]
            alt = struct.unpack('<f', payload[8:12])[0]
            sat_count = payload[12]
            # Newer firmware appends a fix-valid byte; fall back to sat count.
            fix_valid = bool(payload[13]) if payload_len >= 14 else (sat_count > 0)
            gps_data = {
                "latitude": round(lat, 6),
                "longitude": round(lon, 6),
                "altitude": round(alt, 2),
                "satellites": sat_count,
                "fix_valid": fix_valid,
            }
            log.info(f"GPS: fix={fix_valid} Lat={lat:.6f} Lon={lon:.6f} "
                     f"Alt={alt:.1f}m Sats={sat_count}")
            schedule_broadcast({"type": "gps", "data": gps_data})

    elif cmd_type == CMD_IMAGE_LIST:
        blob = collect_chunk("image", payload, payload_len)
        if blob is not None:
            files = parse_image_list(blob)
            log.info(f"IMAGE_LIST complete: {len(files)} files")
            schedule_broadcast({"type": "image_list", "data": files})

    elif cmd_type == CMD_HEALTH_DATA:
        blob = collect_chunk("health", payload, payload_len)
        if blob is not None:
            devices = parse_health(blob)
            online = sum(1 for d in devices if d["online"])
            log.info(f"HEALTH complete: {online}/{len(devices)} online")
            schedule_broadcast({"type": "health", "data": devices})

    elif cmd_type == CMD_EPS_LOG_DATA:
        blob = collect_log_chunk(payload, payload_len)
        if blob is not None:
            records = parse_eps_log(blob)
            log.info(f"EPS_LOG complete: {len(records)} records")
            schedule_broadcast({"type": "eps_log", "data": records})
            send_command(CMD_EPS_LOG_CLEAR)  # OBC deletes the transferred snapshot

    elif cmd_type == CMD_IMAGE_DATA:
        handle_image_chunk(payload, payload_len)

    elif cmd_type == CMD_EPS_DATA:
        blob = collect_chunk("eps", payload, payload_len)
        if blob is not None:
            eps = parse_eps_payload(blob)
            if eps:
                latest_telemetry["eps"] = eps
                log.info(f"EPS complete: {len(eps['ina226'])} INA226, "
                         f"{len(eps['tmp102'])} TMP102, {len(eps['adm1177'])} ADM1177")
                schedule_broadcast({"type": "eps", "data": eps})
            else:
                schedule_broadcast({"type": "eps_failed",
                                    "data": "EPS data invalid — try again"})

    else:
        log.info(f"Unhandled CMD: 0x{cmd_type:02X}")

# ====================================================================
# EPS TELEMETRY PARSER
# ====================================================================
def parse_eps_payload(payload: bytes):
    """
    Decode the EPS telemetry packet from the OBC.
    Layout (multi-byte fields little-endian):
      [1]  INA count N1
      N1 x { float busVoltage_V (4), float current_A (4) }
      [1]  TMP count N2
      N2 x { float tempC (4) }
      [1]  ADM count N3
      N3 x { uint16 voltage_mV (LE), uint16 current_mA (LE) }
    """
    try:
        idx = 0
        result = {"ina226": [], "tmp102": [], "adm1177": []}

        n_ina = payload[idx]; idx += 1
        for i in range(n_ina):
            bus_v = struct.unpack('<f', payload[idx:idx + 4])[0]; idx += 4
            cur_a = struct.unpack('<f', payload[idx:idx + 4])[0]; idx += 4
            result["ina226"].append({
                "index": i,
                "voltage": round(bus_v, 3),
                "current": round(cur_a, 3),
            })

        n_tmp = payload[idx]; idx += 1
        for i in range(n_tmp):
            temp_c = struct.unpack('<f', payload[idx:idx + 4])[0]; idx += 4
            result["tmp102"].append({
                "index": i,
                "temperature": round(temp_c, 2),
            })

        n_adm = payload[idx]; idx += 1
        for i in range(n_adm):
            v_mv = struct.unpack('<H', payload[idx:idx + 2])[0]; idx += 2
            c_ma = struct.unpack('<H', payload[idx:idx + 2])[0]; idx += 2
            result["adm1177"].append({
                "index": i,
                "voltage_mv": v_mv,
                "current_ma": c_ma,
            })

        return result
    except (struct.error, IndexError) as e:
        log.error(f"Failed to parse EPS payload: {e}")
        return None

# ====================================================================
# RELIABLE PULL COLLECTORS (EPS / health / image list)
# Push responses (send-all-chunks-twice) are not reliable on a lossy half-
# duplex link: if both copies of any chunk are lost, the transfer is stuck
# forever. Instead we COLLECT chunks and, whenever the stream stalls with a
# gap, RE-REQUEST the whole command — new chunks fill the gaps until complete.
# This mirrors the (reliable) image-download re-request loop, and gives a live
# percentage for every chunked response.
# ====================================================================
COLLECT_RETRY_S = 1.3       # no new chunk within this -> re-request the command
COLLECT_MAX_RETRIES = 8
COLLECT_KEEP_DONE_S = 3.0   # keep a finished collector to swallow late echoes

_collectors = {}            # key -> state dict

def start_collect(key: str, cmd: int):
    """Begin (or restart) collecting a chunked response for `key`."""
    _collectors[key] = {
        "cmd": cmd, "chunks": {}, "total": None,
        "retries": 0, "last": time.time(), "done": False,
    }
    send_command(cmd)
    log.info(f"Collect {key}: requested (cmd 0x{cmd:02X})")

def collect_chunk(key: str, payload: bytes, payload_len: int):
    """Feed one chunk [idx][total][data]. Returns the blob once complete."""
    st = _collectors.get(key)
    if st is None or st["done"] or payload_len < 2:
        return None
    idx, total = payload[0], payload[1]
    if total == 0:
        return None
    st["total"] = total
    is_new = idx not in st["chunks"]
    st["chunks"][idx] = bytes(payload[2:payload_len])
    st["last"] = time.time()
    if is_new:
        received = len(st["chunks"])
        got = sum(len(v) for v in st["chunks"].values())
        schedule_broadcast({
            "type": f"{key}_progress",
            "data": {"received": received, "total": total,
                     "percent": int(received * 100 / total), "bytes": got},
        })
        log.info(f"Collect {key}: {received}/{total}")
    if all(i in st["chunks"] for i in range(total)):
        st["done"] = True
        st["last"] = time.time()
        return b"".join(st["chunks"][i] for i in range(total))
    return None

def service_collectors():
    """Re-request stalled collectors; report failure after too many retries."""
    now = time.time()
    for key, st in list(_collectors.items()):
        if st["done"]:
            if now - st["last"] > COLLECT_KEEP_DONE_S:
                del _collectors[key]
            continue
        if now - st["last"] > COLLECT_RETRY_S:
            if st["retries"] >= COLLECT_MAX_RETRIES:
                total = st["total"] or 0
                missing = [i for i in range(total) if i not in st["chunks"]]
                del _collectors[key]
                schedule_broadcast({"type": f"{key}_failed",
                                    "data": f"Lost data (missing {missing}) — try again"})
                log.error(f"Collect {key}: gave up after {COLLECT_MAX_RETRIES} retries")
            else:
                st["retries"] += 1
                st["last"] = now
                send_command(st["cmd"])
                log.info(f"Collect {key}: re-request (retry {st['retries']})")

# EPS log pull: a uint16-chunked stream ([idxHi][idxLo][totalHi][totalLo][data])
# so the log can exceed 255 chunks. On a stall we re-request the WHOLE pull; the
# OBC re-streams the same frozen snapshot, so accumulated chunks still merge.
LOG_RETRY_S = 1.5
LOG_MAX_RETRIES = 10
_log_collector = {"active": False, "chunks": {}, "total": None,
                  "retries": 0, "last": 0.0}

def start_eps_log_pull():
    _log_collector.update({"active": True, "chunks": {}, "total": None,
                           "retries": 0, "last": time.time()})
    send_command(CMD_GET_EPS_LOG)
    log.info("EPS log pull requested")

def collect_log_chunk(payload, payload_len):
    if not _log_collector["active"] or payload_len < 4:
        return None
    idx = (payload[0] << 8) | payload[1]
    total = (payload[2] << 8) | payload[3]
    if total == 0:
        return None
    _log_collector["total"] = total
    is_new = idx not in _log_collector["chunks"]
    _log_collector["chunks"][idx] = bytes(payload[4:payload_len])
    _log_collector["last"] = time.time()
    if is_new:
        received = len(_log_collector["chunks"])
        schedule_broadcast({"type": "eps_log_progress", "data": {
            "received": received, "total": total,
            "percent": int(received * 100 / total)}})
    if all(i in _log_collector["chunks"] for i in range(total)):
        blob = b"".join(_log_collector["chunks"][i] for i in range(total))
        _log_collector["active"] = False
        return blob
    return None

def service_log_collector():
    if not _log_collector["active"]:
        return
    now = time.time()
    if now - _log_collector["last"] > LOG_RETRY_S:
        if _log_collector["retries"] >= LOG_MAX_RETRIES:
            _log_collector["active"] = False
            schedule_broadcast({"type": "eps_log_failed",
                                "data": "Lost log data — try again"})
        else:
            _log_collector["retries"] += 1
            _log_collector["last"] = now
            send_command(CMD_GET_EPS_LOG)

def parse_eps_log(blob):
    """Parse fixed 48-byte records: t(u32) + 6*(u16 mV, i16 mA) +
    2*(i16 c°C) + 4*(u16 mV, u16 mA)."""
    recs = []
    rsize = 48
    for off in range(0, len(blob) - rsize + 1, rsize):
        r = blob[off:off + rsize]
        t = struct.unpack('<I', r[0:4])[0]
        p = 4
        ina = []
        for i in range(6):
            mv = struct.unpack('<H', r[p:p + 2])[0]
            ma = struct.unpack('<h', r[p + 2:p + 4])[0]
            p += 4
            ina.append({"index": i, "voltage": round(mv / 1000, 3),
                        "current": round(ma / 1000, 3)})
        tmp = []
        for i in range(2):
            cc = struct.unpack('<h', r[p:p + 2])[0]
            p += 2
            tmp.append({"index": i, "temperature": round(cc / 100, 2)})
        adm = []
        for i in range(4):
            v = struct.unpack('<H', r[p:p + 2])[0]
            c = struct.unpack('<H', r[p + 2:p + 4])[0]
            p += 4
            adm.append({"index": i, "voltage_mv": v, "current_ma": c})
        recs.append({"t": t, "ina226": ina, "tmp102": tmp, "adm1177": adm})
    return recs

# GPS is a single small frame (not chunked); make it reliable with the same
# re-request idea so a lost reply is retried instead of silently dropped.
_gps_pending = {"active": False, "retries": 0, "last": 0.0}
GPS_RETRY_S = 1.5
GPS_MAX_RETRIES = 5

def start_gps():
    _gps_pending.update({"active": True, "retries": 0, "last": time.time()})
    send_command(CMD_GET_GPS)

def service_gps():
    if not _gps_pending["active"]:
        return
    now = time.time()
    if now - _gps_pending["last"] > GPS_RETRY_S:
        if _gps_pending["retries"] >= GPS_MAX_RETRIES:
            _gps_pending["active"] = False
            schedule_broadcast({"type": "gps_failed", "data": "No GPS reply — try again"})
        else:
            _gps_pending["retries"] += 1
            _gps_pending["last"] = now
            send_command(CMD_GET_GPS)

def parse_image_list(blob: bytes):
    """Parse [nameLen][name][size(4B, big-endian)] repeating.

    Every real entry is a printable ASCII .jpg filename, so we stop at the
    first byte that doesn't fit that shape. This prevents trailing padding or a
    dropped chunk from inflating the count with garbage entries, and dedupes
    names in case a redundant chunk slips through."""
    files = []
    seen = set()
    idx = 0
    n = len(blob)
    while idx < n:
        fn_len = blob[idx]
        idx += 1
        if fn_len == 0 or idx + fn_len + 4 > n:
            break
        raw = blob[idx:idx + fn_len]
        idx += fn_len
        fsize = struct.unpack('>I', blob[idx:idx + 4])[0]
        idx += 4
        # Validate: a real filename decodes as printable ASCII and ends in .jpg.
        try:
            name = raw.decode('ascii')
        except UnicodeDecodeError:
            break
        if not name.isprintable() or not name.lower().endswith((".jpg", ".jpeg")):
            break  # hit padding / garbage — the real list has ended
        if name in seen:
            continue
        seen.add(name)
        files.append({"name": name, "size": fsize})
        known_image_sizes[name] = fsize  # so a later download can show a real %
    return files

def parse_health(blob: bytes):
    """Parse [count] then count x [addr][online]. Adds a friendly label."""
    labels = {
        0x40: "INA226 · Solar Cell 1", 0x41: "INA226 · Solar Cell 2",
        0x42: "INA226 · Solar Cell 3", 0x43: "INA226 · Solar Cell 4",
        0x47: "INA226 · Battery Charging", 0x48: "INA226 · Battery Discharging",
        0x4A: "TMP102 · Battery 1 Temp", 0x4B: "TMP102 · Battery 2 Temp",
        0x58: "ADM1177 · OBC Power", 0x59: "ADM1177 · Communication Power",
        0x5A: "ADM1177 · Payload 1 Power", 0x5B: "ADM1177 · Payload 2 Power",
    }
    devices = []
    if not blob:
        return devices
    count = blob[0]
    idx = 1
    for _ in range(count):
        if idx + 2 > len(blob):
            break
        addr = blob[idx]
        online = bool(blob[idx + 1])
        idx += 2
        devices.append({
            "addr": f"0x{addr:02X}",
            "online": online,
            "label": labels.get(addr, f"Device 0x{addr:02X}"),
        })
    return devices

# ====================================================================
# IMAGE DOWNLOAD STATE MACHINE
# ====================================================================
def _safe_name(name: str) -> str:
    """Reject path traversal — keep only the basename, no slashes."""
    return os.path.basename(name or "").replace("\\", "").replace("/", "")

def request_chunk(idx: int):
    """Ask the OBC for a chunk. The filename is included on EVERY request so a
    download survives an OBC watchdog reset (the OBC would otherwise forget it)."""
    name = download_state["filename"].encode('ascii', errors='ignore')[:30]
    send_command(CMD_REQ_CHUNK, struct.pack('>H', idx) + name)
    download_state["last_rx_time"] = time.time()  # reset the per-chunk timer

# --- Resume persistence: a paused/interrupted download is saved to a .part
# file (chunk i at offset i*IMAGE_CHUNK_SIZE) + a JSON manifest of received
# indices, so it can resume after an app/bridge restart. The satellite stores
# nothing — it just serves whatever chunk we ask for.
def _part_paths(fname: str):
    base = os.path.join(DOWNLOAD_DIR, "." + _safe_name(fname))
    return base + ".part", base + ".part.json"

def _persist_chunk(fname: str, idx: int, data: bytes):
    try:
        os.makedirs(DOWNLOAD_DIR, exist_ok=True)
        part, manifest = _part_paths(fname)
        with open(part, "r+b" if os.path.exists(part) else "w+b") as f:
            f.seek(idx * IMAGE_CHUNK_SIZE)
            f.write(data)
        indices = []
        if os.path.exists(manifest):
            with open(manifest) as m:
                indices = json.load(m).get("indices", [])
        if idx not in indices:
            indices.append(idx)
        with open(manifest, "w") as m:
            json.dump({"expected_size": download_state["expected_size"],
                       "chunk_size": IMAGE_CHUNK_SIZE, "indices": indices}, m)
    except Exception as e:
        log.warning(f"persist chunk failed: {e}")

def _load_partial(fname: str):
    try:
        part, manifest = _part_paths(fname)
        if not (os.path.exists(part) and os.path.exists(manifest)):
            return None
        with open(manifest) as m:
            meta = json.load(m)
        cs = meta.get("chunk_size", IMAGE_CHUNK_SIZE)
        chunks = {}
        with open(part, "rb") as f:
            for i in sorted(meta.get("indices", [])):
                f.seek(i * cs)
                chunks[i] = f.read(cs)
        return chunks, meta.get("expected_size", 0)
    except Exception as e:
        log.warning(f"load partial failed: {e}")
        return None

def _clear_partial(fname: str):
    for p in _part_paths(fname):
        try:
            if os.path.exists(p):
                os.remove(p)
        except Exception:
            pass

def start_download(filename: str):
    safe = _safe_name(filename) or "photo.jpg"
    now = time.time()
    partial = _load_partial(safe)
    chunks = {}
    expected = known_image_sizes.get(safe, 0)
    if partial:
        chunks, exp2 = partial
        if exp2:
            expected = exp2
        log.info(f"Resuming {safe} with {len(chunks)} cached chunk(s)")
    nxt = 0
    while nxt in chunks:
        nxt += 1
    download_state.update({
        "active": True, "filename": safe, "current_chunk": nxt,
        "expected_size": expected,
        "chunks": chunks, "highest_chunk": max(chunks) if chunks else -1,
        "start_time": now, "last_rx_time": now,
        "retries": 0, "deadline": now + DOWNLOAD_ABSOLUTE_CAP_S, "paused": False,
    })
    log.info(f"Download started: {safe} (expected {expected} B, from chunk {nxt})")
    request_chunk(nxt)

def pause_download():
    if download_state["active"] and not download_state["paused"]:
        download_state["paused"] = True
        log.info("Download paused")
        schedule_broadcast({"type": "download_paused",
                            "data": {"filename": download_state["filename"]}})

def resume_download():
    if download_state["active"] and download_state["paused"]:
        download_state["paused"] = False
        download_state["last_rx_time"] = time.time()
        download_state["retries"] = 0
        log.info("Download resumed")
        schedule_broadcast({"type": "download_resumed",
                            "data": {"filename": download_state["filename"]}})
        request_chunk(download_state["current_chunk"])

def abort_download(reason: str):
    if not download_state["active"]:
        return
    fname = download_state["filename"]
    download_state["active"] = False
    download_state["chunks"] = {}
    log.error(f"DOWNLOAD FAILED ({fname}): {reason}")
    schedule_broadcast({"type": "download_failed",
                        "data": {"filename": fname, "reason": reason}})

def _emit_download_progress():
    received = sum(len(v) for v in download_state["chunks"].values())
    expected = download_state["expected_size"]
    elapsed = max(1e-3, time.time() - download_state["start_time"])
    spd = received / elapsed
    pct = int(received * 100 / expected) if expected else 0
    eta = int((expected - received) / spd) if (expected and spd > 0) else 0
    schedule_broadcast({"type": "download_progress", "data": {
        "chunk": download_state["highest_chunk"],
        "bytes_received": received,
        "total_size": expected,        # 0 = unknown
        "percent": pct,
        "speed_bps": round(spd, 1),
        "eta_s": eta,
        "filename": download_state["filename"],
    }})

def _finish_download():
    chunks = download_state["chunks"]
    data = b"".join(chunks[i] for i in sorted(chunks))
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)
    save_path = os.path.join(DOWNLOAD_DIR, _safe_name(download_state["filename"]))
    with open(save_path, "wb") as f:
        f.write(data)
    elapsed = time.time() - download_state["start_time"]
    log.info(f"DOWNLOAD COMPLETE: {save_path} ({len(data)} B in {elapsed:.1f}s)")
    schedule_broadcast({"type": "download_complete", "data": {
        "filename": download_state["filename"],
        "size": len(data),
        "elapsed": round(elapsed, 1),
        "path": save_path,
    }})
    _clear_partial(download_state["filename"])  # transfer done — drop the resume cache
    download_state["active"] = False
    download_state["chunks"] = {}

def handle_image_chunk(payload: bytes, payload_len: int):
    if not download_state["active"]:
        return

    # EOT: the OBC only sends it once we've requested past the last chunk, so by
    # now every in-order chunk has been received.
    if payload_len >= 2 and payload[0] == 0xFF and payload[1] == 0xFF:
        _finish_download()
        return

    if payload_len < 3:
        return

    chunk_id = struct.unpack('>H', payload[:2])[0]
    chunk_data = bytes(payload[2:])

    download_state["last_rx_time"] = time.time()
    download_state["retries"] = 0

    if chunk_id not in download_state["chunks"]:
        download_state["chunks"][chunk_id] = chunk_data
        if chunk_id > download_state["highest_chunk"]:
            download_state["highest_chunk"] = chunk_id
        _persist_chunk(download_state["filename"], chunk_id, chunk_data)
        _emit_download_progress()

    # If the user paused, keep the chunk but stop asking for more.
    if download_state["paused"]:
        return

    # Request the next in-order chunk we still need.
    nxt = download_state["current_chunk"]
    while nxt in download_state["chunks"]:
        nxt += 1
    download_state["current_chunk"] = nxt
    request_chunk(nxt)

def service_download():
    """Called from the serial loop: drive retries + timeouts for the download."""
    if not download_state["active"] or download_state["paused"]:
        return  # paused downloads keep their partial and don't time out
    now = time.time()
    if now > download_state["deadline"]:
        abort_download("Timed out (exceeded maximum download time)")
        return
    if now - download_state["last_rx_time"] > CHUNK_TIMEOUT_S:
        download_state["retries"] += 1
        if download_state["retries"] > CHUNK_MAX_RETRIES:
            abort_download(f"No response after {CHUNK_MAX_RETRIES} retries")
            return
        log.warning(f"Download stall: retry {download_state['retries']} "
                    f"for chunk {download_state['current_chunk']}")
        request_chunk(download_state["current_chunk"])

# ====================================================================
# SERIAL READER THREAD
# ====================================================================
def list_available_ports():
    """Return a list of {device, description} for the USB serial ports present
    (legacy /dev/ttyS* motherboard UARTs are hidden — they clutter the picker
    and are never the Ground Station)."""
    ports = []
    try:
        for p in list_ports.comports():
            if _is_usb_serial(p.device):
                ports.append({"device": p.device, "description": p.description or ""})
    except Exception:
        pass
    return ports

def build_bridge_status(error=None):
    """Status message the app uses to drive the connection banner + port picker."""
    return {
        "type": "bridge_status",
        "data": {
            "serial_connected": serial_connected,
            "port": current_port,
            "available_ports": list_available_ports(),
            "error": error,
        },
    }

def _open_serial():
    """Attempt to open the serial port. Returns True on success."""
    global ser, serial_connected, current_port, detected_port
    global _port_open_time, _no_rx_hint_sent
    if requested_port:
        port = requested_port
    else:
        if detected_port is None:
            detected_port = autodetect_serial_port()
        port = detected_port or SERIAL_PORT
    current_port = port
    try:
        ser = serial.Serial(port, BAUD_RATE, timeout=0.1)
        serial_connected = True
        _port_open_time = time.time()
        _no_rx_hint_sent = False
        log.info(f"Serial port {port} opened at {BAUD_RATE} baud")
        schedule_broadcast(build_bridge_status())
        return True
    except Exception as e:
        serial_connected = False
        ser = None
        detected_port = None   # re-run detection next attempt (port may have moved)
        available = [p.device for p in list_ports.comports()]
        log.error(
            f"Cannot open {port}: {e}. "
            f"Available ports: {available or 'none detected'}. "
            f"Retrying... (tip: close the Arduino Serial Monitor; "
            f"on Linux ensure you're in the 'dialout' group)"
        )
        schedule_broadcast(build_bridge_status(error=str(e)))
        return False

def serial_reader_loop():
    global ser, serial_connected, _no_rx_hint_sent

    in_frame = False
    escape_next = False
    kiss_buffer = bytearray()

    while True:
        # (Re)open the port whenever it is not currently connected.
        if ser is None or not getattr(ser, "is_open", False):
            if not _open_serial():
                # Wait up to 3s, but wake immediately on a reconnect request.
                reconnect_event.wait(timeout=3)
                reconnect_event.clear()
                continue
            in_frame = False
            escape_next = False
            kiss_buffer.clear()

        try:
            # Handle a user-requested reconnect / port change.
            if reconnect_event.is_set():
                reconnect_event.clear()
                try:
                    ser.close()
                except Exception:
                    pass
                ser = None
                serial_connected = False
                schedule_broadcast(build_bridge_status())
                continue

            if ser.in_waiting > 0:
                raw = ser.read(ser.in_waiting)
                for b in raw:
                    if b == FEND:
                        if in_frame and len(kiss_buffer) > 0:
                            process_packet(bytearray(kiss_buffer))
                            kiss_buffer.clear()
                            in_frame = False
                            escape_next = False
                        else:
                            in_frame = True
                            kiss_buffer.clear()
                            escape_next = False
                    elif in_frame:
                        if b == FESC:
                            escape_next = True
                        elif escape_next:
                            if b == TFEND:
                                kiss_buffer.append(FEND)
                            elif b == TFESC:
                                kiss_buffer.append(FESC)
                            escape_next = False
                        else:
                            kiss_buffer.append(b)
            else:
                time.sleep(0.01)  # Avoid busy-wait

            # Wrong-port hint: the port is open but NO valid packet has EVER
            # arrived (the OBC beacons every 1-10 s, so a healthy chain always
            # produces data). Most likely we're on a debug console, not the GS.
            if (serial_connected and not _no_rx_hint_sent
                    and latest_telemetry["last_packet_time"] == 0
                    and time.time() - _port_open_time > 20):
                _no_rx_hint_sent = True
                msg = (f"No KISS data on {current_port} after 20 s — this is "
                       "probably a debug console, not the Ground Station. "
                       "Pick the GS port in the dashboard's port selector "
                       "(the GS KISS link is on PC10/PC11 — usually a "
                       "USB-serial adapter, e.g. ttyUSB0).")
                log.warning(msg)
                schedule_broadcast(build_bridge_status(error=msg))

            # Check link timeout
            if latest_telemetry["last_packet_time"] > 0:
                if time.time() - latest_telemetry["last_packet_time"] > LINK_TIMEOUT_S:
                    if latest_telemetry["link_status"] != "LOST":
                        latest_telemetry["link_status"] = "LOST"
                        log.warning("Link LOST (timeout)")
                        schedule_broadcast({"type": "telemetry", "data": latest_telemetry})

            # Re-request stalled chunked responses (EPS / health / image list),
            # GPS, and drive any in-progress image download.
            service_collectors()
            service_gps()
            service_log_collector()
            service_download()

        except serial.SerialException as e:
            log.error(f"Serial error: {e}. Reconnecting...")
            serial_connected = False
            try:
                ser.close()
            except Exception:
                pass
            ser = None
            schedule_broadcast(build_bridge_status(error=str(e)))
            time.sleep(2)
        except Exception as e:
            log.error(f"Unexpected error in serial reader: {e}")
            time.sleep(1)

# ====================================================================
# ASYNC BROADCAST HELPER
# ====================================================================
import queue
broadcast_q = queue.Queue()

def schedule_broadcast(data: dict):
    """Thread-safe: schedule a broadcast via queue."""
    broadcast_q.put(data)

async def broadcast(data: dict):
    """Send a JSON message to all connected WebSocket clients."""
    global connected_clients
    if connected_clients:
        message = json.dumps(data, default=str)
        disconnected = set()
        for client in connected_clients:
            try:
                await client.send(message)
            except websockets.exceptions.ConnectionClosed:
                disconnected.add(client)
        connected_clients.difference_update(disconnected)

# ====================================================================
# WEBSOCKET HANDLER
# ====================================================================
async def ws_handler(websocket):
    connected_clients.add(websocket)
    log.info(f"Dashboard connected ({len(connected_clients)} clients)")

    # Send current telemetry + bridge/serial status immediately on connect
    try:
        await websocket.send(json.dumps({
            "type": "telemetry",
            "data": latest_telemetry
        }))
        await websocket.send(json.dumps(build_bridge_status()))
    except:
        pass

    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                cmd = data.get("cmd", "")
                log.info(f"WS CMD: {cmd}")

                if cmd == "list_ports":
                    # App is asking which serial ports are available.
                    await websocket.send(json.dumps(build_bridge_status()))

                elif cmd == "set_port":
                    # App picked a specific serial port -> switch to it.
                    global requested_port, detected_port
                    new_port = (data.get("port") or "").strip()
                    requested_port = new_port or None
                    detected_port = None  # force fresh detection if AUTO
                    log.info(f"Serial port override set to: {requested_port or 'AUTO'}")
                    reconnect_event.set()
                    await websocket.send(json.dumps(build_bridge_status()))

                elif cmd == "reconnect":
                    # Force a fresh serial reconnect (re-runs auto-detect).
                    log.info("Reconnect requested by app")
                    globals()["detected_port"] = None  # re-probe from scratch
                    reconnect_event.set()
                    await websocket.send(json.dumps(build_bridge_status()))

                elif cmd == "set_download_dir":
                    # The app chose where downloaded images are saved.
                    global DOWNLOAD_DIR
                    new_dir = (data.get("path") or "").strip()
                    if new_dir:
                        try:
                            os.makedirs(new_dir, exist_ok=True)
                            DOWNLOAD_DIR = new_dir
                            log.info(f"Download directory set to: {DOWNLOAD_DIR}")
                        except Exception as e:
                            log.warning(f"Bad download dir {new_dir}: {e}")

                elif cmd == "pause_download":
                    pause_download()

                elif cmd == "resume_download":
                    resume_download()

                elif cmd == "ping":
                    send_command(CMD_PING)

                elif cmd == "status":
                    if download_state["active"] and not download_state["paused"]:
                        await websocket.send(json.dumps(
                            {"type": "busy", "data": "Download in progress"}))
                    else:
                        start_collect("health", CMD_STATUS)

                elif cmd == "beacon":
                    send_command(CMD_BEACON)

                elif cmd == "eps_log_config":
                    enable = 1 if data.get("enable") else 0
                    interval = int(data.get("interval", 5)) & 0xFFFF
                    send_command(CMD_EPS_LOG_CFG,
                                 bytes([enable, interval & 0xFF, (interval >> 8) & 0xFF]))
                    log.info(f"EPS log config: enable={enable} interval={interval}s")

                elif cmd == "get_eps_log":
                    if download_state["active"] and not download_state["paused"]:
                        await websocket.send(json.dumps(
                            {"type": "busy", "data": "Download in progress"}))
                    else:
                        start_eps_log_pull()

                elif cmd == "sync_time":
                    # Set the satellite's software clock to the PC's UTC time.
                    epoch = int(time.time())
                    send_command(CMD_SET_TIME, struct.pack('<I', epoch))
                    log.info(f"Time sync -> epoch {epoch}")

                elif cmd == "take_pic":
                    res_id = int(data.get("resolution", 0)) & 0xFF
                    send_command(CMD_TAKE_PIC, bytes([res_id]))

                elif cmd == "get_gps":
                    start_gps()

                elif cmd == "get_eps":
                    if download_state["active"] and not download_state["paused"]:
                        await websocket.send(json.dumps(
                            {"type": "busy", "data": "Download in progress"}))
                    else:
                        start_collect("eps", CMD_GET_EPS)

                elif cmd == "toggle_pwr":
                    subsystem = data.get("subsystem", 0)
                    send_command(CMD_TOGGLE_PWR, bytes([subsystem]))

                elif cmd == "list_image":
                    if download_state["active"] and not download_state["paused"]:
                        await websocket.send(json.dumps(
                            {"type": "busy", "data": "Download in progress"}))
                    else:
                        start_collect("image", CMD_LIST_IMAGE)

                elif cmd == "remove_image":
                    filename = data.get("filename", "")
                    if filename:
                        send_command(CMD_REMOVE_IMAGE, filename.encode('ascii'))
                    else:
                        await websocket.send(json.dumps({
                            "type": "error", "data": "Missing filename"
                        }))

                elif cmd == "download":
                    if download_state["active"]:
                        msg = ("A download is paused — resume or cancel it first"
                               if download_state["paused"]
                               else "A download is already running")
                        await websocket.send(json.dumps(
                            {"type": "busy", "data": msg}))
                    else:
                        filename = data.get("filename", "photo.jpg")
                        start_download(filename)
                        await websocket.send(json.dumps({
                            "type": "download_started",
                            "data": {"filename": download_state["filename"]}
                        }))

                else:
                    log.warning(f"Unknown WS command: {cmd}")
                    await websocket.send(json.dumps({
                        "type": "error", "data": f"Unknown command: {cmd}"
                    }))

            except json.JSONDecodeError:
                log.warning("Invalid JSON from dashboard")

    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        connected_clients.discard(websocket)
        log.info(f"Dashboard disconnected ({len(connected_clients)} clients)")

# ====================================================================
# MAIN
# ====================================================================
async def broadcast_worker():
    while True:
        while not broadcast_q.empty():
            data = broadcast_q.get()
            await broadcast(data)
        await asyncio.sleep(0.05)

async def main():
    global main_loop
    main_loop = asyncio.get_running_loop()

    # Start serial reader in background thread
    serial_thread = threading.Thread(target=serial_reader_loop, daemon=True)
    serial_thread.start()

    # Create downloads directory
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)

    # Start worker
    asyncio.create_task(broadcast_worker())

    # Start WebSocket server. Bind BOTH loopback stacks (IPv4 127.0.0.1 and
    # IPv6 ::1) so the app connects regardless of how "localhost" resolves on
    # this OS (the Linux IPv4/IPv6 mismatch bug). Fall back to IPv4 only if the
    # dual-stack bind fails (e.g. IPv6 disabled).
    try:
        await websockets.serve(ws_handler, ["127.0.0.1", "::1"], WS_PORT)
        log.info(f"WebSocket Server listening on 127.0.0.1 + ::1 :{WS_PORT}")
    except OSError as e:
        log.warning(f"Dual-stack bind failed ({e}); using 127.0.0.1 only")
        await websockets.serve(ws_handler, "127.0.0.1", WS_PORT)
        log.info(f"WebSocket Server listening on 127.0.0.1:{WS_PORT}")

    log.info("Bridge is running. Waiting for connections...")
    await asyncio.Future()  # Run forever (the server keeps serving)

if __name__ == "__main__":
    asyncio.run(main())
