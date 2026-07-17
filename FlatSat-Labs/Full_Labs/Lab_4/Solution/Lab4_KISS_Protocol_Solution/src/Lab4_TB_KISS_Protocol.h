/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 4.1: Testbench Header
 */

#ifndef LAB4_TB_KISS_PROTOCOL_H
#define LAB4_TB_KISS_PROTOCOL_H

#include <Arduino.h>

typedef size_t (*KISS_Encoder_Ptr)(const uint8_t *payload, size_t payloadSize, uint8_t *outBuffer);

void runKISSTestbench(KISS_Encoder_Ptr studentFunc);

#endif // LAB4_TB_KISS_PROTOCOL_H