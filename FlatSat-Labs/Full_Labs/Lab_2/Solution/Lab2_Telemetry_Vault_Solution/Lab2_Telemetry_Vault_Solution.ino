/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 2.2: The Telemetry Vault (Solution Key)
 */

#include <SPI.h>
#include "SdFat_Adafruit_Fork.h"

#include "src/Lab2_TB_Telemetry_Vault.h"

// --- Hardware Connection Layer (SPI3) ---
#define SD_CS PC9
#define SD_SCK PC10
#define SD_MISO PC11
#define SD_MOSI PC12

SPIClass SD_SPI(SD_MOSI, SD_MISO, SD_SCK);
SdFat sd;
File flightFile;
const char *filename = "flightlog.csv";

// Mock telemetry data
uint8_t currentBootCount = 85;
String mockTimestamp = "12:34:56";
float mockBatteryV = 4.12;
float mockObcTemp = 28.50;

void setup()
{
  Serial.setRx(PD9);
  Serial.setTx(PD8);
  Serial.begin(115200);
  delay(4000);

  Serial.println("\n=== FlatSat Telemetry Vault Booting ===");
  SD_SPI.begin();

  if (!sd.begin(SdSpiConfig(SD_CS, DEDICATED_SPI, SD_SCK_MHZ(10), &SD_SPI)))
  {
    Serial.println(" 🔴 CRITICAL ERROR: SD Card not responding!");
    while (1)
      ;
  }
  Serial.println(" 🟢 SD Card filesystem mounted successfully.");

  // =========================================================
  // TB PREPARATION (DO NOT MODIFY)
  // =========================================================
  // sd.remove(filename); // Comment this line if you want continuous data slate for testing.
  // =========================================================

  // ---------------------------------------------------------
  // TODO: Telemetry Logging Logic (FILLED SOLUTION)
  // ---------------------------------------------------------

  // 1. Open file in Append Mode
  if (!flightFile.open(filename, O_RDWR | O_CREAT | O_AT_END))
  {
    Serial.println(" 🔴 ERROR: Failed to open flightlog.csv!");
    while (1)
      ;
  }

  // 2. Write header if new file
  if (flightFile.size() == 0)
  {
    Serial.println("New log file detected. Injecting CSV headers...");
    flightFile.println("Boot_Count,Timestamp,Battery_V,OBC_Temp");
  }

  // 3. Append data
  flightFile.print(currentBootCount);
  flightFile.print(",");
  flightFile.print(mockTimestamp);
  flightFile.print(",");
  flightFile.print(mockBatteryV, 2);
  flightFile.print(",");
  flightFile.println(mockObcTemp, 2);

  // 4. Close the file!
  flightFile.close();
  Serial.println("Telemetry frame committed to disk storage.");

  // ---------------------------------------------------------
  // Run Testbench (TB)
  // ---------------------------------------------------------
  runTelemetryVaultTestbench(filename);
}

void loop() {}