#include <Arduino.h>
#include <SPI.h>
#include <Wire.h>
#include "SdFat_Adafruit_Fork.h"

// ====================================================================
// HARDWARE PIN DEFINITIONS (STM32F429ZI - Nucleo-144)
// ====================================================================
#define SD_SCK PC10
#define SD_MISO PC11
#define SD_MOSI PC12
#define SD_CS PC9

#define I2C_SCL PB8
#define I2C_SDA PB9

#define PAYLOAD_PWR_PIN PG6 // Example MOSFET pin for Payload power

SPIClass SD_SPI(SD_MOSI, SD_MISO, SD_SCK);
SdFat sd;
HardwareSerial CommsUART(PA1, PA0);

// ====================================================================
// PROTOCOL & COMMANDS
// ====================================================================
enum CommandByte {
  CMD_PING         = 0x01,
  CMD_ACK          = 0x02,
  CMD_BEACON       = 0x03,
  CMD_TAKE_PIC     = 0x04,
  CMD_GET_GPS      = 0x05,
  CMD_TOGGLE_PWR   = 0x06,
  CMD_LIST_IMAGE   = 0x07,
  CMD_REMOVE_IMAGE = 0x08,
  CMD_REQ_CHUNK    = 0x09,
  CMD_STATUS       = 0x0A,
  CMD_IMAGE_DATA   = 0x0B
};

#define FEND 0xC0
#define FESC 0xDB
#define TFEND 0xDC
#define TFESC 0xDD
#define SYNC1 0xAA
#define SYNC2 0xBB

// ====================================================================
// SYSTEM STATES
// ====================================================================
unsigned long lastBeaconTime = 0;
unsigned long beaconInterval = 10000; // 10s default (Lost Link)
unsigned long lastAckTime = 0;
const unsigned long LINK_TIMEOUT = 15000;

uint8_t systemErrors = 0x00;
#define ERR_I2C    0x01
#define ERR_SD     0x02
#define ERR_EPS    0x04

bool payloadPwrState = false;

// ====================================================================
// UTILITIES
// ====================================================================
uint32_t calculateCRC32(const uint8_t *data, size_t length) {
  uint32_t crc = 0xFFFFFFFF;
  for (size_t i = 0; i < length; i++) {
    crc ^= data[i];
    for (uint8_t j = 0; j < 8; j++) {
      if (crc & 1) crc = (crc >> 1) ^ 0xEDB88320;
      else crc >>= 1;
    }
  }
  return ~crc;
}

void checkHardware() {
  systemErrors = 0;
  Wire.beginTransmission(0x20); // Example EPS I2C Address
  if (Wire.endTransmission() != 0) systemErrors |= ERR_EPS;
}

// ====================================================================
// PACKET BUILDER & TRANSMITTER
// ====================================================================
void sendPacket(uint8_t cmdType, const uint8_t *payload, uint8_t payloadLen) {
  uint8_t packet[256];
  packet[0] = SYNC1;
  packet[1] = SYNC2;
  packet[2] = cmdType;
  packet[3] = payloadLen;
  
  if (payloadLen > 0 && payload != nullptr) {
    memcpy(&packet[4], payload, payloadLen);
  }
  
  uint32_t crc = calculateCRC32(packet, 4 + payloadLen);
  packet[4 + payloadLen] = (crc >> 24) & 0xFF;
  packet[5 + payloadLen] = (crc >> 16) & 0xFF;
  packet[6 + payloadLen] = (crc >> 8) & 0xFF;
  packet[7 + payloadLen] = crc & 0xFF;

  size_t totalPacketLen = 8 + payloadLen;

  // KISS ENCODE
  CommsUART.write(FEND);
  for (size_t i = 0; i < totalPacketLen; i++) {
    if (packet[i] == FEND) {
      CommsUART.write(FESC);
      CommsUART.write(TFEND);
    } else if (packet[i] == FESC) {
      CommsUART.write(FESC);
      CommsUART.write(TFESC);
    } else {
      CommsUART.write(packet[i]);
    }
  }
  CommsUART.write(FEND);
}

void sendBeacon() {
  checkHardware();
  uint8_t beaconData[5];
  beaconData[0] = systemErrors;
  beaconData[1] = payloadPwrState ? 1 : 0;
  beaconData[2] = 80; // Mock Battery %
  beaconData[3] = 25; // Mock Temp
  beaconData[4] = 12; // Mock Voltage
  sendPacket(CMD_BEACON, beaconData, 5);
}

