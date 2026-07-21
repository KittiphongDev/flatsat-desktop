/*
 * FlatSat New Architecture
 * On-Board Computer (OBC) - STM32F429ZI
 * Non-blocking state machine with dynamic beacon, resumable downloads,
 * and full command set.
 */

#include <Arduino.h>
#include <SPI.h>
#include <Wire.h>
#include "SdFat_Adafruit_Fork.h"
#include <IWatchdog.h>

// ====================================================================
// HARDWARE PIN DEFINITIONS (STM32F429ZI - Nucleo-144)
// ====================================================================

// --- SD CARD BUS (SPI3 - Dedicated) ---
#define SD_SCK PC10
#define SD_MISO PC11
#define SD_MOSI PC12
#define SD_CS PC9

// --- I2C BUS (Sensors / EPS) ---
#define I2C_SCL PB8
#define I2C_SDA PB9

// --- MOSFET POWER SWITCHES ---
#define PAYLOAD_PWR_PIN PG6   // Payload subsystem power MOSFET
#define GPS_PWR_PIN PG7       // GPS module power MOSFET
#define CAM_PWR_PIN PG8       // Camera module power MOSFET

// --- EPS SENSOR BUS (I2C2 - Dedicated to EPS sensors) ---
#define EPS_SDA PF0
#define EPS_SCL PF1

// --- Hardware Instances ---
SPIClass SD_SPI(SD_MOSI, SD_MISO, SD_SCK);
SdFat sd;
HardwareSerial CommsUART(PA1, PA0); // UART to COMMU module

// ====================================================================
// EPS SENSOR DRIVERS (INA226 / TMP102 / ADM1177 over dedicated I2C)
// Ported from obc_read_eps.ino — see that sketch for datasheet notes.
// ====================================================================

// ---- Base class: generic I2C device -------------------------------
class I2CDevice {
protected:
  TwoWire& wire;
  uint8_t  address;

public:
  I2CDevice(TwoWire& wireInstance, uint8_t addr)
      : wire(wireInstance), address(addr) {}

  void writeRegister16(uint8_t reg, uint16_t value) {
    wire.beginTransmission(address);
    wire.write(reg);
    wire.write((value >> 8) & 0xFF);
    wire.write(value & 0xFF);
    wire.endTransmission();
  }

  void writePointer(uint8_t reg) {
    wire.beginTransmission(address);
    wire.write(reg);
    wire.endTransmission();
  }

  uint16_t readRegister16(uint8_t reg) {
    wire.beginTransmission(address);
    wire.write(reg);
    wire.endTransmission(false); // Repeated START
    wire.requestFrom(address, (uint8_t)2);
    if (wire.available() >= 2) {
      uint16_t value = (uint16_t)wire.read() << 8; // MSB
      value |= wire.read();                        // LSB
      return value;
    }
    return 0;
  }

  uint8_t readBytes(uint8_t* buf, uint8_t len) {
    wire.requestFrom(address, len);
    uint8_t i = 0;
    while (wire.available() && i < len) {
      buf[i++] = wire.read();
    }
    return i;
  }
};

// ---- INA226: Voltage / Current / Power monitor --------------------
class INA226 : public I2CDevice {
public:
  INA226(TwoWire& wireInstance, uint8_t addr = 0x40)
      : I2CDevice(wireInstance, addr) {}

  bool begin() {
    uint16_t config = readRegister16(REG_CONFIG);
    return (config != 0x0000 && config != 0xFFFF);
  }

  void calibrate(float rShunt_Ohms, float maxExpectedCurrent_Amps) {
    currentLSB = maxExpectedCurrent_Amps / 32768.0f;
    uint16_t calValue = (uint16_t)(0.00512f / (currentLSB * rShunt_Ohms));
    writeRegister16(REG_CALIBRATION, calValue);
  }

  float getBusVoltage_V() {
    uint16_t raw = readRegister16(REG_BUS_VOLTAGE);
    return raw * 0.00125f; // LSB = 1.25 mV
  }

