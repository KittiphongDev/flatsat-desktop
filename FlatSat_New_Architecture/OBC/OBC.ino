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
#include <TinyGPS++.h>   // GPS NMEA parsing (same library as the FlatSat labs)
#include "Arducam_Mega.h" // Camera payload (same library as Lab 5)

// ====================================================================
// CAMERA BUILD MODE
//   PROTOTYPE  = FlatSat prototype board: the camera is always powered
//                (PD4 is not used to switch it). You cannot turn it on/off,
//                but you CAN take pictures.
//   PRODUCTION = flight-style: the camera is powered through PD4 and exposed
//                as a switchable output (toggle subsystem 3).
// Change this ONE line and reflash to switch builds. The dashboard has a
// matching Prototype/Production setting — keep the two in sync.
// ====================================================================
#define CAMERA_MODE_PROTOTYPE  0
#define CAMERA_MODE_PRODUCTION 1
#ifndef CAMERA_MODE
#define CAMERA_MODE CAMERA_MODE_PROTOTYPE
#endif

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
// EPS controllable power outputs (ADM1177 hot-swap channels).
// The OBC drives the channel enable lines on pins PD1/PD2/PD3.
// (Output 1 = OBC itself and cannot be switched off.)
#define PAYLOAD_PWR_PIN PD1   // Output 2: Communication power   (ADM1177 0x59)
#define GPS_PWR_PIN     PD2   // Output 3: Payload 1 / GPS power (ADM1177 0x5A)
#define CAM_PWR_PIN     PD3   // Output 4: Payload 2 / PC104     (ADM1177 0x5B)

// --- EPS SENSOR BUS (I2C2 - Dedicated to EPS sensors) ---
#define EPS_SDA PF0
#define EPS_SCL PF1

// --- GPS MODULE UART (matches Lab 5) ---
#define GPS_RX PE0
#define GPS_TX PE1

// --- Camera Payload (Arducam Mega) ---
// Power on PD4 is a *separate* GPIO from the ADM1177 outputs (PD1/PD2/PD3);
// it only does something in the PRODUCTION build. The camera has its own SPI
// bus (PB3/PB4/PB5), independent of the SD card's dedicated SPI3.
#define ARDUCAM_PWR_PIN PD4   // production camera power switch
#define ARDUCAM_CS      PE7   // camera SPI chip-select
#define ARDUCAM_MISO    PB4
#define ARDUCAM_MOSI    PB5
#define ARDUCAM_SCK     PB3

// --- Hardware Instances ---
SPIClass SD_SPI(SD_MOSI, SD_MISO, SD_SCK);
SdFat sd;
HardwareSerial CommsUART(PA1, PA0); // UART to COMMU module
HardwareSerial GpsUART(GPS_RX, GPS_TX); // NMEA stream from the GPS module
TinyGPSPlus gps;
Arducam_Mega myCAM(ARDUCAM_CS);

// --- STM32 Arducam HAL shim (same fix as Lab 5) ---
// The Arducam C-core has no STM32 definition for the CS pin, so we bridge its
// hooks to standard Arduino GPIO calls.
extern "C" {
  void arducamCsOutputMode() { pinMode(ARDUCAM_CS, OUTPUT); }
  void arducamSpiCsPinLow()  { digitalWrite(ARDUCAM_CS, LOW); }
  void arducamSpiCsPinHigh() { digitalWrite(ARDUCAM_CS, HIGH); }
}

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
  CMD_EPS_DATA     = 0x10, // OBC -> GS: full EPS telemetry dump
  CMD_HEALTH_DATA  = 0x11  // OBC -> GS: I2C device health scan result
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
// The COMMS->GS radio link carries at most 64 bytes per frame. Each frame is
// AX.25(16) + packet header/CRC(8) + radio CRC(2) = 26 bytes of overhead, so
// keep the data per chunk <= ~36 bytes.
#define CHUNK_SIZE 32       // image download data per chunk
#define EPS_CHUNK_SIZE 32   // EPS telemetry data per chunk
#define WDT_TIMEOUT_US 10000000 // 10 seconds

