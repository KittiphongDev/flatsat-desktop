#include "Lab3_TB_Read_EPS.h"

// Expected pin values (from solution)
#define EXPECTED_EPS_SDA    PF0
#define EXPECTED_EPS_SCL    PF1
#define EXPECTED_MAIN_SDA   PB9
#define EXPECTED_MAIN_SCL   PB8
#define EXPECTED_SERIAL_RX  PD9
#define EXPECTED_SERIAL_TX  PD8

// Expected I2C addresses (from solution)
static const uint8_t EXPECTED_SOLAR[4] = {0x40, 0x41, 0x42, 0x43};
static const uint8_t EXPECTED_BATT_CHG = 0x47;
static const uint8_t EXPECTED_BATT_DIS = 0x48;

// ---------------------------------------------------------
// Helper: check if an I2C device ACKs at the given address
// ---------------------------------------------------------
static bool i2cProbe(TwoWire &bus, uint8_t addr) {
  bus.beginTransmission(addr);
  return (bus.endTransmission() == 0);
}

// ---------------------------------------------------------
// Main testbench
// ---------------------------------------------------------
void runEPSTestbench(TwoWire &epsBus,
                     int epsSDA, int epsSCL,
                     int mainSDA, int mainSCL,
                     int serialRx, int serialTx,
                     const uint8_t solarAddrs[4],
                     uint8_t battChgAddr, uint8_t battDisAddr) {

  Serial.println("\n========================================");
  Serial.println("    LAB 3.1 VALIDATION TEST");
  Serial.println("========================================");

  bool allPassed = true;
  int testNum = 0;

  // --------------------------------------------------
  // TEST 1: EPS I2C bus pins (TODO 1)
  // --------------------------------------------------
  testNum++;
  Serial.println("\n[TEST " + String(testNum) + "] EPS I2C Bus Pins (TODO 1)");
  bool epsPinsOK = (epsSDA == EXPECTED_EPS_SDA) && (epsSCL == EXPECTED_EPS_SCL);
  if (epsPinsOK) {
    Serial.println(" " + String((char)0xE2) + String((char)0x9C) + String((char)0x85) + " [PASS] EPS bus: SDA=PF0, SCL=PF1");
  } else {
    Serial.println(" " + String((char)0xE2) + String((char)0x9D) + String((char)0x8C) + " [FAIL] EPS bus pins are incorrect.");
    Serial.println("     * Hint: Check the FlatSat schematic for the EPS I2C bus SDA/SCL pins.");
    allPassed = false;
  }

  // --------------------------------------------------
  // TEST 2: INA226 sensor addresses (TODO 2)
  // --------------------------------------------------
  testNum++;
  Serial.println("\n[TEST " + String(testNum) + "] INA226 Sensor Addresses (TODO 2)");
  bool addrsOK = true;

  // Check solar addresses
  for (int i = 0; i < 4; i++) {
    if (solarAddrs[i] != EXPECTED_SOLAR[i]) {
      Serial.println("     * SOLAR " + String(i + 1) + ": expected 0x" +
                     String(EXPECTED_SOLAR[i], HEX) + ", got 0x" +
                     String(solarAddrs[i], HEX));
      addrsOK = false;
    }
  }

  // Check battery addresses
  if (battChgAddr != EXPECTED_BATT_CHG) {
    Serial.println("     * BATT CHG: expected 0x" + String(EXPECTED_BATT_CHG, HEX) +
                   ", got 0x" + String(battChgAddr, HEX));
    addrsOK = false;
  }
  if (battDisAddr != EXPECTED_BATT_DIS) {
    Serial.println("     * BATT DIS: expected 0x" + String(EXPECTED_BATT_DIS, HEX) +
                   ", got 0x" + String(battDisAddr, HEX));
    addrsOK = false;
  }

  if (addrsOK) {
    Serial.println(" " + String((char)0xE2) + String((char)0x9C) + String((char)0x85) + " [PASS] All 6 INA226 addresses are correct.");
  } else {
    Serial.println(" " + String((char)0xE2) + String((char)0x9D) + String((char)0x8C) + " [FAIL] One or more INA226 addresses are wrong.");
    Serial.println("     * Hint: Use your Lab 1.2 I2C scanner on the EPS bus to discover addresses.");
    allPassed = false;
  }

  // --------------------------------------------------
  // TEST 3: Serial UART pins (TODO 3)
  // --------------------------------------------------
  testNum++;
  Serial.println("\n[TEST " + String(testNum) + "] Serial UART Pins (TODO 3)");
  bool uartOK = (serialRx == EXPECTED_SERIAL_RX) && (serialTx == EXPECTED_SERIAL_TX);
  if (uartOK) {
    Serial.println(" " + String((char)0xE2) + String((char)0x9C) + String((char)0x85) + " [PASS] Serial: RX=PD9, TX=PD8");
  } else {
    Serial.println(" " + String((char)0xE2) + String((char)0x9D) + String((char)0x8C) + " [FAIL] Serial UART pins are incorrect.");
    Serial.println("     * Hint: Check the OBC schematic for the debug UART RX/TX pins.");
    allPassed = false;
  }

  // --------------------------------------------------
  // TEST 4: Main I2C bus pins (TODO 4)
  // --------------------------------------------------
  testNum++;
  Serial.println("\n[TEST " + String(testNum) + "] Main I2C Bus Pins (TODO 4)");
  bool mainPinsOK = (mainSDA == EXPECTED_MAIN_SDA) && (mainSCL == EXPECTED_MAIN_SCL);
  if (mainPinsOK) {
    Serial.println(" " + String((char)0xE2) + String((char)0x9C) + String((char)0x85) + " [PASS] Main bus: SDA=PB9, SCL=PB8");
  } else {
    Serial.println(" " + String((char)0xE2) + String((char)0x9D) + String((char)0x8C) + " [FAIL] Main I2C bus pins are incorrect.");
    Serial.println("     * Hint: Check the FlatSat schematic for the Main bus SDA/SCL pins.");
    allPassed = false;
  }

  // --------------------------------------------------
  // TEST 5: I2C device connectivity (verifies TODO 4 & 5)
  // --------------------------------------------------
  testNum++;
  Serial.println("\n[TEST " + String(testNum) + "] I2C Device Connectivity (TODO 4 & 5)");
  bool connectOK = true;

  // Probe each solar sensor on EPS bus
  for (int i = 0; i < 4; i++) {
    if (!i2cProbe(epsBus, solarAddrs[i])) {
      Serial.println("     * SOLAR " + String(i + 1) + " (0x" +
                     String(solarAddrs[i], HEX) + "): no ACK on EPS bus");
      connectOK = false;
    }
  }

  // Probe battery sensors on EPS bus
  if (!i2cProbe(epsBus, battChgAddr)) {
    Serial.println("     * BATT CHG (0x" + String(battChgAddr, HEX) + "): no ACK on EPS bus");
    connectOK = false;
  }
  if (!i2cProbe(epsBus, battDisAddr)) {
    Serial.println("     * BATT DIS (0x" + String(battDisAddr, HEX) + "): no ACK on EPS bus");
    connectOK = false;
  }

  // Probe RTC on Main bus (address 0x51 for PCF85063TP)
  if (!i2cProbe(Wire, 0x51)) {
    Serial.println("     * RTC (0x51): no ACK on Main bus — check TODO 5");
    connectOK = false;
  }

  if (connectOK) {
    Serial.println(" " + String((char)0xE2) + String((char)0x9C) + String((char)0x85) + " [PASS] All 7 I2C devices responding.");
  } else {
    Serial.println(" " + String((char)0xE2) + String((char)0x9D) + String((char)0x8C) + " [FAIL] One or more I2C devices not responding.");
    Serial.println("     * Hint: Ensure I2C_EPS.begin() and Wire.begin() are called,");
    Serial.println("       and that rtc.begin() is present (TODO 5).");
    allPassed = false;
  }

  // --------------------------------------------------
  // Summary
  // --------------------------------------------------
  Serial.println("\n========================================");
  Serial.println("--- Test Summary ---");
  if (allPassed) {
    Serial.println(" " + String((char)0xE2) + String((char)0x9C) + String((char)0x85) + " VALIDATE PASS: All pins and addresses are correct!");
  } else {
    Serial.println(" " + String((char)0xE2) + String((char)0x9D) + String((char)0x8C) + " VALIDATE FAILED: Please fix the errors and try again.");
  }
  Serial.println("========================================\n");
}