  float getCurrent_A() {
    if (currentLSB == 0.0f) return 0.0f;
    int16_t raw = (int16_t)readRegister16(REG_CURRENT);
    return raw * currentLSB;
  }

private:
  float currentLSB = 0.0f;
  const uint8_t REG_CONFIG      = 0x00;
  const uint8_t REG_BUS_VOLTAGE = 0x02;
  const uint8_t REG_CURRENT     = 0x04;
  const uint8_t REG_CALIBRATION = 0x05;
};

// ---- TMP102: Digital temperature sensor ---------------------------
class TMP102 : public I2CDevice {
public:
  TMP102(TwoWire& wireInstance, uint8_t addr = 0x48)
      : I2CDevice(wireInstance, addr) {}

  float readTemperatureC() {
    uint16_t raw  = readRegister16(REG_TEMPERATURE);
    int16_t  temp = (int16_t)raw >> 4; // 12-bit result
    return temp * 0.0625f;             // LSB = 0.0625 C
  }

private:
  static const uint8_t REG_TEMPERATURE = 0x00;
};

// ---- ADM1177: Hot-swap controller / power monitor -----------------
class ADM1177 : public I2CDevice {
public:
  ADM1177(TwoWire& wireInstance, float rSenseOhms, uint8_t addr = 0x2D)
      : I2CDevice(wireInstance, addr), rSense(rSenseOhms) {}

  void startConversion() {
    writePointer(CMD_V_CONT | CMD_I_CONT | CMD_VRANGE);
  }

  bool readData(uint16_t &voltage, uint16_t &current) {
    uint8_t buf[3] = {0};
    if (readBytes(buf, 3) < 3) return false;

    uint16_t vRaw = ((uint16_t)(buf[0] << 4)) | (buf[2] >> 4);
    uint16_t iRaw = ((uint16_t)(buf[1] << 4)) | (buf[2] & 0x0F);
    voltage = vRaw * (V_FULLSCALE   /  (ADM_RESOLUTION / 1000.0f));
    current = iRaw * (I_LSB_PER_OHM / ((ADM_RESOLUTION / 1000.0f) * rSense));
    return true;
  }

private:
  float rSense;
  static const uint8_t CMD_V_CONT = 0b00000001;
  static const uint8_t CMD_I_CONT = 0b00000100;
  static const uint8_t CMD_VRANGE = 0b00010000;
  const float V_FULLSCALE   = 6.65f;
  const float I_LSB_PER_OHM = 0.10584f;
  const float ADM_RESOLUTION = 4096.0f;
};

// ---- EPS bus + sensor instances -----------------------------------
TwoWire EPS_SEN(EPS_SDA, EPS_SCL);

#define INA226_COUNT  6
#define TMP102_COUNT  2
#define ADM1177_COUNT 4

INA226 powerMonitors[INA226_COUNT] = {
  INA226(EPS_SEN, 0x40),
  INA226(EPS_SEN, 0x41),
  INA226(EPS_SEN, 0x42),
  INA226(EPS_SEN, 0x43),
  INA226(EPS_SEN, 0x47),
  INA226(EPS_SEN, 0x48),
};

TMP102 tempSensors[TMP102_COUNT] = {
  TMP102(EPS_SEN, 0x4A),
  TMP102(EPS_SEN, 0x4B),
};

ADM1177 powerControllers[ADM1177_COUNT] = {
  ADM1177(EPS_SEN, 0.06f, 0x58),
  ADM1177(EPS_SEN, 0.06f, 0x59),
  ADM1177(EPS_SEN, 0.06f, 0x5A),
  ADM1177(EPS_SEN, 0.06f, 0x5B),
};

const float INA226_SHUNT_OHMS = 0.02f;
const float INA226_MAX_AMPS   = 4.096f;

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
  CMD_IMAGE_DATA   = 0x0B,
  CMD_GPS_DATA     = 0x0C,
  CMD_IMAGE_LIST   = 0x0D,
  CMD_NACK         = 0x0E,
  CMD_GET_EPS      = 0x0F, // GS -> OBC: request full EPS telemetry
  CMD_EPS_DATA     = 0x10  // OBC -> GS: full EPS telemetry dump
};

