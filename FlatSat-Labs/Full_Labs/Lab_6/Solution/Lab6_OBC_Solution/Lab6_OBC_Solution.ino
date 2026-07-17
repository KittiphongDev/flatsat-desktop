/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 6: Resilient Downlink & System Fault Tolerance
 * Module: On-Board Computer (OBC) - Solution Code
 * Architecture: OBC reads SD Card and sends data chunks to COMMS via UART.
 */

#include <Arduino.h>
#include <SPI.h>
#include "SdFat_Adafruit_Fork.h"
#include <IWatchdog.h>

// ====================================================================
// HARDWARE PIN DEFINITIONS
// ====================================================================

// --- SD CARD BUS (SPI3 - Dedicated) ---
#define SD_SCK PC10
#define SD_MISO PC11
#define SD_MOSI PC12
#define SD_CS PC9

SPIClass SD_SPI(SD_MOSI, SD_MISO, SD_SCK);
SdFat sd;

// --- UART TO COMMS MODULE ---
HardwareSerial CommsUART(PA1, PA0);

// ====================================================================
// MISSION PARAMETERS
// ====================================================================
#define CHUNK_SIZE 48          // Optimized payload chunk size (bytes)
#define ACK_TIMEOUT_MS 5000    // Handshake wait threshold (milliseconds)
#define WDT_TIMEOUT_US 10000000 // Watchdog hardware trigger (10 seconds)

const char *IMAGE_FILE = "photo.jpg";
const char *STATE_FILE = "state.txt";

uint32_t currentChunkIndex = 0;
bool isTransferComplete = false;
bool isRecovered = false; // Flag to prevent WDT boot loops upon recovery

// ====================================================================
// STATE RECOVERY FUNCTIONS
// ====================================================================
void loadTransferState()
{
  if (sd.exists(STATE_FILE))
  {
    File stateFile;
    if (stateFile.open(STATE_FILE, O_RDONLY))
    {
      String valStr = stateFile.readStringUntil('\n');
      currentChunkIndex = valStr.toInt();
      stateFile.close();

      isRecovered = true; // Mark system as successfully recovered from a fault

      Serial.print("[RECOVERY] Resuming transfer from Chunk #");
      Serial.println(currentChunkIndex);
    }
  }
  else
  {
    Serial.println("[START] New transfer mission. Starting from Chunk #0");
  }
}

void saveTransferState(uint32_t chunkIdx)
{
  File stateFile;
  if (stateFile.open(STATE_FILE, O_WRONLY | O_CREAT | O_TRUNC))
  {
    stateFile.println(chunkIdx);
    stateFile.close();
  }
}

// ====================================================================
// SETUP FUNCTION
// ====================================================================
void setup()
{
  // Initialize Debug Serial to PC
  Serial.setRx(PD9);
  Serial.setTx(PD8);
  Serial.begin(115200);

  // Initialize UART connection to the COMMS subsystem
  CommsUART.begin(115200);

  delay(2000);
  Serial.println("\n=== FlatSat OBC: Resilient Downlink Manager ===");

  // 1. Initialize SD Card (on SPI3)
  Serial.print("[SYSTEM] Initializing SD Card on SPI3... ");
  SD_SPI.begin();
  if (!sd.begin(SdSpiConfig(SD_CS, DEDICATED_SPI, SD_SCK_MHZ(10), &SD_SPI)))
  {
    Serial.println("FAILED!");
    Serial.println("-> Please check SD Card connection.");
    while (true)
      ;
  }
  Serial.println("OK!");

  // 2. Load previous state (Fault Recovery Mechanism)
  loadTransferState();

  // 3. Initialize Hardware Watchdog Timer
  IWatchdog.begin(WDT_TIMEOUT_US);
  Serial.println("[SYSTEM] Watchdog Timer armed (10 Seconds).");
}