// --- Camera ---
#define CAM_BUF_SIZE 256          // SD write buffer during capture (matches Lab 5)
#define CAM_BOOT_DELAY_MS 2000    // sensor boot + auto-exposure settle

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
// Channels boot powered ON (HIGH) so the radio link and payloads are live.
// Index mapping: payload=Communication(PD1), gps=Payload1/GPS(PD2), cam=Payload2/PC104(PD3)
bool payloadPwrState = true;
bool gpsPwrState = true;
bool camPwrState = true;

// --- Camera payload (Arducam on PD4) ---
// NOTE: this is the real camera, distinct from camPwrState above (which is the
// ADM1177 "Payload 2 / PC104" rail on PD3). In PROTOTYPE the camera is always
// powered; in PRODUCTION it is switched via PD4 (toggle subsystem 3).
bool cameraPwrState = (CAMERA_MODE == CAMERA_MODE_PROTOTYPE); // PD4 state
bool camReady = false;                                        // myCAM.begin() done

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

  // GPS: flag when there is no valid fix, so the dashboard's error string can
  // actually light up (R7). ERR_CAM is reserved for a real camera fault.
  if (!gps.location.isValid()) systemErrors |= ERR_GPS;
}

// ====================================================================
// IMAGE COUNTER — resume numbering past the highest img_NNNN.jpg on the SD
// card so a reboot doesn't overwrite existing captures (D15).
// ====================================================================
void scanImageCounter() {
  uint32_t maxNext = 0;
  File root = sd.open("/");
  if (root) {
    File entry;
    while (entry.openNext(&root, O_RDONLY)) {
      char name[32];
      entry.getName(name, sizeof(name));
      unsigned long n = 0;
      if (sscanf(name, "img_%lu.jpg", &n) == 1) {
        if (n + 1 > maxNext) maxNext = n + 1;
      }
      entry.close();
    }
    root.close();
  }
  imageCounter = maxNext;
  Serial.print("[SD] Image counter resumed at ");
  Serial.println(imageCounter);
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

  if (enqueueChunked(CMD_EPS_DATA, payload, idx)) {
    Serial.print("[EPS] Telemetry queued, ");
    Serial.print(idx);
    Serial.println(" bytes");
  } else {
    sendPacket(CMD_NACK, nullptr, 0);   // queue full -> dashboard shows "busy"
    Serial.println("[EPS] TX queue full - NACK");
  }
}

// ====================================================================
// GENERIC CHUNKED SENDER
// The COMMS->GS radio carries at most 64 bytes/frame, so responses larger
// than that are split into small frames: [chunkIdx][totalChunks][data...].
// Each chunk is sent twice (back-to-back) so a single dropped frame doesn't
// lose the transfer; the PC bridge de-duplicates by chunk index.
// ====================================================================
// A delay that keeps the GPS NMEA parser fed and the watchdog happy, so the
// paced chunked sends don't starve the GPS (D10). Blocking is retained (a
// second command safely waits in the UART RX buffer), avoiding the R1
// dropped-command regression of a full non-blocking rewrite.
void pacedDelay(uint16_t ms) {
  uint32_t end = millis() + ms;
  while ((int32_t)(end - millis()) > 0) {
    while (GpsUART.available()) gps.encode(GpsUART.read());
    IWatchdog.reload();
  }
}

// ---- TX JOB QUEUE ------------------------------------------------
// Chunked responses (EPS / health / image list) are queued and serviced ONE
// AT A TIME from loop(), non-blocking. This guarantees ordering (a job runs
// to completion before the next starts), never drops a command that arrives
// mid-transfer (it queues; NACK only when the queue is truly full), and lets
// loop() keep listening to the uplink between chunks.
struct ChunkJob {
  uint8_t  cmdType;
  uint8_t  blob[220];
  uint16_t blobLen;
};
#define JOB_QUEUE_SIZE 4
ChunkJob jobQueue[JOB_QUEUE_SIZE];
uint8_t jobHead = 0, jobTail = 0;     // head = job being / next to be serviced

// Active-transfer state machine
bool          txActive = false;
uint8_t       txChunk = 0, txTotal = 1, txCopy = 0;
unsigned long txNextAt = 0;
#define TX_COPIES        2
#define TX_CHUNK_GAP_MS  90

// Beacon arbitration: hold beacons off while a transfer is running/pending and
// for a short window after any command activity, so the half-duplex radio link
// isn't stomped by a beacon mid-conversation.
unsigned long lastActivityTime = 0;
#define BEACON_HOLDOFF_MS 2000

bool txBusy() { return txActive || jobHead != jobTail; }

