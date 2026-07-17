/*
 * NBSPACE Labs: FlatSat Learning Set
 * Testbench Implementation
 */

#include "Lab2_TB_Telemetry_Vault.h"

void runTelemetryVaultTestbench(const char *fname)
{
  Serial.println("\n========================================");
  Serial.println("    VALIDATION TEST       ");
  Serial.println("========================================");
  bool isPassed = true;
  File testFile;

  Serial.println("\n[TEST 1] File Checking...");

  if (!testFile.open(fname, O_RDONLY))
  {
    Serial.println(" 🔴 [FAIL] File Check: flightlog.csv not found.");
    isPassed = false;
  }
  else
  {
    Serial.println(" 🟢 [PASS] File Check: flightlog.csv detected.");

    String headerLine = testFile.readStringUntil('\n');
    headerLine.trim();

    Serial.println("\n[TEST 2] Structural Checking...");

    if (headerLine != "Boot_Count,Timestamp,Battery_V,OBC_Temp")
    {
      Serial.println(" 🔴 [FAIL] Structural Check: CSV headers mismatch.");
      isPassed = false;
    }
    else
    {
      Serial.println(" 🟢 [PASS] Structural Check: CSV headers correct.");
    }

    int dataRowsCount = 0;
    while (testFile.available())
    {
      if (testFile.readStringUntil('\n').length() > 5)
      {
        dataRowsCount++;
      }
    }
    testFile.close();

    Serial.println("\n[TEST 3] Data Checking...");

    if (dataRowsCount > 0)
    {
      Serial.println(" 🟢 [PASS] Data Check: Records found: " + String(dataRowsCount));
    }
    else
    {
      Serial.println(" 🔴 [FAIL] Data Check: No valid records found.");
      isPassed = false;
    }
  }

  Serial.println("\n========================================\n--- Test Summary ---");

  if (isPassed)
  {
    Serial.println(" 🟢 [PASS] Telemetry Vault is stable.");
  }
  else
  {
    Serial.println(" 🔴 [FAIL] Telemetry storage fault.");
  }

  Serial.println("========================================\n");
}