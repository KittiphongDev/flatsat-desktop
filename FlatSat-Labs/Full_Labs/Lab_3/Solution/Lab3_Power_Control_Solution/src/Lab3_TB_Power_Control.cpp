#include "Lab3_TB_Power_Control.h"

void runPowerControlTestbench(bool ch1, bool ch2, bool ch3) {
  Serial.println("\n========================================");
  Serial.println("    VALIDATION TEST       ");
  Serial.println("========================================");

  bool isPassed = true;

  // Test 1: Channel 3 (ADCS) should be DISABLED (pre-filled example)
  Serial.println("\n[TEST 1] Checking Channel 3 (ADCS)...");
  if (!ch3) {
    Serial.println(" 🟢 [PASS] Channel 3 (ADCS): Correctly disabled.");
  } else {
    Serial.println(" 🔴 [FAIL] Channel 3 (ADCS): Should be OFF.");
    isPassed = false;
  }

  // Test 2: Channel 1 (Payload) should be ENABLED
  Serial.println("\n[TEST 2] Checking Channel 1 (Payload)...");
  if (ch1) {
    Serial.println(" 🟢 [PASS] Channel 1 (Payload): Correctly enabled.");
  } else {
    Serial.println(" 🔴 [FAIL] Channel 1 (Payload): Expected ON but state is OFF.");
    Serial.println("     * Hint: Complete TODO 1 — follow the example pattern above it.");
    isPassed = false;
  }

  // Test 3: Channel 2 (COMMS) should be ENABLED
  Serial.println("\n[TEST 3] Checking Channel 2 (COMMS)...");
  if (ch2) {
    Serial.println(" 🟢 [PASS] Channel 2 (COMMS): Correctly enabled.");
  } else {
    Serial.println(" 🔴 [FAIL] Channel 2 (COMMS): Expected ON but state is OFF.");
    Serial.println("     * Hint: Complete TODO 2 — same as TODO 1 but with EPS_CMD_CH2_ENABLE.");
    isPassed = false;
  }

  Serial.println("\n========================================");
  Serial.println("--- Test Summary ---");
  if (isPassed) {
    Serial.println(" 🟢 VALIDATE PASS: Power Control Sequencing Verified!");
  } else {
    Serial.println(" 🔴 VALIDATE FAILED: Please fix the errors and try again.");
  }
  Serial.println("========================================\n");
}
