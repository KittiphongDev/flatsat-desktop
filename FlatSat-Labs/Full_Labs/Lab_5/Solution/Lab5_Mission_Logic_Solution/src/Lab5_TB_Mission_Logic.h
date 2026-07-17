#ifndef LAB5_TB_MISSION_LOGIC_H
#define LAB5_TB_MISSION_LOGIC_H

#include <Arduino.h>
#include "SdFat.h"

void runMissionTestbench(float lat, float lon, bool inTargetArea, SdFs &sd, int cameraPowerPin, const char *imageName);

#endif

