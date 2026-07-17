"""
NBSPACE Labs: FlatSat Learning Set
Lab 6: Terrestrial Segment - Image Reconstruction Script
Description: Interfaces with GS board, processes dynamic payloads, and reconstructs binary JPEG fragments.
"""

import serial
import time
import binascii
import zlib

# CONFIGURATION: Modify COM port to match your local Ground Station deployment
COM_PORT = 'COM12' 
BAUD_RATE = 115200

OUTPUT_FILE = "received_photo.jpg"
CHUNK_SIZE = 48

try:
    ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=1)
    print(f"Ground Station Control Terminal Connected on {COM_PORT}")
    print(f"Waiting for Satellite Downlink... Image will be saved to '{OUTPUT_FILE}'\n")
    
    # Open file in binary seek-write mode (creates new or opens existing)
    try:
        f = open(OUTPUT_FILE, "r+b")
    except FileNotFoundError:
        f = open(OUTPUT_FILE, "wb")
        
    with f as file:
        while True:
            # Poll lines from the serial pipeline
            line = ser.readline().decode('utf-8', errors='ignore').strip()
            
            if "CHUNK_DATA:" in line:
                # Extract clean hex payload following token delimiter
                hex_data = line.split("CHUNK_DATA:")[1]
                
                # Deconstruct packet structures dynamically
                chunk_id_hex = hex_data[:4]      # Bytes 0-1: 16-bit Chunk ID
                payload_len_hex = hex_data[4:6]  # Byte 2: 8-bit Data Block Length
                image_hex = hex_data[6:]         # Byte 3+: Raw image fragment
                
                chunk_index = int(chunk_id_hex, 16)
                payload_len = int(payload_len_hex, 16)
                
                # ---------------------------------------------------------
                # END OF TRANSMISSION (EOT) CHECK
                # ---------------------------------------------------------
                if chunk_index == 0xFFFF and payload_len == 0:
                    print("\n[SUCCESS] End of Transmission (EOT) received! Image assembly complete.")
                    
                    f.flush()
                    f.seek(0)
                    file_data = f.read()
                    
                    crc32_hash = zlib.crc32(file_data) & 0xFFFFFFFF
                    
                    print("==================================================")
                    print(f"Final File Size: {len(file_data)} bytes")
                    print(f"Received CRC32 : {crc32_hash:08X}")
                    print("==================================================")
                    print(">> Please compare this CRC32 with the original file! <<")
                    
                    break # Exit the while loop gracefully to close the file
                
                image_bytes = binascii.unhexlify(image_hex)
                
                # Dynamic Seek-Write: Map fragments directly into absolute block addresses
                # This architecture natively handles fragmented or out-of-order packets
                file.seek(chunk_index * CHUNK_SIZE) # Absolute offset multiplication based on CHUNK_SIZE
                file.write(image_bytes)
                file.flush() # Force write buffer dump onto disk partition
                
                print(f"[DOWNLOAD] Chunk #{chunk_index:03d} successfully written to disk. ({payload_len} bytes)")
            
            elif line != "":
                # Direct relay for verbose telemetry messages coming from the GS board
                print(line)
                
except serial.SerialException as e:
    print(f"Serial Connection Error: Port locked or unavailable. Details: {e}")
except KeyboardInterrupt:
    print("\nMission Terminated by Ground Segment Operator.")