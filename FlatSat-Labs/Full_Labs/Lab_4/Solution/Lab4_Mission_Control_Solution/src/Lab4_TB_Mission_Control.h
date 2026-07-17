/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 4.3: Testbench Header
 */

#ifndef LAB4_TB_MISSION_CONTROL_H
#define LAB4_TB_MISSION_CONTROL_H

#include <Arduino.h>
#include <RadioLib.h> 

typedef int (*InitRadio_Ptr)(SX1278&);
typedef size_t (*DecodeKISS_Ptr)(const uint8_t*, size_t, uint8_t*);
typedef bool (*VerifyChecksum_Ptr)(const uint8_t*, size_t);

void runMissionControlTestbench(SX1278& radioObj, InitRadio_Ptr initFunc, DecodeKISS_Ptr decodeFunc, VerifyChecksum_Ptr verifyFunc);

#endif // LAB4_TB_MISSION_CONTROL_H