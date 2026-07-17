import zlib
import os

FILE_NAME = "photo.jpg"

try:
    file_size = os.path.getsize(FILE_NAME)
    with open(FILE_NAME, "rb") as f:
        file_data = f.read()
        crc32_hash = zlib.crc32(file_data) & 0xFFFFFFFF
        
        print("\n=== ORIGINAL FILE INFO ===")
        print(f"File Name : {FILE_NAME}")
        print(f"File Size : {file_size} bytes")
        print(f"CRC32 Hash: {crc32_hash:08X}")
        print("==========================\n")
    
except FileNotFoundError:
    print(f"Error: File '{FILE_NAME}' not found in this folder.")