// --- KISS Framing ---
#define FEND  0xC0
#define FESC  0xDB
#define TFEND 0xDC
#define TFESC 0xDD

// --- Application Layer Sync ---
#define SYNC1 0xAA
#define SYNC2 0xBB

// --- Image Transfer ---
#define CHUNK_SIZE 48
#define WDT_TIMEOUT_US 10000000 // 10 seconds

// ====================================================================
// SYSTEM STATE
// ====================================================================
unsigned long lastBeaconTime = 0;
unsigned long beaconInterval = 10000; // 10s default (Lost Link)
unsigned long lastAckTime = 0;
const unsigned long LINK_TIMEOUT = 15000; // 15s without ACK = slow down

// --- Error Tracking (Bitmask) ---
uint8_t systemErrors = 0x00;
#define ERR_I2C  0x01
#define ERR_SD   0x02
#define ERR_EPS  0x04
#define ERR_CAM  0x08
#define ERR_GPS  0x10

// --- Subsystem Power States ---
bool payloadPwrState = false;
bool gpsPwrState = false;
bool camPwrState = false;

// --- Image Counter ---
uint32_t imageCounter = 0;

// --- Download State ---
char downloadFilename[64] = "photo.jpg"; // Default file for download

// ====================================================================
// CRC32 CALCULATION
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

// ====================================================================
// NON-BLOCKING HARDWARE CHECK
// ====================================================================
void checkHardware() {
  systemErrors = 0;

  // Check EPS: probe the first INA226 on the dedicated EPS bus
  EPS_SEN.beginTransmission(0x40);
  if (EPS_SEN.endTransmission() != 0) systemErrors |= ERR_EPS;

  // Check SD Card
  if (!sd.exists("/")) systemErrors |= ERR_SD;
}

// ====================================================================
// EPS SENSOR INITIALISATION (non-blocking — flags ERR_EPS on failure)
// ====================================================================
void initEPS() {
  EPS_SEN.begin();

  bool allOk = true;
  for (int i = 0; i < INA226_COUNT; i++) {
    if (!powerMonitors[i].begin()) {
      allOk = false;
      Serial.print("[EPS] INA226 not found at index ");
      Serial.println(i);
    }
    powerMonitors[i].calibrate(INA226_SHUNT_OHMS, INA226_MAX_AMPS);
  }
  // Last two INA226s use a 0.01 ohm shunt (matches obc_read_eps.ino)
  powerMonitors[INA226_COUNT - 1].calibrate(0.01f, INA226_MAX_AMPS);
  powerMonitors[INA226_COUNT - 2].calibrate(0.01f, INA226_MAX_AMPS);

  for (int i = 0; i < ADM1177_COUNT; i++) {
    powerControllers[i].startConversion();
  }

  if (!allOk) systemErrors |= ERR_EPS;
  Serial.print("[EPS] Sensors initialised, status: ");
  Serial.println(allOk ? "OK" : "DEGRADED");
}

// ====================================================================
// EPS TELEMETRY PACKET BUILDER
// Payload layout (multi-byte fields little-endian):
//   [1]  INA count N1
//   N1 x { float busVoltage_V (4), float current_A (4) }
//   [1]  TMP count N2
//   N2 x { float tempC (4) }
//   [1]  ADM count N3
//   N3 x { uint16 voltage_mV (LE), uint16 current_mA (LE) }
// ====================================================================
void sendEPSData() {
  uint8_t payload[200];
  uint8_t idx = 0;

  // --- INA226 block ---
  payload[idx++] = INA226_COUNT;
  for (int i = 0; i < INA226_COUNT; i++) {
    float busV = powerMonitors[i].getBusVoltage_V();
    float curA = powerMonitors[i].getCurrent_A();
    memcpy(&payload[idx], &busV, 4); idx += 4;
    memcpy(&payload[idx], &curA, 4); idx += 4;
  }

  // --- TMP102 block ---
  payload[idx++] = TMP102_COUNT;
  for (int i = 0; i < TMP102_COUNT; i++) {
    float tempC = tempSensors[i].readTemperatureC();
    memcpy(&payload[idx], &tempC, 4); idx += 4;
  }

  // --- ADM1177 block ---
  payload[idx++] = ADM1177_COUNT;
  for (int i = 0; i < ADM1177_COUNT; i++) {
    uint16_t v = 0, c = 0;
    powerControllers[i].readData(v, c); // v/c stay 0 on read failure
    payload[idx++] = v & 0xFF;          // LSB
    payload[idx++] = (v >> 8) & 0xFF;   // MSB
    payload[idx++] = c & 0xFF;
    payload[idx++] = (c >> 8) & 0xFF;
  }

  sendPacket(CMD_EPS_DATA, payload, idx);
  Serial.print("[EPS] Telemetry sent, payload bytes: ");
  Serial.println(idx);
}