bool enqueueChunked(uint8_t cmdType, const uint8_t *blob, uint16_t blobLen) {
  if (blobLen > sizeof(jobQueue[0].blob)) blobLen = sizeof(jobQueue[0].blob);
  uint8_t next = (uint8_t)((jobTail + 1) % JOB_QUEUE_SIZE);
  if (next == jobHead) return false;  // full -> caller NACKs ("busy")
  jobQueue[jobTail].cmdType = cmdType;
  memcpy(jobQueue[jobTail].blob, blob, blobLen);
  jobQueue[jobTail].blobLen = blobLen;
  jobTail = next;
  return true;
}

// Called every loop() pass. Emits at most one chunk copy per call, paced by
// TX_CHUNK_GAP_MS — byte-for-byte the same stream as the old blocking sender.
void serviceChunkedTx() {
  if (!txActive) {
    if (jobHead == jobTail) return;   // nothing pending
    ChunkJob &j = jobQueue[jobHead];
    txTotal = (uint8_t)((j.blobLen + EPS_CHUNK_SIZE - 1) / EPS_CHUNK_SIZE);
    if (txTotal == 0) txTotal = 1;
    txChunk = 0;
    txCopy = 0;
    txActive = true;
    txNextAt = millis();              // first chunk goes out immediately
  }
  if ((int32_t)(millis() - txNextAt) < 0) return;

  ChunkJob &j = jobQueue[jobHead];
  uint16_t off = (uint16_t)txChunk * EPS_CHUNK_SIZE;
  uint8_t len = (j.blobLen - off > EPS_CHUNK_SIZE) ? EPS_CHUNK_SIZE
                                                   : (uint8_t)(j.blobLen - off);
  uint8_t part[EPS_CHUNK_SIZE + 2];
  part[0] = txChunk;
  part[1] = txTotal;
  memcpy(&part[2], &j.blob[off], len);
  sendPacket(j.cmdType, part, len + 2);
  txNextAt = millis() + TX_CHUNK_GAP_MS;
  lastActivityTime = millis();

  if (++txCopy >= TX_COPIES) {        // both copies of this chunk sent
    txCopy = 0;
    if (++txChunk >= txTotal) {       // job complete -> pop, next job follows
      txActive = false;
      jobHead = (uint8_t)((jobHead + 1) % JOB_QUEUE_SIZE);
    }
  }
}

// ====================================================================
// DEVICE HEALTH SCAN (STATUS command)
// Probes each known EPS sensor/controller on the EPS I2C bus and reports
// which are online. Payload: [count] then count x [addr][online?1:0].
// ====================================================================
void sendDeviceHealth() {
  // Known devices from the FlatSat EPS documentation.
  static const uint8_t addrs[] = {
    0x40, 0x41, 0x42, 0x43, 0x47, 0x48, // INA226 (solar x4, batt charge/discharge)
    0x4A, 0x4B,                         // TMP102 (battery temps)
    0x58, 0x59, 0x5A, 0x5B              // ADM1177 (power outputs)
  };
  const uint8_t n = sizeof(addrs);

  uint8_t payload[1 + 2 * sizeof(addrs)];
  uint8_t idx = 0;
  payload[idx++] = n;
  for (uint8_t i = 0; i < n; i++) {
    EPS_SEN.beginTransmission(addrs[i]);
    uint8_t online = (EPS_SEN.endTransmission() == 0) ? 1 : 0;
    payload[idx++] = addrs[i];
    payload[idx++] = online;
    IWatchdog.reload();
  }

  if (enqueueChunked(CMD_HEALTH_DATA, payload, idx)) {
    Serial.print("[HEALTH] Device scan queued, ");
    Serial.print(n);
    Serial.println(" devices");
  } else {
    sendPacket(CMD_NACK, nullptr, 0);
    Serial.println("[HEALTH] TX queue full - NACK");
  }
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

  // Real telemetry from the EPS. Battery is a 1S Li-ion (3.0 V empty →
  // 4.2 V full), read from the discharge rail monitor (index 5 = 0x48).
  float battV = powerMonitors[5].getBusVoltage_V();
  int pct = (int)((battV - 3.0f) / 1.2f * 100.0f); // 1S Li-ion state of charge
  pct = constrain(pct, 0, 100);
  float obcTemp = tempSensors[0].readTemperatureC();

  uint8_t beaconData[8];
  beaconData[0] = systemErrors;                  // Error bitmask
  beaconData[1] = payloadPwrState ? 1 : 0;       // Communication power (PD1)
  beaconData[2] = gpsPwrState ? 1 : 0;           // Payload 1 / GPS power (PD2)
  beaconData[3] = camPwrState ? 1 : 0;           // Payload 2 / PC104 power (PD3)
  beaconData[4] = (uint8_t)pct;                  // Battery state of charge (%)
  beaconData[5] = (uint8_t)constrain((int)obcTemp, 0, 255);   // Battery temp (°C)
  beaconData[6] = (uint8_t)constrain((int)(battV + 0.5f), 0, 255); // Batt V (whole volts)
  beaconData[7] = (millis() - lastAckTime < LINK_TIMEOUT) ? 1 : 0; // Link status

  sendPacket(CMD_BEACON, beaconData, 8);
  Serial.print("[BEACON] Bat=");
  Serial.print(pct);
  Serial.print("% V=");
  Serial.print(battV, 2);
  Serial.print(" T=");
  Serial.println(obcTemp, 1);
}

