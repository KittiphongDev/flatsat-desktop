#include "Lab5_TB_Mission_Logic.h"

void runMissionTestbench(float lat, float lon, bool studentInTargetArea, SdFs &sd, int cameraPowerPin, const char *imageName) {
  const float ROI_LAT_MIN = 5.61;
  const float ROI_LAT_MAX = 20.46;
  const float ROI_LON_MIN = 97.34;
  const float ROI_LON_MAX = 105.63;
  
  bool expectedInTargetArea = (lat >= ROI_LAT_MIN && lat <= ROI_LAT_MAX && lon >= ROI_LON_MIN && lon <= ROI_LON_MAX);
  
  // Check for Power pin state (use pin provided by caller)
  int powerPinState = digitalRead(cameraPowerPin);

  bool logicCorrect = (studentInTargetArea == expectedInTargetArea);
  bool pinCorrect = false;

  if (expectedInTargetArea && powerPinState == HIGH) {
    pinCorrect = true;
  } else if (!expectedInTargetArea && powerPinState == LOW) {
    pinCorrect = true;
  }

  // Check for saved image using provided image name (with fallbacks)
  bool isImageSaved = sd.exists(imageName) || sd.exists("IMG_0.JPG") || sd.exists("0.jpg");
  bool isMetadataSaved = sd.exists("METADATA.TXT");

  if (logicCorrect && pinCorrect) {
    if (expectedInTargetArea) {
      if (isImageSaved && isMetadataSaved) {
        Serial.println(" 🟢 [PASS] Mission Logic, Power, & Capture/Save are CORRECT.");
      } else {
        Serial.println(" 🔴 [FAIL] Logic/Power correct, but Image/Metadata NOT saved!");
      }
    } else {
      Serial.println(" 🟢 [PASS] Mission Logic & Payload Power are CORRECT (Standby Mode).");
    }
  } else {
    if (!logicCorrect) {
      Serial.println(" 🔴 [FAIL] Gating logic is INCORRECT. Check ROI conditions.");
    }
    if (!pinCorrect) {
      Serial.println(" 🔴 [FAIL] Power State mismatch! Check CAMERA_POWER_PIN logic.");
    }
  }
}