// ====================================================================
// PACKET BUILDER & KISS ENCODER
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

  // KISS Encode and Transmit
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

  Serial.print("[TX] Sent CMD 0x");
  Serial.print(cmdType, HEX);
  Serial.print(" PayloadLen=");
  Serial.println(payloadLen);
}

// ====================================================================
// BEACON BUILDER
// ====================================================================
void sendBeacon() {
  checkHardware();

  uint8_t beaconData[8];
  beaconData[0] = systemErrors;                  // Error bitmask
  beaconData[1] = payloadPwrState ? 1 : 0;       // Payload power state
  beaconData[2] = gpsPwrState ? 1 : 0;           // GPS power state
  beaconData[3] = camPwrState ? 1 : 0;           // Camera power state
  beaconData[4] = 80;                            // Battery % (mock/read from EPS)
  beaconData[5] = 25;                            // OBC Temp (mock/read from sensor)
  beaconData[6] = 12;                            // Solar Voltage (mock/read from EPS)
  beaconData[7] = (millis() - lastAckTime < LINK_TIMEOUT) ? 1 : 0; // Link status

  sendPacket(CMD_BEACON, beaconData, 8);
  Serial.println("[BEACON] Transmitted");
}

// ====================================================================
// COMMAND HANDLER (Full Implementation)
// ====================================================================
void handleCommand(uint8_t cmdType, uint8_t *payload, uint8_t payloadLen) {
  Serial.print("[RX] CMD 0x");
  Serial.println(cmdType, HEX);

  switch (cmdType) {

    // --- PING ---
    case CMD_PING:
      sendPacket(CMD_ACK, nullptr, 0);
      Serial.println("[CMD] PING -> ACK");
      break;

    // --- ACK ---
    case CMD_ACK:
      lastAckTime = millis();
      Serial.println("[CMD] ACK received");
      break;

    // --- STATUS (Force immediate beacon) ---
    case CMD_STATUS:
      sendBeacon();
      Serial.println("[CMD] STATUS -> Beacon sent");
      break;

    // --- GET EPS (Full EPS telemetry dump) ---
    case CMD_GET_EPS:
      sendEPSData();
      Serial.println("[CMD] GET_EPS -> EPS data sent");
      break;

    // --- BEACON (Force immediate beacon from GS) ---
    case CMD_BEACON:
      sendBeacon();
      Serial.println("[CMD] BEACON forced by GS");
      break;

    // --- TAKE PICTURE ---
    case CMD_TAKE_PIC: {
      Serial.println("[CMD] TAKE_PIC");
      // Build filename: img_XXXX.jpg
      char filename[32];
      snprintf(filename, sizeof(filename), "img_%04lu.jpg", imageCounter);

      // TODO: Read actual camera FIFO here
      // For now, create a placeholder file to confirm SD write works
      File imgFile;
      if (imgFile.open(filename, O_WRONLY | O_CREAT | O_TRUNC)) {
        // Write placeholder data (replace with actual camera data)
        uint8_t placeholder[] = {0xFF, 0xD8, 0xFF, 0xE0}; // JPEG header stub
        imgFile.write(placeholder, sizeof(placeholder));
        imgFile.close();
        imageCounter++;

        // Respond with ACK containing the filename
        uint8_t ackPayload[32];
        uint8_t fnLen = strlen(filename);
        memcpy(ackPayload, filename, fnLen);
        sendPacket(CMD_ACK, ackPayload, fnLen);
        Serial.print("[CMD] Picture saved: ");
        Serial.println(filename);
      } else {
        sendPacket(CMD_NACK, nullptr, 0);
        Serial.println("[CMD] TAKE_PIC FAILED - SD write error");
      }
      break;
    }

    // --- GET GPS ---
    case CMD_GET_GPS: {
      Serial.println("[CMD] GET_GPS");
      // TODO: Read actual GPS NMEA data from GPS UART
      // Mock GPS data for now
      uint8_t gpsData[16];
      // Latitude (float, 4 bytes) - mock: 13.7563 (Bangkok)
      float lat = 13.7563f;
      float lon = 100.5018f;
      float alt = 150.0f;
      uint8_t satCount = 8;
      memcpy(&gpsData[0], &lat, 4);
      memcpy(&gpsData[4], &lon, 4);
      memcpy(&gpsData[8], &alt, 4);
      gpsData[12] = satCount;

      sendPacket(CMD_GPS_DATA, gpsData, 13);
      Serial.println("[CMD] GPS data sent");
      break;
    }

    // --- TOGGLE POWER ---
    case CMD_TOGGLE_PWR: {
      if (payloadLen >= 1) {
        uint8_t subsystem = payload[0];
        // Subsystem IDs: 0=Payload, 1=GPS, 2=Camera
        uint8_t responsePayload[2];
        responsePayload[0] = subsystem;

        switch (subsystem) {
          case 0: // Payload
            payloadPwrState = !payloadPwrState;
            digitalWrite(PAYLOAD_PWR_PIN, payloadPwrState ? HIGH : LOW);
            responsePayload[1] = payloadPwrState ? 1 : 0;
            Serial.print("[CMD] Payload Power: ");
            Serial.println(payloadPwrState ? "ON" : "OFF");
            break;
          case 1: // GPS
            gpsPwrState = !gpsPwrState;
            digitalWrite(GPS_PWR_PIN, gpsPwrState ? HIGH : LOW);
            responsePayload[1] = gpsPwrState ? 1 : 0;
            Serial.print("[CMD] GPS Power: ");
            Serial.println(gpsPwrState ? "ON" : "OFF");
            break;
          case 2: // Camera
            camPwrState = !camPwrState;
            digitalWrite(CAM_PWR_PIN, camPwrState ? HIGH : LOW);
            responsePayload[1] = camPwrState ? 1 : 0;
            Serial.print("[CMD] Camera Power: ");
            Serial.println(camPwrState ? "ON" : "OFF");
            break;
          default:
            sendPacket(CMD_NACK, nullptr, 0);
            return;
        }
        sendPacket(CMD_ACK, responsePayload, 2);
      } else {
        sendPacket(CMD_NACK, nullptr, 0);
      }
      break;
    }

    // --- LIST IMAGES ---
    case CMD_LIST_IMAGE: {
      Serial.println("[CMD] LIST_IMAGE");
      // Iterate SD root and collect .jpg filenames
      uint8_t listPayload[200];
      uint8_t listIndex = 0;

      File root = sd.open("/");
      if (root) {
        File entry;
        while (entry.openNext(&root, O_RDONLY)) {
          char name[32];
          entry.getName(name, sizeof(name));

          // Filter for .jpg files only
          size_t nameLen = strlen(name);
          if (nameLen > 4 &&
              (strcmp(&name[nameLen-4], ".jpg") == 0 || strcmp(&name[nameLen-4], ".JPG") == 0)) {

            // Format: [nameLen][name bytes][fileSize 4 bytes]
            uint8_t fnLen = (uint8_t)nameLen;
            uint32_t fileSize = entry.fileSize();

            if (listIndex + 1 + fnLen + 4 < sizeof(listPayload)) {
              listPayload[listIndex++] = fnLen;
              memcpy(&listPayload[listIndex], name, fnLen);
              listIndex += fnLen;
              listPayload[listIndex++] = (fileSize >> 24) & 0xFF;
              listPayload[listIndex++] = (fileSize >> 16) & 0xFF;
              listPayload[listIndex++] = (fileSize >> 8) & 0xFF;
              listPayload[listIndex++] = fileSize & 0xFF;
            }
          }
          entry.close();
        }
        root.close();
      }

      sendPacket(CMD_IMAGE_LIST, listPayload, listIndex);
      Serial.print("[CMD] Listed images, payload size: ");
      Serial.println(listIndex);
      break;
    }

    // --- REMOVE IMAGE ---
    case CMD_REMOVE_IMAGE: {
      if (payloadLen > 0 && payloadLen < 63) {
        char filename[64];
        memcpy(filename, payload, payloadLen);
        filename[payloadLen] = '\0';

        Serial.print("[CMD] REMOVE_IMAGE: ");
        Serial.println(filename);

        if (sd.exists(filename)) {
          sd.remove(filename);
          sendPacket(CMD_ACK, nullptr, 0);
          Serial.println("[CMD] File removed successfully");
        } else {
          sendPacket(CMD_NACK, nullptr, 0);
          Serial.println("[CMD] File not found");
        }
      } else {
        sendPacket(CMD_NACK, nullptr, 0);
      }
      break;
    }

    // --- REQUEST CHUNK (Resumable Download) ---
    case CMD_REQ_CHUNK: {
      if (payloadLen >= 2) {
        uint16_t chunkId = (payload[0] << 8) | payload[1];

        // If payload has a filename (payloadLen > 2), use it
        if (payloadLen > 2 && payloadLen < 66) {
          memcpy(downloadFilename, &payload[2], payloadLen - 2);
          downloadFilename[payloadLen - 2] = '\0';
        }

        Serial.print("[CMD] REQ_CHUNK #");
        Serial.print(chunkId);
        Serial.print(" from ");
        Serial.println(downloadFilename);

        File img;
        if (img.open(downloadFilename, O_RDONLY)) {
          uint32_t fileSize = img.fileSize();
          uint32_t offset = (uint32_t)chunkId * CHUNK_SIZE;

          if (offset >= fileSize) {
            // End of file - send empty chunk as EOT
            uint8_t eotData[4];
            eotData[0] = 0xFF;
            eotData[1] = 0xFF;
            eotData[2] = (fileSize >> 8) & 0xFF;
            eotData[3] = fileSize & 0xFF;
            img.close();
            sendPacket(CMD_IMAGE_DATA, eotData, 4);
            Serial.println("[CMD] EOT sent");
          } else {
            img.seek(offset);
            uint8_t chunkData[CHUNK_SIZE + 2];
            chunkData[0] = payload[0]; // Echo Chunk ID High
            chunkData[1] = payload[1]; // Echo Chunk ID Low
            int bytesRead = img.read(&chunkData[2], CHUNK_SIZE);
            img.close();
            sendPacket(CMD_IMAGE_DATA, chunkData, bytesRead + 2);
            Serial.print("[CMD] Chunk sent, bytes: ");
            Serial.println(bytesRead);
          }
        } else {
          sendPacket(CMD_NACK, nullptr, 0);
          Serial.println("[CMD] File not found for download");
        }
      }
      break;
    }

    default:
      Serial.print("[CMD] Unknown command: 0x");
      Serial.println(cmdType, HEX);
      sendPacket(CMD_NACK, nullptr, 0);
      break;
  }
}

