// NBSPACE Labs: FlatSat Learning Set
// Lab 3.1: OBC Read EPS Telemetry
// Solution Code

#include <Arduino.h>
#include <Wire.h>
#include <PCF85063TP.h>
#include "src/Lab3_TB_Read_EPS.h"

#define EPS_SDA PF0
#define EPS_SCL PF1
TwoWire I2C_EPS(EPS_SDA, EPS_SCL);
PCD85063TP rtc;

// --- INA226 sensor I2C addresses (6 channels) ---
const uint8_t SOLAR_ADDRS[4] = {0x40, 0x41, 0x42, 0x43}; // Solar panels 1–4
const uint8_t BATT_CHG_ADDR  = 0x47;                     // Battery charge path
const uint8_t BATT_DIS_ADDR  = 0x48;                     // Battery discharge path

#define INA226_REG_BUS_VOLTAGE 0x02
#define INA226_REG_CURRENT     0x04
#define INA226_REG_CALIBRATION 0x05

#define INA226_CAL_VALUE 5120 // 0.00512 / (0.1 mA LSB * 0.01 ohm Rsense)

// ---------------------------------------------------------
// INA226 sensor read/write helpers
// ---------------------------------------------------------

void setupINA226(uint8_t address) {
  I2C_EPS.beginTransmission(address);
  I2C_EPS.write(INA226_REG_CALIBRATION);
  I2C_EPS.write((INA226_CAL_VALUE >> 8) & 0xFF); 
  I2C_EPS.write(INA226_CAL_VALUE & 0xFF);        
  I2C_EPS.endTransmission();
}

float readVoltage(uint8_t address) {
  I2C_EPS.beginTransmission(address);
  I2C_EPS.write(INA226_REG_BUS_VOLTAGE);
  I2C_EPS.endTransmission();
  
  I2C_EPS.requestFrom((int)address, 2);
  if (I2C_EPS.available() == 2) {
    uint8_t msb = I2C_EPS.read();
    uint8_t lsb = I2C_EPS.read();
    int16_t raw = (msb << 8) | lsb;
    return raw * 0.00125; // LSB = 1.25 mV
  }
  return 0.0;
}

float readCurrent(uint8_t address) {
  I2C_EPS.beginTransmission(address);
  I2C_EPS.write(INA226_REG_CURRENT);
  I2C_EPS.endTransmission();
  
  I2C_EPS.requestFrom((int)address, 2);
  if (I2C_EPS.available() == 2) {
    uint8_t msb = I2C_EPS.read();
    uint8_t lsb = I2C_EPS.read();
    int16_t raw = (msb << 8) | lsb; 
    return raw * 0.1; // LSB = 0.1 mA (per calibration)
  }
  return 0.0;
}

// ---------------------------------------------------------
// Setup & Loop
// ---------------------------------------------------------

void setup() {
  #define SERIAL_RX_PIN PD9
  #define SERIAL_TX_PIN PD8
  Serial.setRx(SERIAL_RX_PIN);
  Serial.setTx(SERIAL_TX_PIN);
  Serial.begin(1000000);
  delay(4000); // Allow serial connection to stabilize

  I2C_EPS.begin();
  #define MAIN_SDA PB9
  #define MAIN_SCL PB8
  Wire.setSDA(MAIN_SDA);
  Wire.setSCL(MAIN_SCL);
  Wire.begin();
  
  rtc.begin();

  for (int i = 0; i < 4; i++) {
    setupINA226(SOLAR_ADDRS[i]);
  }
  
  setupINA226(BATT_CHG_ADDR);
  setupINA226(BATT_DIS_ADDR);

  // Run validation testbench
  runEPSTestbench(I2C_EPS,
                  EPS_SDA, EPS_SCL,
                  MAIN_SDA, MAIN_SCL,
                  SERIAL_RX_PIN, SERIAL_TX_PIN,
                  SOLAR_ADDRS, BATT_CHG_ADDR, BATT_DIS_ADDR);
}

void loop() {
  // 1. Read current time from RTC
  rtc.getTime();
  String hh = (rtc.hour < 10) ? "0" + String(rtc.hour) : String(rtc.hour);
  String mm = (rtc.minute < 10) ? "0" + String(rtc.minute) : String(rtc.minute);
  String ss = (rtc.second < 10) ? "0" + String(rtc.second) : String(rtc.second);
  String timeStamp = "[" + hh + ":" + mm + ":" + ss + "]";

  // 2. Build display output (ANSI clear + header)
  String displayData = "\033[2J\033[H";

  displayData += "=================================================\n";
  displayData += "       FLATSAT FULL EPS REAL-TIME DASHBOARD      \n";
  displayData += "=================================================\n";
  displayData += "  OBC MISSION TIME : " + timeStamp + "\n";
  displayData += "-------------------------------------------------\n";

  // 3. Read and display solar panel telemetry
  float totalSolarPower = 0.0;
  for (int i = 0; i < 4; i++) {
    float v = readVoltage(SOLAR_ADDRS[i]);
    float i_ma = readCurrent(SOLAR_ADDRS[i]);
    totalSolarPower += (v * i_ma); // Accumulate total solar power (mW)
    
    displayData += "  [SOLAR " + String(i + 1) + "] -> Voltage: " + String(v, 2) + 
                   " V  | Current: " + String(i_ma, 1) + " mA\n";
  }
  
  float chgV = readVoltage(BATT_CHG_ADDR);
  float chgI = readCurrent(BATT_CHG_ADDR);
  float disV = readVoltage(BATT_DIS_ADDR);
  float disI = readCurrent(BATT_DIS_ADDR);

  displayData += "-------------------------------------------------\n";
  displayData += "  [BATT CHG] -> Voltage: " + String(chgV, 2) + " V  | IN  : " + String(chgI, 1) + " mA\n";
  displayData += "  [BATT DIS] -> Voltage: " + String(disV, 2) + " V  | OUT : " + String(disI, 1) + " mA\n";
  displayData += "=================================================\n";
  displayData += "  TOTAL SOLAR POWER IN: " + String(totalSolarPower, 1) + " mW\n";

  Serial.print(displayData);

  delay(500); // Refresh interval
}