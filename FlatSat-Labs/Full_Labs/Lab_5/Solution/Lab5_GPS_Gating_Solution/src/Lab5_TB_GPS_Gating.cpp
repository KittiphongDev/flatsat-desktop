#include "Lab5_TB_GPS_Gating.h"

void runGPSGatingTestbench(float lat, float lon, bool isInside) {
  const float ROI_LAT_MIN = 5.61;
  const float ROI_LAT_MAX = 20.46;
  const float ROI_LON_MIN = 97.34;
  const float ROI_LON_MAX = 105.63;
  
  bool expected = (lat >= ROI_LAT_MIN && lat <= ROI_LAT_MAX && lon >= ROI_LON_MIN && lon <= ROI_LON_MAX);
  
  if (isInside == expected) {
    Serial.println(" 🟢 [PASS] Gating logic is CORRECT.");
  } else {
    Serial.println(" 🔴 [FAIL] Gating logic is INCORRECT. Please review your program.");
  }
}