// ====================================================================
// KISS DECODER & INCOMING DATA PROCESSOR
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
        // Validate minimum packet size and sync bytes
        if (rxIndex >= 8 && rxBuffer[0] == SYNC1 && rxBuffer[1] == SYNC2) {
          uint8_t cmdType = rxBuffer[2];
          uint8_t payloadLen = rxBuffer[3];

          // Validate packet length matches expected
          if (rxIndex == (size_t)(8 + payloadLen)) {
            uint32_t expectedCrc =
              ((uint32_t)rxBuffer[rxIndex-4] << 24) |
              ((uint32_t)rxBuffer[rxIndex-3] << 16) |
              ((uint32_t)rxBuffer[rxIndex-2] << 8)  |
              (uint32_t)rxBuffer[rxIndex-1];
            uint32_t calcCrc = calculateCRC32(rxBuffer, rxIndex - 4);

            if (expectedCrc == calcCrc) {
              lastAckTime = millis(); // Any valid packet = link alive
              handleCommand(cmdType, &rxBuffer[4], payloadLen);
            } else {
              Serial.println("[ERROR] CRC mismatch on incoming packet");
            }
          } else {
            Serial.print("[ERROR] Packet length mismatch. Expected ");
            Serial.print(8 + payloadLen);
            Serial.print(" got ");
            Serial.println(rxIndex);
          }
        }
        rxIndex = 0;
        inFrame = false;
        escapeNext = false;
      } else {
        inFrame = true;
        rxIndex = 0;
        escapeNext = false;
      }
    } else if (inFrame) {
      if (c == FESC) {
        escapeNext = true;
      } else if (escapeNext) {
        if (c == TFEND) rxBuffer[rxIndex++] = FEND;
        else if (c == TFESC) rxBuffer[rxIndex++] = FESC;
        escapeNext = false;
      } else {
        if (rxIndex < sizeof(rxBuffer)) {
          rxBuffer[rxIndex++] = c;
        } else {
          // Buffer overflow protection
          inFrame = false;
          rxIndex = 0;
          Serial.println("[ERROR] RX buffer overflow");
        }
      }
    }
  }
}

