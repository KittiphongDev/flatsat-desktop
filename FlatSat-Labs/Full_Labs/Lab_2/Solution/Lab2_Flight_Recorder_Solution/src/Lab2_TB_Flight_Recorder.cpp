#include "Lab2_TB_Flight_Recorder.h"

void runFlightRecorderTestbench(Adafruit_SPIFlash &flashObj, uint32_t studentId, uint8_t studentCount)
{
  Serial.println("\n========================================");
  Serial.println("    VALIDATION TEST       ");
  Serial.println("========================================");

  bool isPassed = true;

  // Test 1: Hardware Integrity Check (Validates what the student captured in TODO 1)
  Serial.println("\n[TEST 1] Hardware Checking...");

  if (studentId == 0 || studentId == 0xFFFFFF)
  {
    Serial.println(" 🔴 [FAIL] Hardware Check: Variable 'jedecId' is empty or invalid!");
    Serial.println("   * Hint: Did you assign flash.getJEDECID() to 'jedecId' in TODO 1?");
    isPassed = false;
  }
  else
  {
    Serial.println(" 🟢 [PASS] Hardware Check: Student successfully grabbed W25Q128 JEDEC ID.");
  }

  // Test 2: Data Integrity Check (Validates student write operation in TODO 5)
  Serial.println("\n[TEST 2] Integrity Checking...");

  uint8_t physicalCount = 0;
  flashObj.readBuffer(0x0000, &physicalCount, 1);

  if (physicalCount != studentCount)
  {
    Serial.println(" 🔴 [FAIL] Integrity Check: Expected boot count " + String(studentCount) + " but read " + String(physicalCount) + " from IC.");
    Serial.println("   * Hint: Did you execute flash.writeBuffer() correctly in TODO 5?");
    isPassed = false;
  }
  else
  {
    Serial.println(" 🟢 [PASS] Integrity Check: Boot count value matched with physical Flash storage.");
  }

  // Test 3: Sector Erase Verification Check (Validates TODO 4)
  Serial.println("\n[TEST 3] Erase Checking...");

  uint8_t physicalEraseByte = 0;
  flashObj.readBuffer(0x0001, &physicalEraseByte, 1);

  // If the student skipped TODO 4, this byte will still be 0x00 (Injected Sabotage)
  if (physicalEraseByte != 0xFF)
  {
    Serial.println(" 🔴 [FAIL] Erase Check: Adjacent address 0x0001 is dirty (0x" + String(physicalEraseByte, HEX) + ")!");
    Serial.println("   * Hint: You MUST clear the sector using flash.eraseSector(0) before writing data!");
    isPassed = false;
  }
  else
  {
    Serial.println(" 🟢 [PASS] Erase Check: Sector 0 formatting verified (Dirty byte successfully cleared).");
  }

  // System Mission Evaluation
  Serial.println("\n========================================\n--- Test Summary ---");

  if (isPassed)
  {
    Serial.println(" 🟢 [PASS] Flight Recorder subsystem is fully operational.");
  }
  else
  {
    Serial.println(" 🔴 [FAIL] Flight Recorder malfunction. Critical logic error found.");
  }

  Serial.println("========================================\n");
}