/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 2.3: The Backup Mission (Solution Key)
 */

#include <SPI.h>
#include "SdFat_Adafruit_Fork.h"

#define EXTERNAL_FLASH_USE_SPI 1
#include <Adafruit_SPIFlash.h>

#include "src/Lab2_TB_Backup_Mission.h"

// ====================================================================
// HARDWARE PIN DEFINITIONS (Dual SPI Bus Architecture)
// ====================================================================

// --- SPI FLASH BUS (SPI2) ---
#define FLASH_SCK PB13
#define FLASH_MISO PB14
#define FLASH_MOSI PB15
#define FLASH_CS PB12

SPIClass FLASH_SPI(FLASH_MOSI, FLASH_MISO, FLASH_SCK);
Adafruit_FlashTransport_SPI flashTransport(FLASH_CS, &FLASH_SPI);
Adafruit_SPIFlash flash(&flashTransport);

// --- SD CARD BUS (SPI3) ---
#define SD_SCK PC10
#define SD_MISO PC11
#define SD_MOSI PC12
#define SD_CS PC9

SPIClass SD_SPI(SD_MOSI, SD_MISO, SD_SCK);
SdFat sd;
File backupFile;

const char *textFilename = "safe_boot.txt";

void setup()
{
  Serial.setRx(PD9);
  Serial.setTx(PD8);
  Serial.begin(115200);

  delay(4000);

  Serial.println("\n=== FlatSat Emergency Backup Pipeline Initiated ===");
  Serial.println(" 🟡 WARNING: Voltage drop detected! Preparing data evacuation...");

  // Initialize both hardware SPI buses
  FLASH_SPI.begin();
  SD_SPI.begin();

  // 1. Mount SPI Flash (on SPI2)
  if (!flash.begin())
  {
    Serial.println(" 🔴 CRITICAL ERROR: SPI Flash not responding on PB12!");
    while (1)
      ;
  }

  // 2. Mount SD Card (on SPI3 using Dedicated Mode)
  if (!sd.begin(SdSpiConfig(SD_CS, DEDICATED_SPI, SD_SCK_MHZ(10), &SD_SPI)))
  {
    Serial.println(" 🔴 CRITICAL ERROR: SD Card not responding on PC9!");
    while (1)
      ;
  }
  Serial.println(" 🟢 Hardware peripherals successfully linked on Dual SPI buses.");

  // =========================================================
  // TB PREPARATION (DO NOT MODIFY)
  // =========================================================
  sd.remove(textFilename);
  // =========================================================

  // ---------------------------------------------------------
  // TODO: Emergency Backup Logic (FILLED SOLUTION)
  // ---------------------------------------------------------

  // Step 1: Read the last known boot count from Flash address 0x0000
  uint8_t exportedBootCount = 0;
  flash.readBuffer(0x0000, &exportedBootCount, 1);

  Serial.print("Retrieved Flight Recorder Status. Last Boot Count: ");
  Serial.println(exportedBootCount);

  // Step 2: Create/Overwrite a clean file on SD Card named "safe_boot.txt"
  if (!backupFile.open(textFilename, O_WRONLY | O_CREAT | O_TRUNC))
  {
    Serial.println(" 🔴 ERROR: Failed to create safe_boot.txt on SD card!");
    while (1)
      ;
  }

  // Step 3: Write the verification string along with the extracted count
  backupFile.print("Last known boot count: ");
  backupFile.println(exportedBootCount);

  // Step 4: Force flush data to the physical storage instantly by closing the handle
  backupFile.close();
  Serial.println("Emergency backup committed to Telemetry Vault.");
  Serial.println("OBC entering Deep Sleep Mode now...");

  // ---------------------------------------------------------
  // Run Testbench (TB)
  // ---------------------------------------------------------
  runBackupMissionTestbench(textFilename, exportedBootCount);
}

void loop()
{
  // Satellite system remains in power-saving sleep loop
}