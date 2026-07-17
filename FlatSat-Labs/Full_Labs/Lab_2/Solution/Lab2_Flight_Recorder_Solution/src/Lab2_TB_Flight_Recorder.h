#ifndef LAB2_TB_FLIGHT_RECORDER_H
#define LAB2_TB_FLIGHT_RECORDER_H

#include <Arduino.h>

#define EXTERNAL_FLASH_USE_SPI 1
#include <Adafruit_SPIFlash.h>

// Initailize Testbench for file .ino
void runFlightRecorderTestbench(Adafruit_SPIFlash &flashObj, uint32_t studentId, uint8_t studentCount);

#endif // LAB2_TB_FLIGHT_RECORDER_H