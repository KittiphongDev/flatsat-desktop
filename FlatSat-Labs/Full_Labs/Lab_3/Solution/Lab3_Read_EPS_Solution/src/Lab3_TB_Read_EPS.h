#ifndef TESTBENCH_H
#define TESTBENCH_H

#include <Arduino.h>
#include <Wire.h>

// Validates all student-configured pins and I2C addresses
void runEPSTestbench(TwoWire &epsBus,
                     int epsSDA, int epsSCL,
                     int mainSDA, int mainSCL,
                     int serialRx, int serialTx,
                     const uint8_t solarAddrs[4],
                     uint8_t battChgAddr, uint8_t battDisAddr);

#endif