// ====================================================================
// SETUP
// ====================================================================
void setup() {
  // Debug Serial to PC
  Serial.setRx(PD9);
  Serial.setTx(PD8);
  Serial.begin(115200);
  delay(2000);

  Serial.println("\n=== FlatSat OBC: New Architecture ===");
  Serial.println("[SYSTEM] STM32F429ZI Initializing...");

  // UART to COMMU
  CommsUART.begin(115200);

  // I2C Bus (general sensors)
  Wire.begin();

  // EPS Sensor Bus (INA226 / TMP102 / ADM1177)
  initEPS();

  // Power MOSFET Pins
  pinMode(PAYLOAD_PWR_PIN, OUTPUT);
  pinMode(GPS_PWR_PIN, OUTPUT);
  pinMode(CAM_PWR_PIN, OUTPUT);
  digitalWrite(PAYLOAD_PWR_PIN, LOW);
  digitalWrite(GPS_PWR_PIN, LOW);
  digitalWrite(CAM_PWR_PIN, LOW);

  // SD Card (SPI3)
  Serial.print("[SYSTEM] Initializing SD Card... ");
  SD_SPI.begin();
  if (!sd.begin(SdSpiConfig(SD_CS, DEDICATED_SPI, SD_SCK_MHZ(10), &SD_SPI))) {
    systemErrors |= ERR_SD;
    Serial.println("FAILED!");
  } else {
    Serial.println("OK!");
  }

  // Hardware Watchdog
  IWatchdog.begin(WDT_TIMEOUT_US);
  Serial.println("[SYSTEM] Watchdog Timer armed (10s)");

  // Initial hardware check
  checkHardware();
  Serial.print("[SYSTEM] System Errors: 0x");
  Serial.println(systemErrors, HEX);
  Serial.println("[SYSTEM] OBC Ready. Entering main loop.");
}

// ====================================================================
// MAIN LOOP (Non-blocking)
// ====================================================================
void loop() {
  unsigned long currentMillis = millis();

  // 1. Dynamic Link Management
  if (currentMillis - lastAckTime > LINK_TIMEOUT) {
    beaconInterval = 10000; // Link lost -> slow beacon
  } else {
    beaconInterval = 1000;  // Link active -> fast beacon
  }

  // 2. Beacon Transmission
  if (currentMillis - lastBeaconTime >= beaconInterval) {
    sendBeacon();
    lastBeaconTime = currentMillis;
  }

  // 3. Process Incoming Commands from COMMU
  processIncomingUART();

  // 4. Service Watchdog
  IWatchdog.reload();
}
