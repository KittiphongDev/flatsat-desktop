/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 4.3: BIST Implementation for Ground Station (Advanced Gauntlet)
 */

#include "Lab4_TB_Mission_Control.h"

// Helper function to safely compare arrays
bool checkArrayMatchGS(const uint8_t* arr1, const uint8_t* arr2, size_t size) {
  for (size_t i = 0; i < size; i++) {
    if (arr1[i] != arr2[i]) return false;
  }
  return true;
}

void runMissionControlTestbench(SX1278& radioObj, InitRadio_Ptr initFunc, DecodeKISS_Ptr decodeFunc, VerifyChecksum_Ptr verifyFunc) {
  Serial.println("\n--- Running BIST (Advanced Mission Control Evaluator) ---");
  int passedTests = 0;
  const int TOTAL_TESTS = 8;
  uint8_t studentBuffer[64];

  // ==========================================
  // Test 1: Hardware Initialization Check
  // ==========================================
  int initStatus = initFunc(radioObj);
  if (initStatus != RADIOLIB_ERR_NONE) {
    Serial.print(" 🔴 [FAIL] Test 1: Ground Station radio init error code ");
    Serial.println(initStatus);
  } else {
    Serial.println(" 🟢 [PASS] Test 1: Hardware Radio initialized.");
    passedTests++;
  }

  // ==========================================
  // Test 2: Decoding Normal Payload
  // ==========================================
  const uint8_t tc2_raw[] = {0xC0, 0x11, 0x22, 0x33, 0xC0};
  const uint8_t tc2_exp[] = {0x11, 0x22, 0x33};
  size_t tc2_len = decodeFunc(tc2_raw, sizeof(tc2_raw), studentBuffer);
  
  if (tc2_len == sizeof(tc2_exp) && checkArrayMatchGS(studentBuffer, tc2_exp, tc2_len)) {
    Serial.println(" 🟢 [PASS] Test 2: Normal frame decoded properly.");
    passedTests++;
  } else {
    Serial.println(" 🔴 [FAIL] Test 2: Failed to parse a standard frame.");
  }

  // ==========================================
  // Test 3: Decoding FEND Stuffing (0xDB 0xDC -> 0xC0)
  // ==========================================
  const uint8_t tc3_raw[] = {0xC0, 0xAA, 0xDB, 0xDC, 0xBB, 0xC0};
  const uint8_t tc3_exp[] = {0xAA, 0xC0, 0xBB};
  size_t tc3_len = decodeFunc(tc3_raw, sizeof(tc3_raw), studentBuffer);

  if (tc3_len == sizeof(tc3_exp) && checkArrayMatchGS(studentBuffer, tc3_exp, tc3_len)) {
    Serial.println(" 🟢 [PASS] Test 3: FEND un-stuffing successful.");
    passedTests++;
  } else {
    Serial.println(" 🔴 [FAIL] Test 3: FEND un-stuffing (0xDB 0xDC) failed.");
  }

  // ==========================================
  // Test 4: Decoding FESC Stuffing (0xDB 0xDD -> 0xDB)
  // ==========================================
  const uint8_t tc4_raw[] = {0xC0, 0x44, 0xDB, 0xDD, 0x55, 0xC0};
  const uint8_t tc4_exp[] = {0x44, 0xDB, 0x55};
  size_t tc4_len = decodeFunc(tc4_raw, sizeof(tc4_raw), studentBuffer);

  if (tc4_len == sizeof(tc4_exp) && checkArrayMatchGS(studentBuffer, tc4_exp, tc4_len)) {
    Serial.println(" 🟢 [PASS] Test 4: FESC un-stuffing successful.");
    passedTests++;
  } else {
    Serial.println(" 🔴 [FAIL] Test 4: FESC un-stuffing (0xDB 0xDD) failed.");
  }

  // ==========================================
  // Test 5: Out-of-Bounds Noise Rejection
  // ==========================================
  const uint8_t tc5_raw[] = {0xFF, 0xEE, 0xC0, 0x99, 0x88, 0xC0, 0x77, 0x66};
  const uint8_t tc5_exp[] = {0x99, 0x88};
  size_t tc5_len = decodeFunc(tc5_raw, sizeof(tc5_raw), studentBuffer);

  if (tc5_len == sizeof(tc5_exp) && checkArrayMatchGS(studentBuffer, tc5_exp, tc5_len)) {
    Serial.println(" 🟢 [PASS] Test 5: Ignored RF noise outside the FEND markers.");
    passedTests++;
  } else {
    Serial.println(" 🔴 [FAIL] Test 5: Failed to ignore garbage bytes outside the frame.");
  }

  // ==========================================
  // Test 6: Empty Frame Edge Case
  // ==========================================
  const uint8_t tc6_raw[] = {0xC0, 0xC0};
  size_t tc6_len = decodeFunc(tc6_raw, sizeof(tc6_raw), studentBuffer);

  if (tc6_len == 0) {
    Serial.println(" 🟢 [PASS] Test 6: Handled empty frame gracefully (Size 0).");
    passedTests++;
  } else {
    Serial.println(" 🔴 [FAIL] Test 6: Empty frame returned a non-zero size.");
  }

  // ==========================================
  // Test 7: Valid Checksum Verification
  // ==========================================
  const uint8_t tc7_payload[] = {0x12, 0x34, 0x56, 0x70}; // 0x12 ^ 0x34 ^ 0x56 = 0x70
  if (verifyFunc(tc7_payload, sizeof(tc7_payload)) == true) {
    Serial.println(" 🟢 [PASS] Test 7: Checksum algorithm approved valid data.");
    passedTests++;
  } else {
    Serial.println(" 🔴 [FAIL] Test 7: Checksum algorithm rejected valid data.");
  }

  // ==========================================
  // Test 8: Invalid Checksum Rejection (Solar Storm)
  // ==========================================
  const uint8_t tc8_payload[] = {0x12, 0x34, 0x56, 0xFF}; // Bad Checksum
  if (verifyFunc(tc8_payload, sizeof(tc8_payload)) == false) {
    Serial.println(" 🟢 [PASS] Test 8: Checksum algorithm dropped corrupted data.");
    passedTests++;
  } else {
    Serial.println(" 🔴 [FAIL] Test 8: Checksum algorithm allowed corrupted data to pass!");
  }

  // ==========================================
  // Final Evaluation
  // ==========================================
  Serial.println("\n-------------------------------------------");
  if (passedTests == TOTAL_TESTS) {
    Serial.println(" 🟢 [PASS] Ground Station Decoder is fully operational and space-ready!");
  } else {
    Serial.print(" 🔴 [FAIL] Passed ");
    Serial.print(passedTests);
    Serial.print(" out of ");
    Serial.print(TOTAL_TESTS);
    Serial.println(" tests. Mission Control software fault detected.");
  }
  Serial.println("-------------------------------------------\n");
}