// ====================================================================
// CAMERA CAPTURE  (Arducam Mega -> JPEG on SD)
// Ported from Lab 5's capture routine: take a VGA JPEG, stream it out of the
// camera FIFO, and write everything between the JPEG SOI (FF D8) and EOI
// (FF D9) markers to the SD card. Feeds the watchdog while streaming.
//
// Auto-power is handled by the DASHBOARD (it toggles the camera on and waits
// before sending TAKE_PIC), so this routine assumes the camera is already
// powered and initialised. In PRODUCTION it refuses if the camera isn't ready.
// Returns true on success and ACKs with the filename; NACKs on failure.
// ====================================================================
bool captureAndSaveImage() {
#if CAMERA_MODE == CAMERA_MODE_PRODUCTION
  if (!camReady) {
    Serial.println("[CAM] Capture refused: camera not powered/ready");
    sendPacket(CMD_NACK, nullptr, 0);
    return false;
  }
#endif

  char filename[32];
  snprintf(filename, sizeof(filename), "img_%04lu.jpg", imageCounter);

  File imgFile;
  if (!imgFile.open(filename, O_WRONLY | O_CREAT | O_TRUNC)) {
    Serial.println("[CAM] SD open failed");
    sendPacket(CMD_NACK, nullptr, 0);
    return false;
  }

  Serial.print("[CAM] Capturing ");
  Serial.print(filename);
  Serial.print(" ... ");
  myCAM.takePicture(CAM_IMAGE_MODE_VGA, CAM_IMAGE_PIX_FMT_JPG);

  uint8_t  buf[CAM_BUF_SIZE];
  uint16_t buffIndex = 0;
  uint8_t  prevByte = 0;
  uint8_t  curByte = 0;
  uint8_t  headFlag = 0;       // 1 once the JPEG SOI has been seen
  uint32_t byteCount = 0;
  bool     gotEnd = false;

  while (myCAM.getReceivedLength()) {
    prevByte = curByte;
    curByte = myCAM.readByte();

    // Once inside the image, buffer every byte and flush in blocks.
    if (headFlag == 1) {
      buf[buffIndex++] = curByte;
      if (buffIndex >= CAM_BUF_SIZE) {
        imgFile.write(buf, buffIndex);
        buffIndex = 0;
      }
    }

    // JPEG start of image (FF D8): open the stream, keep both marker bytes.
    if (headFlag == 0 && prevByte == 0xFF && curByte == 0xD8) {
      headFlag = 1;
      buf[buffIndex++] = 0xFF;
      buf[buffIndex++] = 0xD8;
    }

    // JPEG end of image (FF D9): flush and stop.
    if (headFlag == 1 && prevByte == 0xFF && curByte == 0xD9) {
      imgFile.write(buf, buffIndex);
      buffIndex = 0;
      gotEnd = true;
      break;
    }

    // Keep the hardware watchdog happy during the long SPI read.
    if ((++byteCount & 0x3FF) == 0) IWatchdog.reload();
  }

  imgFile.close();

  if (!gotEnd) {
    Serial.println("no EOI (bad capture)");
    sd.remove(filename);           // drop the truncated file
    sendPacket(CMD_NACK, nullptr, 0);
    return false;
  }

  imageCounter++;
  Serial.println("saved");

  // ACK carrying the filename so the dashboard can list/download it.
  uint8_t ackPayload[32];
  uint8_t fnLen = strlen(filename);
  memcpy(ackPayload, filename, fnLen);
  sendPacket(CMD_ACK, ackPayload, fnLen);
  return true;
}

