/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 4.2: BIST Implementation for RF Space Link
 */

#include "Lab4_TB_Space_Link.h"

void runSpaceLinkTestbench(SX1278 &radioObj, InitRadio_Ptr initFunc, TransmitKISS_Ptr txFunc)
{
    Serial.println("\n--- Running BIST (RF Hardware & Transmission Evaluator) ---");
    bool isPassed = true;

    // ==========================================
    // Test 1: Hardware Initialization Check
    // ==========================================
    Serial.println("[*] Triggering student's initialization function...");
    int initStatus = initFunc(radioObj);

    if (initStatus != RADIOLIB_ERR_NONE)
    {
        Serial.print(" 🔴 [FAIL] Hardware Check: Radio initialization returned error code ");
        Serial.println(initStatus);
        Serial.println("   * Hint: Check SPI wiring and ensure radioObj.beginFSK() is called.");
        isPassed = false;
    }
    else
    {
        Serial.println(" 🟢 [PASS] Hardware Check: Radio chip responded and configured correctly.");
    }

    // Abort if hardware is not responding to avoid crashing on transmit
    if (!isPassed)
    {
        Serial.println(" 🟡 Aborting RF Transmission test due to hardware failure.");
        Serial.println("-------------------------------------------\n");
        return;
    }

    // ==========================================
    // Test 2: RF Transmission Execution Check
    // ==========================================
    Serial.println("[*] Triggering student's transmission function...");

    // Test Payload contains a forbidden byte (0xC0) to verify they used KISS
    const uint8_t testPayload[] = {0xAA, 0xC0, 0xBB};

    int txStatus = txFunc(radioObj, testPayload, sizeof(testPayload));

    if (txStatus != RADIOLIB_ERR_NONE)
    {
        Serial.print(" 🔴 [FAIL] Transmission Check: RF transmission failed with code ");
        Serial.println(txStatus);
        Serial.println("   * Hint: Make sure radioObj.transmit() is executed with correct buffer and size.");
        isPassed = false;
    }
    else
    {
        Serial.println(" 🟢 [PASS] Transmission Check: Test packet successfully blasted over the airwaves!");
    }

    // ==========================================
    // Final Conclusion
    // ==========================================
    Serial.println("\n-------------------------------------------");
    if (isPassed)
    {
        Serial.println(" 🟢 [PASS] FlatSat is now transmitting telemetry to Earth!");
        Serial.println("   -> Next Step: Configure your Ground Station to catch the signal.");
    }
    else
    {
        Serial.println(" 🟡 [FAIL] Communication subsystem fault detected.");
    }
    Serial.println("-------------------------------------------\n");
}