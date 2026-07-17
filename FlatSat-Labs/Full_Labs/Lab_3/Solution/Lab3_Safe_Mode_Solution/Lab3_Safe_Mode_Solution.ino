// NBSPACE Labs: FlatSat Learning Set
// Lab 3.3: OBC Safe Mode
// Solution Code

#include <Arduino.h>
#include <Wire.h>
#include <PCF85063TP.h>
#include "src/Lab3_TB_Safe_Mode.h"

TwoWire I2C_EPS(PF0, PF1);
PCD85063TP rtc;

// --- I2C Addresses ---
#define TMP102_ADDRESS         0x49  // OBC Board Temperature sensor (via Wire)
#define BATT1_TMP102_ADDRESS   0x4A  // Battery 1 Temperature sensor (via I2C_EPS)
#define BATT2_TMP102_ADDRESS   0x4B  // Battery 2 Temperature sensor (via I2C_EPS)

#define INA226_ADDRESS         0x48  // Sensor 6: Battery Discharging Monitor (via I2C_EPS)
#define INA226_REG_BUS_VOLTAGE 0x02

// --- Hardware Power Control Pins ---  
#define PIN_COMMS      PD1
#define PIN_PAYLOAD_1  PD2
#define PIN_PAYLOAD_2  PD3

// --- Safe Mode Thresholds (pre-defined, do not modify) ---
const float SAFE_MODE_THRESHOLD = 3.36; // Enter safe mode below 30% (~3.36V)
const float RECOVERY_THRESHOLD  = 3.84; // Exit safe mode above 70% (~3.84V)

bool safeModeTriggered = false;

void setup() {
  Serial.setRx(PD9);
  Serial.setTx(PD8);
  Serial.begin(115200);
  delay(4000);

  Serial.println("\n=== FlatSat Safe Mode Controller Booting ===");

  // Initialize Power Control Pins
  pinMode(PIN_COMMS, OUTPUT);
  pinMode(PIN_PAYLOAD_1, OUTPUT);
  pinMode(PIN_PAYLOAD_2, OUTPUT);

  // Initialize payloads to ON (HIGH)
  digitalWrite(PIN_COMMS, HIGH);
  digitalWrite(PIN_PAYLOAD_1, HIGH);
  digitalWrite(PIN_PAYLOAD_2, HIGH);

  // Initialize Buses
  I2C_EPS.begin();     // EPS I2C on PF0/PF1
  Wire.setSDA(PB9);    // Main I2C on PB9/PB8
  Wire.setSCL(PB8);
  Wire.begin();
  rtc.begin();

  Serial.println("All subsystems initialized. Monitoring power and thermals...");
}

void loop() {
  // Read bus voltage from INA226 via EPS Bus
  float busVoltage = 0.0;
  I2C_EPS.beginTransmission(INA226_ADDRESS);
  I2C_EPS.write(INA226_REG_BUS_VOLTAGE);
  I2C_EPS.endTransmission();
  I2C_EPS.requestFrom(INA226_ADDRESS, 2);
  
  if (I2C_EPS.available() == 2) {
    byte msb = I2C_EPS.read();
    byte lsb = I2C_EPS.read();
    int raw = (msb << 8) | lsb;
    busVoltage = (raw >> 3) * 0.004; // LSB = 4 mV, right-shift 3 bits
  }

  // Read board temperature from TMP102 via Main Wire Bus
  float boardTemp = 0.0;
  Wire.requestFrom(TMP102_ADDRESS, 2); 
  if (Wire.available() == 2) {
    byte msb = Wire.read();
    byte lsb = Wire.read();
    int tempRaw = ((msb << 8) | lsb) >> 4;
    boardTemp = tempRaw * 0.0625; // LSB = 0.0625°C
  }

  // Read Battery 1 temperature from TMP102 via EPS Bus
  float batt1Temp = 0.0;
  I2C_EPS.requestFrom(BATT1_TMP102_ADDRESS, 2); 
  if (I2C_EPS.available() == 2) {
    byte msb = I2C_EPS.read();
    byte lsb = I2C_EPS.read();
    int tempRaw = ((msb << 8) | lsb) >> 4;
    batt1Temp = tempRaw * 0.0625;
  }

  // Read Battery 2 temperature from TMP102 via EPS Bus
  float batt2Temp = 0.0;
  I2C_EPS.requestFrom(BATT2_TMP102_ADDRESS, 2); 
  if (I2C_EPS.available() == 2) {
    byte msb = I2C_EPS.read();
    byte lsb = I2C_EPS.read();
    int tempRaw = ((msb << 8) | lsb) >> 4;
    batt2Temp = tempRaw * 0.0625;
  }

  // Build RTC timestamp
  rtc.getTime();
  String timestamp = "";
  timestamp += (rtc.hour < 10)   ? "0" + String(rtc.hour)   : String(rtc.hour);
  timestamp += ":";
  timestamp += (rtc.minute < 10) ? "0" + String(rtc.minute) : String(rtc.minute);
  timestamp += ":";
  timestamp += (rtc.second < 10) ? "0" + String(rtc.second) : String(rtc.second);

  // Safe mode decision logic with hysteresis
  if (busVoltage > 0 && busVoltage < SAFE_MODE_THRESHOLD) {
    // LOW VOLTAGE — Enter Safe Mode
    if (!safeModeTriggered) {
      Serial.println("LOW VOLTAGE! Entering Safe Mode...");
      shutdownAllChannels();
      safeModeTriggered = true;
    }
  } else if (safeModeTriggered && busVoltage >= RECOVERY_THRESHOLD) {
    // VOLTAGE RECOVERED — Exit Safe Mode
    Serial.println("Voltage recovered! Exiting Safe Mode...");
    digitalWrite(PIN_COMMS, HIGH);
    digitalWrite(PIN_PAYLOAD_1, HIGH);
    digitalWrite(PIN_PAYLOAD_2, HIGH);
    safeModeTriggered = false;
    Serial.println("All payloads restored to ACTIVE.");
  } else {
    // NOMINAL
    Serial.print("[" + timestamp + "] NOMINAL | ");
    Serial.print("V:" + String(busVoltage, 2) + "V | ");
    Serial.print("OBC_T:" + String(boardTemp, 2) + "C | ");
    Serial.print("B1_T:" + String(batt1Temp, 2) + "C | ");
    Serial.println("B2_T:" + String(batt2Temp, 2) + "C");
  }

  // Run external testbench validations
  runSafeModeTestbench(busVoltage, boardTemp, safeModeTriggered);

  delay(3000); // Monitoring interval
}

// Disable all non-essential power channels via direct GPIO control
void shutdownAllChannels() {
  digitalWrite(PIN_PAYLOAD_1, LOW);
  digitalWrite(PIN_PAYLOAD_2, LOW);
  digitalWrite(PIN_COMMS, LOW);

  Serial.println("All non-essential loads DISABLED via GPIO.");
}