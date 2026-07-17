/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 4.3: Mission Control - Ground Station (Solution Key)
 * Objective: Initialize Ground Station RF, Decode KISS packets, and Verify Checksums.
 */

#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>

// Link the automated BIST system
#include "src/Lab4_TB_Mission_Control.h"

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

// Instantiate the SX1278 radio module object
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
// KISS PROTOCOL DEFINITIONS
// ====================================================================
#define FEND 0xC0
#define FESC 0xDB
#define TFEND 0xDC
#define TFESC 0xDD

// ---------------------------------------------------------
// TODO 1: Radio Hardware Initialization (FILLED SOLUTION)
// ---------------------------------------------------------
int initRadioHardware(SX1278 &radioObj)
{
  int state = radioObj.beginFSK();
  if (state == RADIOLIB_ERR_NONE)
  {
    radioObj.setFrequency(433.0);
    radioObj.setBitRate(9.6);
  }
  return state;
}

// ---------------------------------------------------------
// TODO 2: KISS Protocol Decoder (FILLED SOLUTION)
// ---------------------------------------------------------
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
        inFrame = true;
      }
      else
      {
        break;
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

// ---------------------------------------------------------
// TODO 3: Checksum Verification (FILLED SOLUTION)
// ---------------------------------------------------------
bool verifyChecksum(const uint8_t *payload, size_t payloadSize)
{
  if (payloadSize < 2)
    return false;

  uint8_t calculatedXor = 0;
  for (size_t i = 0; i < payloadSize - 1; i++)
  {
    calculatedXor ^= payload[i];
  }

  uint8_t receivedXor = payload[payloadSize - 1];
  return (calculatedXor == receivedXor);
}

void setup()
{
  Serial.setTx(PC10);
  Serial.setRx(PC11);
  Serial.begin(115200);
  delay(2000);

  Serial.println("\n=== FlatSat COMMS: Mission Control (Ground Station) ===");

  SPI.setMISO(RADIO_MISO);
  SPI.setMOSI(RADIO_MOSI);
  SPI.setSCLK(RADIO_SCK);
  SPI.begin();

  // Run BIST to test decoding and checksum logic
  runMissionControlTestbench(radio, initRadioHardware, decodeKISS, verifyChecksum);

  // Remap hardware interrupt pins after the local verification engine finishes
  radio.setDio0Action(setFlag, RISING);
  int state = radio.startReceive();
  if (state == RADIOLIB_ERR_NONE)
  {
    Serial.println("\nGround Station is now listening for FlatSat Telemetry (Interrupt Mode)...");
  }
  else
  {
    Serial.print("\nFailed to start receiver, code: ");
    Serial.println(state);
  }
}

void loop()
{
  if (receivedFlag)
  {
    receivedFlag = false;

    uint8_t rxBuffer[256];
    size_t rxSize = radio.getPacketLength();
    int state = radio.readData(rxBuffer, rxSize);

    if (state == RADIOLIB_ERR_NONE)
    {
      uint8_t payload[256];
      size_t payloadSize = decodeKISS(rxBuffer, rxSize, payload);

      if (payloadSize > 0)
      {
        Serial.print("\nSignal Caught! RSSI: ");
        Serial.print(radio.getRSSI());
        Serial.println(" dBm");

        if (verifyChecksum(payload, payloadSize))
        {
          Serial.print(" 🟢 Valid Payload Received (Hex): ");
          for (size_t i = 0; i < payloadSize - 1; i++)
          {
            Serial.print(payload[i], HEX);
            Serial.print(" ");
          }
          Serial.println();
        }
        else
        {
          Serial.println(" 🔴 [ERROR] Checksum Mismatch: Packet Dropped!");
        }
      }
    }
    else
    {
      Serial.print(" 🔴 [RX] Hardware Error reading data, code: ");
      Serial.println(state);
    }

    radio.startReceive(); // Keep listening in the background
  }
}