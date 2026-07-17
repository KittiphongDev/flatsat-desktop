/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 6: Resilient Downlink (Ground Station Receiver)
 * Architecture: Interrupt-based RF Receive -> KISS Decode -> Verify Checksum -> Transmit ACK -> Serial to PC
 */

#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>

// ====================================================================
// HARDWARE PIN DEFINITIONS (Ground Station Module - STM32F103RC)
// ====================================================================
#define RADIO_SCK PA5
#define RADIO_MISO PA6
#define RADIO_MOSI PA7
#define RADIO_NSS PB6
#define RADIO_DIO0 PA10
#define RADIO_RESET PC7
#define RADIO_DIO1 -1

SX1278 radio = new Module(RADIO_NSS, RADIO_DIO0, RADIO_RESET, RADIO_DIO1, SPI);

// ====================================================================
// INTERRUPT FLAG & ISR (Interrupt Service Routine)
// ====================================================================
volatile bool receivedFlag = false;

void setFlag(void)
{
  receivedFlag = true;
}

// ====================================================================
// KISS PROTOCOL DEFINITIONS & DECODER
// ====================================================================
#define FEND 0xC0
#define FESC 0xDB
#define TFEND 0xDC
#define TFESC 0xDD

size_t decodeKISS(const uint8_t *inBuffer, size_t inSize, uint8_t *outBuffer)
{
  size_t outIndex = 0;
  bool inFrame = false;
  bool escapeNext = false;

  for (size_t i = 0; i < inSize; i++)
  {
    uint8_t currentByte = inBuffer[i];

    if (currentByte == FEND)
    {
      if (!inFrame)
      {
        inFrame = true; // Frame synchronization marker detected
      }
      else
      {
        break; // Trailing Frame marker detected, close packet safely
      }
    }
    else if (inFrame)
    {
      if (currentByte == FESC)
      {
        escapeNext = true;
      }
      else if (escapeNext)
      {
        if (currentByte == TFEND)
          outBuffer[outIndex++] = FEND;
        else if (currentByte == TFESC)
          outBuffer[outIndex++] = FESC;
        escapeNext = false;
      }
      else
      {
        outBuffer[outIndex++] = currentByte;
      }
    }
  }
  return outIndex;
}

bool verifyChecksum(const uint8_t *payload, size_t payloadSize)
{
  if (payloadSize < 2)
    return false;
  uint8_t expectedChecksum = payload[payloadSize - 1];
  uint8_t calculatedChecksum = 0;
  for (size_t i = 0; i < payloadSize - 1; i++)
  {
    calculatedChecksum ^= payload[i];
  }
  return (calculatedChecksum == expectedChecksum);
}

// ====================================================================
// SETUP FUNCTION
// ====================================================================
void setup()
{
  Serial.setTx(PC10);
  Serial.setRx(PC11);
  Serial.begin(115200);
  delay(2000);

  Serial.println("\n=== FlatSat Ground Station: Image Assembler Ready ===");

  SPI.setMISO(RADIO_MISO);
  SPI.setMOSI(RADIO_MOSI);
  SPI.setSCLK(RADIO_SCK);
  SPI.begin();

  if (radio.beginFSK() == RADIOLIB_ERR_NONE)
  {
    radio.setFrequency(433.0);
    radio.setBitRate(9.6);
    radio.setOutputPower(2);

    // Bind hardware transceiver event to ISR flag
    radio.setDio0Action(setFlag, RISING);

    // Trigger baseline unblocking background reception
    int state = radio.startReceive();
    if (state == RADIOLIB_ERR_NONE)
    {
      Serial.println("[SYSTEM] RF Interrupt enabled. Listening to the sky...");
    }
    else
    {
      Serial.print("[ERROR] Failed to start receive. Code: ");
      Serial.println(state);
    }
  }
  else
  {
    Serial.println("[ERROR] RF Module failed!");
    while (true)
      ;
  }
}

// ====================================================================
// MAIN LOOP FUNCTION
// ====================================================================
void loop()
{
  if (receivedFlag)
  {
    receivedFlag = false; // Reset background execution loop flag

    uint8_t rxBuffer[256];
    size_t rxSize = radio.getPacketLength();
    int state = radio.readData(rxBuffer, rxSize);

    if (state == RADIOLIB_ERR_NONE)
    {
      uint8_t payload[256];
      size_t payloadSize = decodeKISS(rxBuffer, rxSize, payload);

      if (payloadSize > 0)
      {
        if (verifyChecksum(payload, payloadSize))
        {
          // Output serialized binary payload telemetry to PC via pipeline token
          Serial.print("CHUNK_DATA:");
          for (size_t i = 0; i < payloadSize - 1; i++)
          {
            if (payload[i] < 16)
              Serial.print("0");
            Serial.print(payload[i], HEX);
          }
          Serial.println();

          // Dispatch stop-and-wait acknowledgement frame to space
          delay(50);
          radio.transmit("ACK");
        }
        else
        {
          Serial.println("[WARNING] Checksum Mismatch! Packet Dropped.");
        }
      }
      else
      {
        Serial.println("[WARNING] KISS Decode failed! Incomplete frame.");
      }
    }
    else if (state == RADIOLIB_ERR_CRC_MISMATCH)
    {
      Serial.println("[WARNING] RF CRC Mismatch! Bad signal received.");
    }

    // Reactivate non-blocking hardware receiver state
    radio.startReceive();

    // Crucial: Clear secondary TxDone ghost interrupt artifact created by radio.transmit()
    receivedFlag = false;
  }
}