/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 4.2: Space-to-Ground Link (Solution Key)
 * Objective: Initialize RF hardware, encapsulate data with KISS, and transmit.
 * Warning: This code must be uploaded directly to the COMMS Subsystem Board (STM32F411RE).
 */

#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>

// Link the automated BIST system hidden inside the src directory
#include "src/Lab4_TB_Space_Link.h"

// ====================================================================
// HARDWARE PIN DEFINITIONS (Communication Module)
// ====================================================================
#define RADIO_SCK PA5
#define RADIO_MISO PA6
#define RADIO_MOSI PA7
#define RADIO_NSS PB6
#define RADIO_DIO0 PA10
#define RADIO_RESET PC7
#define RADIO_DIO1 -1

// Instantiate the SX1278 radio module object explicitly mapped to standard SPI bus
SX1278 radio = new Module(RADIO_NSS, RADIO_DIO0, RADIO_RESET, RADIO_DIO1, SPI);

// ====================================================================
// KISS PROTOCOL ENCODER (From Lab 4.1)
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
    radioObj.setOutputPower(2); // Set low power to prevent saturation on desk testing
  }
  return state;
}

// ---------------------------------------------------------
// TODO 2: Data Encapsulation & Transmission (FILLED SOLUTION)
// ---------------------------------------------------------
int transmitKISSFrame(SX1278 &radioObj, const uint8_t *payload, size_t size)
{
  uint8_t txBuffer[64];
  size_t packetSize = encodeKISS(payload, size, txBuffer);

  Serial.print("Transmitting RF Packet: ");
  for (size_t i = 0; i < packetSize; i++)
  {
    Serial.print(txBuffer[i], HEX);
    Serial.print(" ");
  }
  Serial.println();

  return radioObj.transmit(txBuffer, packetSize);
}

void setup()
{
  Serial.setTx(PA2);
  Serial.setRx(PA3);
  Serial.begin(115200);
  delay(2000);

  Serial.println("\n=== FlatSat COMMS: Space-to-Ground Link ===");

  SPI.setMISO(RADIO_MISO);
  SPI.setMOSI(RADIO_MOSI);
  SPI.setSCLK(RADIO_SCK);
  SPI.begin();

  // Run Built-In Self-Test (BIST)
  runSpaceLinkTestbench(radio, initRadioHardware, transmitKISSFrame);
}

void loop()
{
  static uint8_t frameCounter = 0;

  // Case A: Nominal Telemetry Packet (0x12 ^ 0x34 ^ 0x56 = 0x70 Valid Checksum)
  uint8_t nominalData[] = {0x12, 0x34, 0x56, 0x70};

  // Case B: Core Byte-Stuffing Stress Frame (0x05 ^ 0xC0 ^ 0xDB = 0x1E Valid Checksum)
  uint8_t stuffedData[] = {0x05, 0xC0, 0xDB, 0x1E};

  // Case C: Anomalous Corrupted Packet (0x12 ^ 0x34 ^ 0x56 = 0x70 but corrupted with 0xFF)
  uint8_t corruptedData[] = {0x12, 0x34, 0x56, 0xFF};

  Serial.println("--------------------------------------------------");
  if (frameCounter == 0)
  {
    Serial.println("[TX Cycle] Injecting Case A: Nominal Telemetry Beacon...");
    transmitKISSFrame(radio, nominalData, sizeof(nominalData));
    frameCounter = 1;
  }
  else if (frameCounter == 1)
  {
    Serial.println("[TX Cycle] Injecting Case B: Core Byte-Stuffing Stress Frame...");
    transmitKISSFrame(radio, stuffedData, sizeof(stuffedData));
    frameCounter = 2;
  }
  else
  {
    Serial.println("[TX Cycle] Injecting Case C: Malformed Telemetry Anomaly (Forcing Checksum Fail)...");
    transmitKISSFrame(radio, corruptedData, sizeof(corruptedData));
    frameCounter = 0;
  }
  Serial.println("--------------------------------------------------\n");

  delay(3000);
}