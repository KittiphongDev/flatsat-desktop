/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 6: Resilient Downlink & Radio Relay Subsystem
 * Module: Communication Module (COMMS) - Solution Code
 * Architecture: Receives dynamic data via UART, computes Checksum, encodes KISS, and transmits over RF.
 */

#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>

// ====================================================================
// HARDWARE PIN DEFINITIONS (COMMS Subsystem - STM32F411RE)
// ====================================================================
#define RADIO_SCK PA5
#define RADIO_MISO PA6
#define RADIO_MOSI PA7
#define RADIO_NSS PB6
#define RADIO_DIO0 PA10
#define RADIO_RESET PC7
#define RADIO_DIO1 -1

SX1278 radio = new Module(RADIO_NSS, RADIO_DIO0, RADIO_RESET, RADIO_DIO1, SPI);

// --- UART TO OBC MODULE ---
HardwareSerial ObcUART(PA12, PA11);

// ====================================================================
// KISS PROTOCOL DEFINITIONS & ENCODER
// ====================================================================
#define FEND 0xC0
#define FESC 0xDB
#define TFEND 0xDC
#define TFESC 0xDD

size_t encodeKISS(const uint8_t *payload, size_t payloadSize, uint8_t *outBuffer)
{
  size_t outIndex = 0;
  outBuffer[outIndex++] = FEND;
  for (size_t i = 0; i < payloadSize; i++)
  {
    uint8_t currentByte = payload[i];
    if (currentByte == FEND)
    {
      outBuffer[outIndex++] = FESC;
      outBuffer[outIndex++] = TFEND;
    }
    else if (currentByte == FESC)
    {
      outBuffer[outIndex++] = FESC;
      outBuffer[outIndex++] = TFESC;
    }
    else
    {
      outBuffer[outIndex++] = currentByte;
    }
  }
  outBuffer[outIndex++] = FEND;
  return outIndex;
}

// ====================================================================
// SETUP FUNCTION
// ====================================================================
void setup()
{
  Serial.begin(115200);  // Debug to PC USB
  ObcUART.begin(115200); // Inter-board connection
  delay(2000);
  Serial.println("\n=== FlatSat COMMS: Radio Relay Active ===");

  SPI.setMISO(RADIO_MISO);
  SPI.setMOSI(RADIO_MOSI);
  SPI.setSCLK(RADIO_SCK);
  SPI.begin();

  Serial.print("[SYSTEM] Initializing RF Module... ");
  if (radio.beginFSK() == RADIOLIB_ERR_NONE)
  {
    radio.setFrequency(433.0);
    radio.setBitRate(9.6);
    radio.setOutputPower(2); // Reduced power to prevent near-field receiver overload
    Serial.println("OK!");
  }
  else
  {
    Serial.println("FAILED!");
    while (true)
      ;
  }

  // Purge any power-on startup voltage transients (Phantom Data) from UART line
  Serial.println("[SYSTEM] Flushing phantom UART data...");
  delay(500);
  while (ObcUART.available())
  {
    ObcUART.read();
  }
  Serial.println("[SYSTEM] System Ready.");
}

// ====================================================================
// MAIN LOOP FUNCTION
// ====================================================================
void loop()
{
  // 1. Listen for incoming Packet Header (Chunk ID + Payload Length = 3 Bytes)
  if (ObcUART.available() >= 3)
  {
    uint8_t header[3];
    ObcUART.readBytes(header, 3);

    uint16_t chunkId = (header[0] << 8) | header[1];
    uint8_t payloadLen = header[2]; // Dynamic payload size parameter

    uint8_t rawPayload[100];
    rawPayload[0] = header[0];
    rawPayload[1] = header[1];
    rawPayload[2] = header[2];

    // 2. Read the remaining expected image block bytes
    ObcUART.setTimeout(250);
    size_t rxCount = ObcUART.readBytes(&rawPayload[3], payloadLen);

    if (rxCount == payloadLen)
    {
      size_t totalRawSize = 3 + payloadLen;

      // 3. Compute error detection Checksum (XOR-8)
      uint8_t checksum = 0;
      for (size_t i = 0; i < totalRawSize; i++)
      {
        checksum ^= rawPayload[i];
      }
      rawPayload[totalRawSize] = checksum; // Append Checksum byte

      // 4. Encapsulate raw frame inside KISS Protocol encapsulation
      uint8_t txKISSBuffer[150];
      size_t kissPacketSize = encodeKISS(rawPayload, totalRawSize + 1, txKISSBuffer);

      Serial.print("[RELAY] Encoded Chunk #");
      Serial.print(chunkId);
      Serial.print(" (Len: ");
      Serial.print(payloadLen);
      Serial.print(") into KISS (");
      Serial.print(kissPacketSize);
      Serial.print(" bytes). Transmitting to Earth... ");

      // 5. Modulate and transmit telemetry over the space channel
      int txState = radio.transmit(txKISSBuffer, kissPacketSize);
      if (txState != RADIOLIB_ERR_NONE)
      {
        Serial.print("RF Error: ");
        Serial.print(txState);
      }

      // 6. Standby and listen for the Ground Station RF Acknowledge (Stop-and-Wait ARQ)
      String rfResponse;
      int rxState = radio.receive(rfResponse, 1000); // 1-second downlink window

      if (rxState == RADIOLIB_ERR_NONE && rfResponse.indexOf("ACK") >= 0)
      {
        Serial.println(" -> Got RF ACK from Ground Station!");
        ObcUART.println("ACK"); // Pass handshake affirmation back to OBC
      }
      else
      {
        Serial.println(" -> RF Timeout / Drop. (Ignoring OBC, forcing retransmit)");
      }

      // Mitigation: Flush any localized EMI feedback loop noise picked up during TX
      while (ObcUART.available())
      {
        ObcUART.read();
      }
    }
    else
    {
      Serial.println("[ERROR] UART Payload fragmented. Flushing buffer.");
      while (ObcUART.available())
        ObcUART.read();
    }
  }
}