// ====================================================================
// MAIN LOOP FUNCTION
// ====================================================================
void loop()
{
  if (isTransferComplete)
  {
    IWatchdog.reload(); // Refresh Watchdog while idling
    delay(1000);
    return;
  }

  File imgFile;
  if (!imgFile.open(IMAGE_FILE, O_RDONLY))
  {
    Serial.println("[ERROR] Cannot open image file. Did you save photo.jpg?");
    IWatchdog.reload();
    delay(1000);
    return;
  }

  // File System Check: Prevent seek overflow and detect mission end boundary
  if ((currentChunkIndex * CHUNK_SIZE) >= imgFile.fileSize())
  {
    imgFile.close();

    // ==================================================================
    // END OF TRANSMISSION (EOT) SIGNALING
    // ==================================================================
    uint8_t eotPacket[3] = {0xFF, 0xFF, 0x00}; // Chunk ID = 0xFFFF, Length = 0

    Serial.print("[TX] Sending EOT (End of Transmission) flag to COMMS... ");
    while (CommsUART.available())
    {
      CommsUART.read();
    }
    CommsUART.write(eotPacket, 3);

    unsigned long startTime = millis();
    bool gotAck = false;
    while (millis() - startTime < ACK_TIMEOUT_MS)
    {
      if (CommsUART.available())
      {
        if (CommsUART.readStringUntil('\n').indexOf("ACK") >= 0)
        {
          gotAck = true;
          break;
        }
      }
    }

    if (gotAck)
    {
      Serial.println("OK! (ACK Received)");
      Serial.println("\n[SUCCESS] Entire image transmitted to Earth successfully!");
      isTransferComplete = true;
      sd.remove(STATE_FILE); // Purge state file upon complete download
    }
    else
    {
      Serial.println("TIMEOUT! Will retry EOT next loop.");
    }

    IWatchdog.reload();
    return;
  }

  // Seek to the precise byte address of the current chunk
  imgFile.seek(currentChunkIndex * CHUNK_SIZE);

  uint8_t buffer[CHUNK_SIZE + 4];

  // Packet Header Construction
  buffer[0] = (currentChunkIndex >> 8) & 0xFF; // Chunk ID High Byte
  buffer[1] = currentChunkIndex & 0xFF;        // Chunk ID Low Byte

  // Read raw image block from SD Card
  int bytesRead = imgFile.read(&buffer[3], CHUNK_SIZE);
  imgFile.close();

  // Inject actual data length into Header (Supports dynamic trailing sub-chunks)
  buffer[2] = bytesRead & 0xFF;
  size_t packetSize = bytesRead + 3; // Total packet size: ID(2) + Len(1) + Payload

  // ------------------------------------------------------------------
  // Simulated Single Event Upset (SEU) - Radiation Anomaly
  // ------------------------------------------------------------------
  if (currentChunkIndex == 10 && !isRecovered)
  {
    Serial.println("\n[WARNING] RADIATION SPIKE DETECTED! SEU OCCURRED!");
    Serial.println("System enters infinite loop. Waiting for Watchdog to intervene...");
    saveTransferState(currentChunkIndex); // Ensure state is saved before hardware crash
    while (true)
    {
      // Infinite loop block. Hardware WDT will force reset after 4 seconds.
    }
  }

  // ------------------------------------------------------------------
  // Data Transmission Subsystem (OBC -> COMMS)
  // ------------------------------------------------------------------
  Serial.print("[TX] Sending Chunk #");
  Serial.print(currentChunkIndex);
  Serial.print(" to COMMS via UART... ");

  // Flush stale data in the incoming UART buffer
  while (CommsUART.available())
  {
    CommsUART.read();
  }

  // Stream raw data packet to COMMS board
  CommsUART.write(buffer, packetSize);

  // ------------------------------------------------------------------
  // Handshake Mechanism (Wait for ACK from COMMS)
  // ------------------------------------------------------------------
  unsigned long startTime = millis();
  bool gotAck = false;

  while (millis() - startTime < ACK_TIMEOUT_MS)
  {
    if (CommsUART.available() && CommsUART.readStringUntil('\n').indexOf("ACK") >= 0)
    {
      gotAck = true;
      break;
    }
  }

  if (gotAck)
  {
    Serial.println("OK! (ACK Received)");
    currentChunkIndex++;
    saveTransferState(currentChunkIndex); // Advance and log next mission checkpoint
  }
  else
  {
    Serial.println("TIMEOUT! (No ACK from COMMS). Will retransmit same chunk.");
  }

  IWatchdog.reload(); // Service the Watchdog Timer (Kick the Dog)
}