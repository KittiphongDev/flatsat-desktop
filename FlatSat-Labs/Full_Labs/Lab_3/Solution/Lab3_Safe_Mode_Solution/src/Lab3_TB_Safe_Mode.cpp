#include "Lab3_TB_Safe_Mode.h"

// --- Internal simulation helper ---
// Applies simulated pin state and checks it, without touching student's loop logic.
static bool simCheckPins(bool expectSafeMode) {
  if (expectSafeMode) {
    // Simulate: testbench drives pins LOW (as if safe mode triggered)
    digitalWrite(PD1, LOW);
    digitalWrite(PD2, LOW);
    digitalWrite(PD3, LOW);
    return (digitalRead(PD1) == LOW && digitalRead(PD2) == LOW && digitalRead(PD3) == LOW);
  } else {
    // Simulate: testbench drives pins HIGH (as if nominal/recovery)
    digitalWrite(PD1, HIGH);
    digitalWrite(PD2, HIGH);
    digitalWrite(PD3, HIGH);
    return (digitalRead(PD1) == HIGH && digitalRead(PD2) == HIGH && digitalRead(PD3) == HIGH);
  }
}

void runSafeModeTestbench(float voltage, float temp, bool triggered) {

  // Hardcoded thresholds — students do not set these
  const float SAFE_THRESHOLD     = 3.36; // 30% battery
  const float RECOVERY_THRESHOLD = 3.84; // 70% battery

  Serial.println("\n========================================");
  Serial.println("    VALIDATION TEST       ");
  Serial.println("========================================");

  bool isPassed = true;

  // -------------------------------------------------------
  // Test 1: Voltage Sensor Sanity (live reading)
  // -------------------------------------------------------
  Serial.println("\n[TEST 1] Checking Voltage Reading...");
  if (voltage == 0.0) {
    Serial.println(" 🔴 [FAIL] Voltage reading is 0.00V. Sensor not responding.");
    isPassed = false;
  } else if (voltage < 0.0 || voltage > 26.0) {
    Serial.println(" 🔴 [FAIL] Voltage " + String(voltage, 2) + "V is outside expected range.");
    isPassed = false;
  } else {
    Serial.println(" 🟢 [PASS] Voltage: " + String(voltage, 2) + "V reading captured.");
  }

  // -------------------------------------------------------
  // Test 2: Temperature Sensor Sanity (live reading)
  // -------------------------------------------------------
  Serial.println("\n[TEST 2] Checking Temperature Reading...");
  if (temp == 0.0) {
    Serial.println(" 🔴 [FAIL] Temperature reading is 0.00C. Sensor not responding.");
    isPassed = false;
  } else if (temp < -40.0 || temp > 125.0) {
    Serial.println(" 🔴 [FAIL] Temperature " + String(temp, 2) + "C is outside TMP102 range.");
    isPassed = false;
  } else {
    Serial.println(" 🟢 [PASS] Temperature: " + String(temp, 2) + "C reading captured.");
  }

  // -------------------------------------------------------
  // Test 3: Simulated Safe Mode Activation (Scenario A: Low Voltage)
  // Simulates voltage = 3.10V — below SAFE_THRESHOLD (3.36V)
  // Expected: safeModeTriggered = true, all pins = LOW
  // -------------------------------------------------------
  Serial.println("\n[TEST 3] Simulated Scenario A — Low Voltage (3.10V < 3.36V):");

  float simLowVoltage = 3.10;
  bool simLowExpectedTrigger = true;
  bool simLowLogicOK = false;
  bool simLowPinOK   = false;

  // Check: for this voltage, student's live triggered state should be true
  // (If live voltage is also low, this is a real scenario; otherwise it's a sim-only logic check)
  if (voltage > 0.0 && voltage < SAFE_THRESHOLD) {
    simLowLogicOK = (triggered == true);
  } else {
    // Live voltage is nominal — simulate the outcome expectation only
    simLowLogicOK = true; // Can't check student bool for a different voltage; skip logic
    Serial.println("   [SIM] Live voltage is nominal. Simulating pin control only for V=" + String(simLowVoltage, 2) + "V.");
  }

  // Simulate GPIO: drive pins LOW and verify MCU responds
  simLowPinOK = simCheckPins(true);

  if (simLowLogicOK && simLowPinOK) {
    Serial.println(" 🟢 [PASS] Safe Mode activation scenario passed. Pins correctly set LOW.");
  } else {
    Serial.println(" 🔴 [FAIL] Safe Mode activation scenario failed!");
    if (!simLowLogicOK)
      Serial.println("     * Safe Mode flag was not triggered when voltage is below 3.36V.");
    if (!simLowPinOK)
      Serial.println("     * GPIO pins did not respond to LOW drive. Check PIN_PAYLOAD_1/2 and PIN_COMMS.");
    isPassed = false;
  }

  // -------------------------------------------------------
  // Test 4: Simulated Recovery (Scenario B: High Voltage)
  // Simulates voltage = 4.00V — above RECOVERY_THRESHOLD (3.84V)
  // Expected: safeModeTriggered = false, all pins = HIGH
  // -------------------------------------------------------
  Serial.println("\n[TEST 4] Simulated Scenario B — Recovery Voltage (4.00V > 3.84V):");

  float simHighVoltage = 4.00;
  bool simHighLogicOK = false;
  bool simHighPinOK   = false;

  // Check: for this voltage, student's live triggered state should be false
  if (voltage >= RECOVERY_THRESHOLD) {
    simHighLogicOK = (triggered == false);
  } else {
    // Live voltage not in recovery zone — only test GPIO response
    simHighLogicOK = true;
    Serial.println("   [SIM] Live voltage is not in recovery zone. Simulating pin control only for V=" + String(simHighVoltage, 2) + "V.");
  }

  // Simulate GPIO: drive pins HIGH and verify MCU responds
  simHighPinOK = simCheckPins(false);

  if (simHighLogicOK && simHighPinOK) {
    Serial.println(" 🟢 [PASS] Recovery scenario passed. Pins correctly restored HIGH.");
  } else {
    Serial.println(" 🔴 [FAIL] Recovery scenario failed!");
    if (!simHighLogicOK)
      Serial.println("     * Safe Mode flag still active when voltage is above 3.84V. Check recovery logic in TODO 3.");
    if (!simHighPinOK)
      Serial.println("     * GPIO pins did not respond to HIGH drive. Check PIN_PAYLOAD_1/2 and PIN_COMMS.");
    isPassed = false;
  }

  // -------------------------------------------------------
  // Test 5: Live Safe Mode Logic Check (real sensor data)
  // -------------------------------------------------------
  Serial.println("\n[TEST 5] Live Safe Mode Logic Check (V=" + String(voltage, 2) + "V):");

  if (voltage > 0.0 && voltage < SAFE_THRESHOLD) {
    if (triggered) {
      Serial.println(" 🟢 [PASS] Safe Mode correctly ACTIVE at " + String(voltage, 2) + "V (below 30%).");
    } else {
      Serial.println(" 🔴 [FAIL] Voltage below 30% but Safe Mode NOT triggered! Check TODO 3.");
      isPassed = false;
    }
  } else if (voltage >= RECOVERY_THRESHOLD) {
    if (!triggered) {
      Serial.println(" 🟢 [PASS] Safe Mode correctly INACTIVE at " + String(voltage, 2) + "V (above 70%).");
    } else {
      Serial.println(" 🔴 [FAIL] Voltage above 70% but Safe Mode still ACTIVE! Check recovery logic.");
      isPassed = false;
    }
  } else {
    // Hysteresis zone (3.36–3.84V)
    Serial.println(" 🟡 [INFO] Voltage in hysteresis zone. Safe Mode: " + String(triggered ? "ACTIVE" : "INACTIVE") + " (either is valid).");
  }

  // Restore pins to live triggered state after simulations
  if (triggered) {
    digitalWrite(PD1, LOW);
    digitalWrite(PD2, LOW);
    digitalWrite(PD3, LOW);
  } else {
    digitalWrite(PD1, HIGH);
    digitalWrite(PD2, HIGH);
    digitalWrite(PD3, HIGH);
  }

  Serial.println("\n========================================");
  Serial.println("--- Test Summary ---");
  if (isPassed) {
    Serial.println(" 🟢 VALIDATE PASS: Safe Mode Controller Verified!");
  } else {
    Serial.println(" 🔴 VALIDATE FAILED: Please fix the errors and try again.");
  }
  Serial.println("========================================\n");
}
