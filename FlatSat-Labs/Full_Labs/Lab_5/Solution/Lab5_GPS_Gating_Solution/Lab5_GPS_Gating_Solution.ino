// NBSPACE Labs: FlatSat Learning Set
// Lab 5.2: GPS-Gating & Orbital Constraints
// Solution Code

#include <TinyGPS++.h>
#include "src/Lab5_TB_GPS_Gating.h"

// Define the Region of Interest (ROI) - e.g., Thailand Bounding Box
const float ROI_LAT_MIN = 5.61;
const float ROI_LAT_MAX = 20.46;
const float ROI_LON_MIN = 97.34;
const float ROI_LON_MAX = 105.63;

TinyGPSPlus gps;
HardwareSerial gps_uart(PE0, PE1);

void setup() {
  Serial.setTx(PD8);
  Serial.setRx(PD9);
  Serial.begin(115200);
  delay(4000);
  gps_uart.begin(9600);

  Serial.println("Lab 5.2: GPS Gating Logic Started");
}

void loop() {
  // Read GPS Data
  while (gps_uart.available() > 0) {
    gps.encode(gps_uart.read());
  }

  // Run GPS Gating Logic every 2 seconds
  static unsigned long lastCheck = 0;
  if (millis() - lastCheck > 2000) {
    lastCheck = millis();

    // Directly assign coordinates without checking for a valid fix
    float currentLat = gps.location.lat();
    float currentLon = gps.location.lng();
    
    bool inTargetArea = false;

    // --- Section 2: GPS-Gating Logic ---
    if (currentLat >= ROI_LAT_MIN && currentLat <= ROI_LAT_MAX &&
        currentLon >= ROI_LON_MIN && currentLon <= ROI_LON_MAX) {
      inTargetArea = true;
    } else {
      inTargetArea = false;
    }

    // Print the result
    Serial.print("Current Location: ");
    Serial.print(currentLat, 4); Serial.print(", "); Serial.println(currentLon, 4);
    
    if (inTargetArea) {
      Serial.println("Status: INSIDE TARGET AREA");
    } else {
      Serial.println("Status: OUTSIDE TARGET AREA");
    }

    runGPSGatingTestbench(currentLat, currentLon, inTargetArea);
  }
}