// ====================================================================
// COMMAND HANDLER (Full Implementation)
// ====================================================================
void handleCommand(uint8_t cmdType, uint8_t *payload, uint8_t payloadLen) {
  Serial.print("[RX] CMD 0x");
  Serial.println(cmdType, HEX);
  lastActivityTime = millis();  // hold beacons off while we're in a conversation

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

    // --- STATUS (Scan I2C devices and report health) ---
    case CMD_STATUS:
      sendDeviceHealth();
      Serial.println("[CMD] STATUS -> Device health sent");
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
      // Real Arducam capture. In PRODUCTION the dashboard powers the camera on
      // (toggle subsystem 3) and waits before sending this, so the camera is
      // expected to be ready; captureAndSaveImage() NACKs if it isn't.
      captureAndSaveImage();
      break;
    }

    // --- GET GPS ---
    case CMD_GET_GPS: {
      Serial.println("[CMD] GET_GPS");
      // Read the real GPS module (parsed from the NMEA stream via TinyGPS++).
      // When there is no fix yet, fixValid = 0 and satellites = 0 so the app
      // can show "NO SIGNAL" even though the link itself is working fine.
      float lat = 0.0f, lon = 0.0f, alt = 0.0f;
      uint8_t satCount = 0;
      uint8_t fixValid = 0;

      if (gps.location.isValid()) {
        lat = gps.location.lat();
        lon = gps.location.lng();
        fixValid = 1;
      }
      if (gps.altitude.isValid()) alt = gps.altitude.meters();
      if (gps.satellites.isValid()) satCount = (uint8_t)gps.satellites.value();

      uint8_t gpsData[16];
      memcpy(&gpsData[0], &lat, 4);
      memcpy(&gpsData[4], &lon, 4);
      memcpy(&gpsData[8], &alt, 4);
      gpsData[12] = satCount;
      gpsData[13] = fixValid; // 0 = no signal/fix, 1 = valid fix

      // Send the reply a few times so a single dropped frame over the radio
      // doesn't lose the whole response.
      for (uint8_t r = 0; r < 3; r++) {
        sendPacket(CMD_GPS_DATA, gpsData, 14);
        pacedDelay(80);
      }
      Serial.print("[CMD] GPS data sent (x3), fix=");
      Serial.println(fixValid);
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
          case 2: // Payload 2 / PC104 (ADM1177 0x5B, PD3)
            camPwrState = !camPwrState;
            digitalWrite(CAM_PWR_PIN, camPwrState ? HIGH : LOW);
            responsePayload[1] = camPwrState ? 1 : 0;
            Serial.print("[CMD] Payload2/PC104 Power: ");
            Serial.println(camPwrState ? "ON" : "OFF");
            break;
          case 3: // Camera payload (Arducam on PD4) — PRODUCTION only
#if CAMERA_MODE == CAMERA_MODE_PRODUCTION
            cameraPwrState = !cameraPwrState;
            digitalWrite(ARDUCAM_PWR_PIN, cameraPwrState ? HIGH : LOW);
            if (cameraPwrState) {
              // Give the sensor time to boot, then bring the camera up. Feed
              // the watchdog around the blocking begin().
              delay(CAM_BOOT_DELAY_MS);
              IWatchdog.reload();
              myCAM.begin();
              camReady = true;
              Serial.println("[CMD] Camera Power: ON (ready)");
            } else {
              camReady = false;
              Serial.println("[CMD] Camera Power: OFF");
            }
            responsePayload[1] = cameraPwrState ? 1 : 0;
            break;
#else
            // Prototype: the camera can't be switched.
            Serial.println("[CMD] Camera toggle ignored (prototype build)");
            sendPacket(CMD_NACK, nullptr, 0);
            return;
#endif
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

      // The list can exceed one 64-byte radio frame, so send it chunked
      // (works for 0 images too — the bridge reassembles an empty list).
      if (enqueueChunked(CMD_IMAGE_LIST, listPayload, listIndex)) {
        Serial.print("[CMD] Image list queued, payload size: ");
        Serial.println(listIndex);
      } else {
        sendPacket(CMD_NACK, nullptr, 0);
        Serial.println("[CMD] TX queue full - NACK");
      }
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

        // If payload has a filename (payloadLen > 2), use it. Guard the length
        // so the uplink frame stays within the 64-byte radio limit (D13):
        // 2 (chunk id) + name(<=30) + 8 (packet) + 16 (AX.25) = <=56 on air.
        uint8_t nameLen = (payloadLen >= 2) ? (payloadLen - 2) : 0;
        if (nameLen > 30) {
          Serial.println("[CMD] REQ_CHUNK filename too long — NACK");
          sendPacket(CMD_NACK, nullptr, 0);
          break;
        }
        if (nameLen > 0) {
          memcpy(downloadFilename, &payload[2], nameLen);
          downloadFilename[nameLen] = '\0';
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

  // GPS module UART (NMEA @ 9600, standard for most GPS receivers)
  GpsUART.begin(9600);

  // I2C Bus (general sensors)
  Wire.begin();

  // EPS Sensor Bus (INA226 / TMP102 / ADM1177)
  initEPS();

  // EPS power-channel enable pins (PD1/PD2/PD3). Boot HIGH = powered ON,
  // matching the FlatSat power-control reference, so the COMMS link stays up.
  pinMode(PAYLOAD_PWR_PIN, OUTPUT);
  pinMode(GPS_PWR_PIN, OUTPUT);
  pinMode(CAM_PWR_PIN, OUTPUT);
  digitalWrite(PAYLOAD_PWR_PIN, payloadPwrState ? HIGH : LOW);
  digitalWrite(GPS_PWR_PIN, gpsPwrState ? HIGH : LOW);
  digitalWrite(CAM_PWR_PIN, camPwrState ? HIGH : LOW);

  // Camera payload (Arducam Mega) on its own SPI bus (PB3/PB4/PB5).
  pinMode(ARDUCAM_PWR_PIN, OUTPUT);
#if CAMERA_MODE == CAMERA_MODE_PROTOTYPE
  digitalWrite(ARDUCAM_PWR_PIN, HIGH);   // harmless if PD4 is unused; camera is always powered
#else
  digitalWrite(ARDUCAM_PWR_PIN, LOW);    // production: powered on demand via toggle subsystem 3
#endif
  SPI.setMISO(ARDUCAM_MISO);
  SPI.setMOSI(ARDUCAM_MOSI);
  SPI.setSCLK(ARDUCAM_SCK);
  SPI.begin();
#if CAMERA_MODE == CAMERA_MODE_PROTOTYPE
  delay(500);
  myCAM.begin();
  camReady = true;
  Serial.println("[CAM] Prototype build: camera powered and ready");
#else
  Serial.println("[CAM] Production build: camera OFF (toggle subsystem 3 to power)");
#endif

  // SD Card (SPI3)
  Serial.print("[SYSTEM] Initializing SD Card... ");
  SD_SPI.begin();
  if (!sd.begin(SdSpiConfig(SD_CS, DEDICATED_SPI, SD_SCK_MHZ(10), &SD_SPI))) {
    systemErrors |= ERR_SD;
    Serial.println("FAILED!");
  } else {
    Serial.println("OK!");
    scanImageCounter(); // continue numbering past existing images (D15)
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

  // 2. Beacon Transmission — but NEVER while a chunked transfer is running or
  // queued, nor right after command activity: the radio link is half-duplex,
  // so a beacon mid-conversation collides with responses and re-requests.
  // The beacon simply waits; it is sent as soon as the link goes quiet.
  if (currentMillis - lastBeaconTime >= beaconInterval &&
      !txBusy() &&
      currentMillis - lastActivityTime >= BEACON_HOLDOFF_MS) {
    sendBeacon();
    lastBeaconTime = currentMillis;
  }

  // 3. Feed the GPS parser with any NMEA bytes from the module
  while (GpsUART.available()) {
    gps.encode(GpsUART.read());
  }

  // 4. Process Incoming Commands from COMMU
  processIncomingUART();

  // 4b. Drive the chunked-TX job queue (one chunk per pass, 90 ms pacing).
  serviceChunkedTx();

  // 5. Service Watchdog
  IWatchdog.reload();
}
