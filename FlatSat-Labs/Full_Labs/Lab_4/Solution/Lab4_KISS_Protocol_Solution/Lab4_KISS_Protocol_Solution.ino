/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 4.1: The KISS Protocol (Solution Key)
 * Objective: Implement Byte Stuffing to prepare telemetry data for RF transmission.
 */

#include <Arduino.h>

#include "src/Lab4_TB_KISS_Protocol.h"

// ====================================================================
// KISS PROTOCOL DEFINITIONS
// ====================================================================
#define FEND 0xC0  // Frame End (Marks start and end of a packet)
#define FESC 0xDB  // Frame Escape (Used to replace forbidden bytes)
#define TFEND 0xDC // Transposed Frame End (Replaces FEND in payload)
#define TFESC 0xDD // Transposed Frame Escape (Replaces FESC in payload)

// ---------------------------------------------------------
// TODO: KISS Protocol Byte Stuffing Function (FILLED SOLUTION)
// ---------------------------------------------------------

size_t encodeKISS(const uint8_t *payload, size_t payloadSize, uint8_t *outBuffer)
{
    size_t outIndex = 0;

    // 1. Add Start FEND
    outBuffer[outIndex++] = FEND;

    // 2. Loop through raw payload and apply Byte Stuffing
    for (size_t i = 0; i < payloadSize; i++)
    {
        uint8_t currentByte = payload[i];

        if (currentByte == FEND)
        {
            // Replace 0xC0 with 0xDB 0xDC
            outBuffer[outIndex++] = FESC;
            outBuffer[outIndex++] = TFEND;
        }
        else if (currentByte == FESC)
        {
            // Replace 0xDB with 0xDB 0xDD
            outBuffer[outIndex++] = FESC;
            outBuffer[outIndex++] = TFESC;
        }
        else
        {
            // Normal byte, copy as-is
            outBuffer[outIndex++] = currentByte;
        }
    }

    // 3. Add End FEND
    outBuffer[outIndex++] = FEND;

    return outIndex; // Return the final packet size
}

void setup()
{
    Serial.setRx(PD9);
    Serial.setTx(PD8);
    Serial.begin(115200);
    delay(2000);
    Serial.println("\n=== FlatSat COMMS: KISS Protocol Encapsulation ===");

    // ---------------------------------------------------------
    // Run Testbench (TB)
    // ---------------------------------------------------------
    runKISSTestbench(encodeKISS);
}

void loop()
{
    // Execute once
}