// ====================================================================
// COMMAND HANDLER
// ====================================================================
void handleCommand(uint8_t cmdType, uint8_t *payload, uint8_t payloadLen) {
  switch (cmdType) {
    case CMD_PING:
      sendPacket(CMD_ACK, nullptr, 0);
      break;
    case CMD_ACK:
      lastAckTime = millis();
      break;
    case CMD_STATUS:
      sendBeacon();
      break;
    case CMD_TOGGLE_PWR:
      payloadPwrState = !payloadPwrState;
      digitalWrite(PAYLOAD_PWR_PIN, payloadPwrState ? HIGH : LOW);
      sendPacket(CMD_ACK, nullptr, 0);
      break;
    case CMD_REQ_CHUNK:
      if (payloadLen >= 2) {
        uint16_t chunkId = (payload[0] << 8) | payload[1];
        File img = sd.open("photo.jpg", O_RDONLY);
        if (img) {
          uint8_t chunkData[64];
          chunkData[0] = payload[0]; // Echo Chunk ID High
          chunkData[1] = payload[1]; // Echo Chunk ID Low
          img.seek(chunkId * 48); // 48 bytes per chunk
          int bytesRead = img.read(&chunkData[2], 48);
          img.close();
          sendPacket(CMD_IMAGE_DATA, chunkData, bytesRead + 2);
        }
      }
      break;
    // ... Implement TAKE_PIC, LIST_IMAGE, etc. ...
  }
}

// ====================================================================
// KISS DECODER & RX LOOP
// ====================================================================
uint8_t rxBuffer[256];
uint16_t rxIndex = 0;
bool inFrame = false;
bool escapeNext = false;

void processIncomingUART() {
  while (CommsUART.available()) {
    uint8_t c = CommsUART.read();
    
    if (c == FEND) {
      if (inFrame && rxIndex > 0) {
        // Parse Packet
        if (rxIndex >= 8 && rxBuffer[0] == SYNC1 && rxBuffer[1] == SYNC2) {
          uint8_t cmdType = rxBuffer[2];
          uint8_t payloadLen = rxBuffer[3];
          uint32_t expectedCrc = (rxBuffer[rxIndex-4] << 24) | (rxBuffer[rxIndex-3] << 16) | (rxBuffer[rxIndex-2] << 8) | rxBuffer[rxIndex-1];
          uint32_t calcCrc = calculateCRC32(rxBuffer, rxIndex - 4);
          
          if (expectedCrc == calcCrc) {
            handleCommand(cmdType, &rxBuffer[4], payloadLen);
            lastAckTime = millis(); // Any valid packet from GS counts as link alive
          }
        }
        rxIndex = 0;
        inFrame = false;
      } else {
        inFrame = true;
      }
    } else if (inFrame) {
      if (c == FESC) {
        escapeNext = true;
      } else if (escapeNext) {
        if (c == TFEND) rxBuffer[rxIndex++] = FEND;
        else if (c == TFESC) rxBuffer[rxIndex++] = FESC;
        escapeNext = false;
      } else {
        rxBuffer[rxIndex++] = c;
      }
    }
  }
}

// ====================================================================
// MAIN
// ====================================================================
void setup() {
  Serial.setRx(PD9);
  Serial.setTx(PD8);
  Serial.begin(115200);
  
  CommsUART.begin(115200);
  Wire.begin();
  
  pinMode(PAYLOAD_PWR_PIN, OUTPUT);
  digitalWrite(PAYLOAD_PWR_PIN, LOW);
  
  SD_SPI.begin();
  if (!sd.begin(SdSpiConfig(SD_CS, DEDICATED_SPI, SD_SCK_MHZ(10), &SD_SPI))) {
    systemErrors |= ERR_SD;
  }
}

void loop() {
  unsigned long currentMillis = millis();

  if (currentMillis - lastAckTime > LINK_TIMEOUT) {
    beaconInterval = 10000;
  } else {
    beaconInterval = 1000;
  }

  if (currentMillis - lastBeaconTime >= beaconInterval) {
    sendBeacon();
    lastBeaconTime = currentMillis;
  }

  processIncomingUART();
}
