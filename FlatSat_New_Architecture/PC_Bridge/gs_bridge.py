import serial
import time
import struct
import binascii
import asyncio
import websockets
import json
import threading

# ====================================================================
# CONFIGURATION
# ====================================================================
SERIAL_PORT = '/dev/ttyUSB0' # Modify as needed
BAUD_RATE = 115200

# KISS Protocol
FEND = b'\xC0'
FESC = b'\xDB'
TFEND = b'\xDC'
TFESC = b'\xDD'

# Command Bytes
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

# State
latest_telemetry = {
    "system_errors": 0,
    "payload_pwr": False,
    "battery_pct": 0,
    "temperature": 0,
    "voltage": 0,
    "link_status": "LOST",
    "last_ack": 0
}

# WebSocket Clients
connected_clients = set()

# Download Manager State
downloading = False
current_chunk = 0
image_buffer = bytearray()

ser = None

# ====================================================================
# SERIAL INTERFACE
# ====================================================================
def calculate_crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF

def encode_kiss(payload: bytes) -> bytes:
    encoded = bytearray()
    encoded.extend(FEND)
    for b in payload:
        if b == 0xC0:
            encoded.extend(b'\xDB\xDC')
        elif b == 0xDB:
            encoded.extend(b'\xDB\xDD')
        else:
            encoded.append(b)
    encoded.extend(FEND)
    return bytes(encoded)

def build_packet(cmd_type, payload=b''):
    packet = bytearray([0xAA, 0xBB, cmd_type, len(payload)])
    packet.extend(payload)
    crc = calculate_crc32(packet)
    packet.extend(struct.pack('>I', crc))
    return encode_kiss(bytes(packet))

def send_command(cmd_type, payload=b''):
    if ser and ser.is_open:
        ser.write(build_packet(cmd_type, payload))

# ====================================================================
# SERIAL READER THREAD
# ====================================================================
def serial_reader_loop():
    global ser, latest_telemetry, downloading, current_chunk, image_buffer
    
    try:
        ser = serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=1)
    except Exception as e:
        print(f"Failed to open {SERIAL_PORT}: {e}")
        return

    in_frame = False
    escape_next = False
    kiss_buffer = bytearray()

    while True:
        try:
            if ser.in_waiting > 0:
                c = ser.read(1)
                
                if c == FEND:
                    if in_frame and len(kiss_buffer) > 0:
                        process_packet(kiss_buffer)
                        kiss_buffer.clear()
                        in_frame = False
                    else:
                        in_frame = True
                elif in_frame:
                    if c == FESC:
                        escape_next = True
                    elif escape_next:
                        if c == TFEND: kiss_buffer.extend(FEND)
                        elif c == TFESC: kiss_buffer.extend(FESC)
                        escape_next = False
                    else:
                        kiss_buffer.extend(c)
        except Exception as e:
            print(f"Serial read error: {e}")
            time.sleep(1)

def process_packet(raw_packet: bytearray):
    global latest_telemetry, downloading, current_chunk, image_buffer
    
    if len(raw_packet) < 8:
        return
        
    if raw_packet[0] != 0xAA or raw_packet[1] != 0xBB:
        return
        
    cmd_type = raw_packet[2]
    payload_len = raw_packet[3]
    
    if len(raw_packet) < 8 + payload_len:
        return
        
    payload = raw_packet[4:4+payload_len]
    expected_crc = struct.unpack('>I', raw_packet[4+payload_len:8+payload_len])[0]
    
    calc_crc = calculate_crc32(raw_packet[:4+payload_len])
    if calc_crc != expected_crc:
        print(f"CRC Mismatch! Expected {expected_crc}, got {calc_crc}")
        return

    # Valid Packet Received -> Link Active
    latest_telemetry["link_status"] = "ACTIVE"
    latest_telemetry["last_ack"] = time.time()
    
    if cmd_type == CMD_BEACON and payload_len == 5:
        latest_telemetry["system_errors"] = payload[0]
        latest_telemetry["payload_pwr"] = bool(payload[1])
        latest_telemetry["battery_pct"] = payload[2]
        latest_telemetry["temperature"] = payload[3]
        latest_telemetry["voltage"] = payload[4]
        asyncio.run(broadcast_telemetry())
        
    elif cmd_type == CMD_ACK:
        print("ACK Received")
        
    elif cmd_type == CMD_IMAGE_DATA:
        if downloading:
            chunk_id = struct.unpack('>H', payload[:2])[0]
            if chunk_id == current_chunk:
                print(f"Received chunk {chunk_id}")
                image_buffer.extend(payload[2:])
                current_chunk += 1
                
                # Check for EOT condition (e.g., chunk size < 48)
                if len(payload) - 2 < 48:
                    print("Download complete!")
                    with open("downloaded_image.jpg", "wb") as f:
                        f.write(image_buffer)
                    downloading = False
                    image_buffer.clear()
                else:
                    # Request next chunk
                    send_command(CMD_REQ_CHUNK, struct.pack('>H', current_chunk))
            else:
                print(f"Chunk mismatch. Expected {current_chunk}, got {chunk_id}")

async def broadcast_telemetry():
    if connected_clients:
        message = json.dumps({"type": "telemetry", "data": latest_telemetry})
        await asyncio.gather(*[client.send(message) for client in connected_clients])

# ====================================================================
# WEBSOCKET SERVER
# ====================================================================
async def handler(websocket):
    connected_clients.add(websocket)
    try:
        async for message in websocket:
            data = json.loads(message)
            cmd = data.get("cmd")
            
            if cmd == "ping":
                send_command(CMD_PING)
            elif cmd == "status":
                send_command(CMD_STATUS)
            elif cmd == "toggle_pwr":
                send_command(CMD_TOGGLE_PWR)
            elif cmd == "take_pic":
                send_command(CMD_TAKE_PIC)
            elif cmd == "download":
                global downloading, current_chunk, image_buffer
                downloading = True
                current_chunk = 0
                image_buffer.clear()
                print("Starting download...")
                send_command(CMD_REQ_CHUNK, struct.pack('>H', current_chunk))
                
    finally:
        connected_clients.remove(websocket)

async def main():
    threading.Thread(target=serial_reader_loop, daemon=True).start()
    async with websockets.serve(handler, "localhost", 8080):
        print("WebSocket Server running on ws://localhost:8080")
        await asyncio.Future()  # run forever

if __name__ == "__main__":
    asyncio.run(main())
