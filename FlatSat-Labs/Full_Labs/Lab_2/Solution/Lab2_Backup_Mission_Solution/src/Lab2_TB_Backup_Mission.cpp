/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 2.3 Testbench Implementation
 */

#include "Lab2_TB_Backup_Mission.h"
#include "SdFat_Adafruit_Fork.h"

void runBackupMissionTestbench(const char *fname, uint8_t originalCount)
{
  Serial.println("\n========================================");
  Serial.println("    VALIDATION TEST       ");
  Serial.println("========================================");
  bool isPassed = true;

  File testFile;

  // Test 1: Verify if the backup file exists
  Serial.println("\n[TEST 1] File Checking...");

  if (!testFile.open(fname, O_RDONLY))
  {
    Serial.println(" 🔴 [FAIL] File Check: safe_boot.txt not found on the SD card.");
    Serial.println("    * Hint: Did you create the file in TODO 2 and close it in TODO 4?");
    isPassed = false;
  }
  else
  {
    Serial.println(" 🟢 [PASS] File Check: safe_boot.txt verified on disk.");

    // Test 2: Parse and verify content integrity
    String fileContent = testFile.readString();
    testFile.close();
    fileContent.trim(); // Clean trailing whitespaces

    Serial.println("   Reading File Content: \"" + fileContent + "\"");

    // Verify the file contains the original boot count number
    Serial.println("\n[TEST 2] Content Checking...");

    if (fileContent.indexOf(String(originalCount)) == -1 || originalCount == 0)
    {
      Serial.println(" 🔴 [FAIL] Content Check: Data corruption or missing data detected.");
      Serial.println("    -> Found:    \"" + fileContent + "\"");
      Serial.println("    -> Expected to find the number: " + String(originalCount));
      Serial.println("    * Hint: Did you properly read from Flash (TODO 1) and write to SD (TODO 3)?");
      isPassed = false;
    }
    else
    {
      Serial.println(" 🟢 [PASS] Content Check: Flash-to-SD pipeline data matches perfectly.");
    }
  }

  // Final Evaluation
  Serial.println("\n========================================\n--- Test Summary ---");

  if (isPassed)
  {
    Serial.println(" 🟢 [PASS] Data evacuation successful. System safe to power off.");
  }
  else
  {
    Serial.println(" 🔴 [FAIL] Data lost in transmission. Check your code logic.");
  }

  Serial.println("========================================\n");
}