#include "Lab1_TB_OBC_Init.h"

void runBootTestbench(String msg, int rxPin, int txPin) {
  Serial.println("\n========================================");
  Serial.println("    VALIDATION TEST       ");
  Serial.println("========================================");
  
  bool msgTestPassed = false;

  Serial.println("\n[TEST 1] Checking Boot Message...");
  String cleanMsg = msg;
  cleanMsg.trim();

  if (cleanMsg == "") {
    Serial.println(" 🔴 [FAIL] Boot message is empty. Please complete TODO 3.");
  } else {
    Serial.println(" 🟢 [PASS] Boot message detected: \"" + cleanMsg + "\"");
    msgTestPassed = true;
  }

  Serial.println("\n========================================\n--- Test Summary ---");
  if (msgTestPassed) {
    Serial.println(" 🟢 VALIDATE PASS: OBC Initialization Complete!");
  } else {
    Serial.println(" 🔴 VALIDATE FAILED: Please fix the errors and try again.");
  }
  Serial.println("========================================\n");
}