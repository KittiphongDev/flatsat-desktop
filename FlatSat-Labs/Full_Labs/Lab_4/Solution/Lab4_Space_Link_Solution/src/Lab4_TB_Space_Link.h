/*
 * NBSPACE Labs: FlatSat Learning Set
 * Lab 4.2: Testbench Header
 */

#ifndef LAB4_TB_SPACE_LINK_H
#define LAB4_TB_SPACE_LINK_H

#include <Arduino.h>
#include <RadioLib.h>

typedef int (*InitRadio_Ptr)(SX1278 &);
typedef int (*TransmitKISS_Ptr)(SX1278 &, const uint8_t *, size_t);

void runSpaceLinkTestbench(SX1278 &radioObj, InitRadio_Ptr initFunc, TransmitKISS_Ptr txFunc);

#endif // LAB4_TB_SPACE_LINK_H