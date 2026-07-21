// ==============================================================================
// FILE: eps_sensors.cpp
// DESCRIPTION: EPS Sensor Driver — INA226, TMP102, ADM1177 over I2C
// ==============================================================================

#include <Wire.h>
#include <stdint.h>

// ==============================================================================
// SECTION 1: BASE CLASS — Generic I2C Device
// ==============================================================================

class I2CDevice {
protected:
    TwoWire& wire;
    uint8_t  address;

public:
    I2CDevice(TwoWire& wireInstance, uint8_t addr)
        : wire(wireInstance), address(addr) {}

    // ---- Write ---------------------------------------------------------------

    void writeRegister16(uint8_t reg, uint16_t value) {
        wire.beginTransmission(address);
        wire.write(reg);
        wire.write((value >> 8) & 0xFF); // MSB
        wire.write( value       & 0xFF); // LSB
        wire.endTransmission();
    }

    void writeRegister8(uint8_t reg, uint8_t value) {
        wire.beginTransmission(address);
        wire.write(reg);
        wire.write(value);
        wire.endTransmission();
    }

    void writePointer(uint8_t reg) {
        wire.beginTransmission(address);
        wire.write(reg);
        wire.endTransmission();
    }

    // ---- Read ----------------------------------------------------------------

    uint16_t readRegister16(uint8_t reg) {
        wire.beginTransmission(address);
        wire.write(reg);
        wire.endTransmission(false);        // Repeated START
        wire.requestFrom(address, (uint8_t)2);
        if (wire.available() >= 2) {
            uint16_t value = (uint16_t)wire.read() << 8; // MSB
            value |= wire.read();                        // LSB
            return value;
        }
        return 0;
    }

    uint16_t readRegister16LE(uint8_t reg) {
        wire.beginTransmission(address);
        wire.write(reg);
        wire.endTransmission(false);
        wire.requestFrom(address, (uint8_t)2);
        if (wire.available() >= 2) {
            uint16_t value =  wire.read();               // LSB
            value |= (uint16_t)wire.read() << 8;        // MSB
            return value;
        }
        return 0;
    }

