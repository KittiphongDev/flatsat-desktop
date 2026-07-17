/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 4.1: BIST Implementation for KISS Protocol
 */

#include "Lab4_TB_KISS_Protocol.h"

// Helper function to check if two arrays match
bool checkArrayMatch(const uint8_t *arr1, const uint8_t *arr2, size_t size)
{
  for (size_t i = 0; i < size; i++)
  {
    if (arr1[i] != arr2[i])
      return false;
  }
  return true;
}

void runKISSTestbench(KISS_Encoder_Ptr studentFunc)
{
  Serial.println("\n========================================");
  Serial.println("    VALIDATION TEST       ");
  Serial.println("========================================");
  int passedTests = 0;
  uint8_t studentBuffer[64]; // Buffer for student function to write into

  // ==========================================
  // Test Case 1: Normal Payload (No forbidden bytes)
  // ==========================================
  const uint8_t tc1_raw[] = {0x11, 0x22, 0x33};
  const uint8_t tc1_exp[] = {0xC0, 0x11, 0x22, 0x33, 0xC0};
  size_t tc1_len = studentFunc(tc1_raw, sizeof(tc1_raw), studentBuffer);

  if (tc1_len == sizeof(tc1_exp) && checkArrayMatch(studentBuffer, tc1_exp, tc1_len))
  {
    Serial.println(" 🟢 [PASS] Test Case 1: Normal Data Encapsulation");
    passedTests++;
  }
  else
  {
    Serial.println(" 🔴 [FAIL] Test Case 1: Normal Data Encapsulation");
    Serial.println("    * Hint: Did you add FEND (0xC0) at both start and end?");
  }

  // ==========================================
  // Test Case 2: Contains FEND (0xC0)
  // ==========================================
  const uint8_t tc2_raw[] = {0xAA, 0xC0, 0xBB};
  const uint8_t tc2_exp[] = {0xC0, 0xAA, 0xDB, 0xDC, 0xBB, 0xC0};
  size_t tc2_len = studentFunc(tc2_raw, sizeof(tc2_raw), studentBuffer);

  if (tc2_len == sizeof(tc2_exp) && checkArrayMatch(studentBuffer, tc2_exp, tc2_len))
  {
    Serial.println(" 🟢 [PASS] Test Case 2: FEND Byte Stuffing (0xC0 -> 0xDB 0xDC)");
    passedTests++;
  }
  else
  {
    Serial.println(" 🔴 [FAIL] Test Case 2: FEND Byte Stuffing Failed!");
  }

  // ==========================================
  // Test Case 3: Contains FESC (0xDB)
  // ==========================================
  const uint8_t tc3_raw[] = {0x44, 0xDB, 0x55};
  const uint8_t tc3_exp[] = {0xC0, 0x44, 0xDB, 0xDD, 0x55, 0xC0};
  size_t tc3_len = studentFunc(tc3_raw, sizeof(tc3_raw), studentBuffer);

  if (tc3_len == sizeof(tc3_exp) && checkArrayMatch(studentBuffer, tc3_exp, tc3_len))
  {
    Serial.println(" 🟢 [PASS] Test Case 3: FESC Byte Stuffing (0xDB -> 0xDB 0xDD)");
    passedTests++;
  }
  else
  {
    Serial.println(" 🔴 [FAIL] Test Case 3: FESC Byte Stuffing Failed!");
  }

  // ==========================================
  // Test Case 4: Nightmare Scenario (Consecutive forbidden bytes)
  // ==========================================
  const uint8_t tc4_raw[] = {0xC0, 0xDB};
  const uint8_t tc4_exp[] = {0xC0, 0xDB, 0xDC, 0xDB, 0xDD, 0xC0};
  size_t tc4_len = studentFunc(tc4_raw, sizeof(tc4_raw), studentBuffer);

  if (tc4_len == sizeof(tc4_exp) && checkArrayMatch(studentBuffer, tc4_exp, tc4_len))
  {
    Serial.println(" 🟢 [PASS] Test Case 4: Consecutive Forbidden Bytes Handling");
    passedTests++;
  }
  else
  {
    Serial.println(" 🔴 [FAIL] Test Case 4: Consecutive special bytes caused an error!");
  }

  // ==========================================
  // Final Evaluation
  // ==========================================
  Serial.println("\n-------------------------------------------");
  if (passedTests == 4)
  {
    Serial.println(" 🟢 [PASS] KISS Protocol Algorithm is robust and space-ready!");
  }
  else
  {
    Serial.print(" 🔴 [FAIL] Algorithm failed ");
    Serial.print(4 - passedTests);
    Serial.println(" test(s). Ground station will reject this data.");
  }
  Serial.println("-------------------------------------------\n");
}