    uint8_t readRegister8(uint8_t reg) {
        wire.beginTransmission(address);
        wire.write(reg);
        wire.endTransmission(false);
        wire.requestFrom(address, (uint8_t)1);
        if (wire.available() >= 1) {
            return wire.read();
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

// ==============================================================================
// SECTION 2: DRIVERS — Per-device sensor logic
// ==============================================================================

// ------------------------------------------------------------------------------
// INA226 — Voltage / Current / Power Monitor
// ------------------------------------------------------------------------------
class INA226 : public I2CDevice {
public:
    INA226(TwoWire& wireInstance, uint8_t addr = 0x40)
        : I2CDevice(wireInstance, addr) {}

    bool begin() {
        // Default power-on config register value is 0x4127
        uint16_t config = readRegister16(REG_CONFIG);
        return (config != 0x0000 && config != 0xFFFF);
    }

    void calibrate(float rShunt_Ohms, float maxExpectedCurrent_Amps) {
        // Current_LSB = MaxCurrent / 2^15
        // Cal = 0.00512 / (Current_LSB * R_Shunt)   [datasheet eq.]
        currentLSB = maxExpectedCurrent_Amps / 32768.0f;
        uint16_t calValue = (uint16_t)(0.00512f / (currentLSB * rShunt_Ohms));
        writeRegister16(REG_CALIBRATION, calValue);
    }

    float getBusVoltage_V() {
        uint16_t raw = readRegister16(REG_BUS_VOLTAGE);
        return raw * 0.00125f;  // LSB = 1.25 mV (datasheet fixed)
    }

    float getShuntVoltage_mV() {
        int16_t raw = (int16_t)readRegister16(REG_SHUNT_VOLTAGE);
        return raw * 0.0025f;   // LSB = 2.5 µV = 0.0025 mV (datasheet fixed)
    }

    float getCurrent_A() {
        if (currentLSB == 0.0f) return 0.0f; // Guard: calibrate() not called
        int16_t raw = (int16_t)readRegister16(REG_CURRENT);
        return raw * currentLSB;
    }

private:
    float currentLSB = 0.0f;

    const uint8_t REG_CONFIG        = 0x00;
    const uint8_t REG_SHUNT_VOLTAGE = 0x01;
    const uint8_t REG_BUS_VOLTAGE   = 0x02;
    const uint8_t REG_POWER         = 0x03;
    const uint8_t REG_CURRENT       = 0x04;
    const uint8_t REG_CALIBRATION   = 0x05;
};

// ------------------------------------------------------------------------------
// TMP102 — Digital Temperature Sensor
// ------------------------------------------------------------------------------
class TMP102 : public I2CDevice {
public:
    TMP102(TwoWire& wireInstance, uint8_t addr = 0x48)
        : I2CDevice(wireInstance, addr) {}

    float readTemperatureC() {
        uint16_t raw  = readRegister16(REG_TEMPERATURE);
        int16_t  temp = (int16_t)raw >> 4; // 12-bit result, lower 4 bits unused
        return temp * 0.0625f;             // LSB = 0.0625 °C (datasheet fixed)
    }

private:
    static const uint8_t REG_TEMPERATURE = 0x00;
};

// ------------------------------------------------------------------------------
// ADM1177 — Hot Swap Controller / Power Monitor
// ------------------------------------------------------------------------------
class ADM1177 : public I2CDevice {
public:
    ADM1177(TwoWire& wireInstance, float rSenseOhms, uint8_t addr = 0x2D)
        : I2CDevice(wireInstance, addr), rSense(rSenseOhms) {}

    void startConversion() {
        writePointer(CMD_V_CONT | CMD_I_CONT | CMD_VRANGE);
        // writeRegister8(REG_CMD, CMD_V_CONT | CMD_I_CONT | CMD_VRANGE);
    }

    bool readData(uint16_t &voltage, uint16_t &current) {
        uint8_t buf[3] = {0};
        if (readBytes(buf, 3) < 3) return false;

        uint16_t vRaw = ((uint16_t)(buf[0] << 4)) | (buf[2] >> 4);
        uint16_t iRaw = ((uint16_t)(buf[1] << 4)) | (buf[2] & 0x0F);
        voltage = vRaw * (V_FULLSCALE    /  (ADM_RESOLUTION / 1000.0f));
        current = iRaw * (I_LSB_PER_OHM / ((ADM_RESOLUTION / 1000.0f) * rSense));

        return true;
    }

private:
    float rSense;

    // Register map
    static const uint8_t REG_CMD         = 0x00;

    // Command byte flags
    static const uint8_t CMD_V_CONT      = 0b00000001; // Voltage,  continuous
    static const uint8_t CMD_I_CONT      = 0b00000100; // Current,  continuous

    static const uint8_t CMD_VRANGE      = 0b0010000; // Chane FS Range

    // Conversion constants (ADM1177 datasheet)
    const float V_FULLSCALE    = 6.65f;   // Full-scale voltage (V)
    const float I_LSB_PER_OHM = 0.10584f;  // Current LSB · Ω factor
    const float ADM_RESOLUTION = 4096.0f;  // 12-bit ADC
};

// ==============================================================================
// SECTION 3: HARDWARE CONFIG — Bus and sensor instantiation
// ==============================================================================

TwoWire EPS_SEN(PF0, PF1); // I2C bus for EPS sensors (SDA, SCL)

INA226 powerMonitors[] = {
    INA226(EPS_SEN, 0x40),
    INA226(EPS_SEN, 0x41),
    INA226(EPS_SEN, 0x42),
    INA226(EPS_SEN, 0x43),
    INA226(EPS_SEN, 0x47),
    INA226(EPS_SEN, 0x48),
};

TMP102 tempSensors[] = {
    TMP102(EPS_SEN, 0x4A),
    TMP102(EPS_SEN, 0x4B),
};

ADM1177 powerControllers[] = {
    ADM1177(EPS_SEN, 0.06f, 0x58),
    ADM1177(EPS_SEN, 0.06f, 0x59),
    ADM1177(EPS_SEN, 0.06f, 0x5A),
    ADM1177(EPS_SEN, 0.06f, 0x5B),
};

// ==============================================================================
// SECTION 4: APPLICATION — Setup and main loop
// ==============================================================================

const float INA226_SHUNT_OHMS   = 0.02f;
const float INA226_MAX_AMPS     = 4.096f;
const int   INA226_COUNT        = 6;
const int   TMP102_COUNT        = 2;
const int   ADM1177_COUNT       = 4;

void setup() {
    Serial.setTx(PD8);
    Serial.setRx(PD9);
    Serial.begin(115200);

    EPS_SEN.begin();

    while (!Serial) { delay(10); }

    for (int i = 0; i < INA226_COUNT; i++) {
        if (!powerMonitors[i].begin()) {
            Serial.print("Failed to find INA226 at index ");
            Serial.println(i);
            while (1) { delay(100); }
        }
        powerMonitors[i].calibrate(INA226_SHUNT_OHMS, INA226_MAX_AMPS);
    }
    powerMonitors[INA226_COUNT - 1].calibrate(0.01, INA226_MAX_AMPS);
    powerMonitors[INA226_COUNT - 2].calibrate(0.01, INA226_MAX_AMPS);
    
    for (int i = 0; i < ADM1177_COUNT; i++) {
        powerControllers[i].startConversion();
    }

    Serial.println("All EPS Sensors initialized and calibrated.");
}

void loop() {
    Serial.println("\033c");
    for (int i = 0; i < INA226_COUNT; i++) {
        float busVolts   = powerMonitors[i].getBusVoltage_V();
        float shuntmV    = powerMonitors[i].getShuntVoltage_mV();
        float currentAmp = powerMonitors[i].getCurrent_A();

        Serial.print("INA226["); Serial.print(i); Serial.println("]:");
        Serial.print("  Bus Voltage   (V):  "); Serial.println(busVolts,   3);
        Serial.print("  Shunt Voltage (mV): "); Serial.println(shuntmV,    3);
        Serial.print("  Current       (A):  "); Serial.println(currentAmp, 3);
        Serial.println("-----------------------------------");
    }

    for (int i = 0; i < TMP102_COUNT; i++) {
        float tempC = tempSensors[i].readTemperatureC();
        Serial.print("TMP102["); Serial.print(i); Serial.print("]: ");
        Serial.print(tempC, 2); Serial.println(" °C");
    }

    for (int i = 0; i < ADM1177_COUNT; i++) {
        // powerControllers[i].startConversion();
        uint16_t voltage, current;
        if (powerControllers[i].readData(voltage, current)) {
            Serial.print("ADM1177["); Serial.print(i); Serial.println("]:");
            Serial.printf("  Voltage (mV): %04d\r\n",voltage);
            Serial.printf("  Current (mA): %04d\r\n",current);
            Serial.println("-----------------------------------");
        } else {
            Serial.print("Failed to read ADM1177 at index ");
            Serial.println(i);
        }
    }

    delay(300);
}