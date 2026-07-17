// NBSPACE Labs: FlatSat Learning Set
// Lab 5.3: Mission Logic & Payload Control
// Solution Code (Integrated GPS Gating & Image Saving)

#include <Wire.h>
#include <PCF85063TP.h>
#include <TinyGPS++.h>
#include <SPI.h>
#include "SdFat.h"
#include "Arducam_Mega.h"
#include "src/Lab5_TB_Mission_Logic.h"

// Define ROI (Region of Interest)
const float ROI_LAT_MIN = 5.61;
const float ROI_LAT_MAX = 20.46;
const float ROI_LON_MIN = 97.34;
const float ROI_LON_MAX = 105.63;

// Initialize Hardware interfaces
HardwareSerial gps_uart(PE0, PE1);
PCD85063TP rtc;
TinyGPSPlus gps;

// SD Card and Camera definitions
#define SPI_DRIVER_SELECT 2
#define ENABLE_DEDICATED_SPI 1

SPIClass SD_SPI(PC12, PC11, PC10);
const int SD_CS = PC9;
#define SD_CONFIG SdSpiConfig(SD_CS, DEDICATED_SPI, SD_SCK_MHZ(8), &SD_SPI)
SdFs sd;
FsFile file;

const int CAM_CS = PE_7;
Arducam_Mega myCAM(CAM_CS);
#define BUFFER_SIZE 256 // Better alignment for SD Card writes

// Power Control Pin for Payload
const int CAMERA_POWER_PIN = PD4;
bool isCameraOn = false; // Tracks if camera is already powered up

// Image saving variables
uint8_t imageCount = 0;
char imageName[13] = { 0 };
uint8_t imageData = 0;
uint8_t imageDataNext = 0;
uint8_t headFlag = 0;
unsigned int buffIndex = 0;
uint8_t imageBuff[BUFFER_SIZE] = { 0 };

// --- STM32 ARDUCAM HAL FIX ---
// The Arducam C-core lacks STM32 definitions for the CS pin.
// This block links the C-core to standard Arduino commands.
extern "C" {
  void arducamCsOutputMode() {
    pinMode(CAM_CS, OUTPUT);
  }
  void arducamSpiCsPinLow() {
    digitalWrite(CAM_CS, LOW);
  }
  void arducamSpiCsPinHigh() {
    digitalWrite(CAM_CS, HIGH);
  }
}
// -----------------------------

void setup() {
  Serial.setTx(PD8);
  Serial.setRx(PD9);
  Serial.begin(115200);

  Wire.setSDA(PB9);
  Wire.setSCL(PB8);
  Wire.begin();
  
  gps_uart.begin(9600);
  rtc.begin();

  // Set the CAMERA_POWER_PIN as OUTPUT
  pinMode(CAMERA_POWER_PIN, OUTPUT);
  digitalWrite(CAMERA_POWER_PIN, LOW); // Start with power off
  isCameraOn = false;

  // Initialize Camera SPI
  SPI.setMISO(PB_4);
  SPI.setMOSI(PB_5);
  SPI.setSCLK(PB_3);
  SPI.begin();

  Serial.println("Lab 5.3: Mission Logic Started");

  // Initialize SD Card
  if (!sd.begin(SD_CONFIG)) {
    Serial.println("SD Card initialization failed!");
  } else {
    Serial.println("SD Card initialized.");
  }
}

void loop() {
  // Read GPS Data
  while (gps_uart.available() > 0) {
    gps.encode(gps_uart.read());
  }

  // Run Mission Logic every 5 seconds
  static unsigned long lastMissionRun = 0;
  if (millis() - lastMissionRun > 5000) {
    lastMissionRun = millis();

    // Directly assign coordinates without checking for a valid fix
    float currentLat = gps.location.lat();
    float currentLon = gps.location.lng();
    
    Serial.print("Current Location: ");
    Serial.print(currentLat, 4); Serial.print(", "); Serial.println(currentLon, 4);

    bool inTargetArea = false;

    // GPS-Gating logic
    if (currentLat >= ROI_LAT_MIN && currentLat <= ROI_LAT_MAX &&
        currentLon >= ROI_LON_MIN && currentLon <= ROI_LON_MAX) {
      inTargetArea = true;
    }

    if (inTargetArea) {
      Serial.println("Inside ROI. Executing Mission payload...");
      
      // Smart Power Management: Only boot if not already on
      if (!isCameraOn) {
        Serial.println("Powering up Camera Payload...");
        digitalWrite(CAMERA_POWER_PIN, HIGH);
        delay(2000); // Wait 2 seconds for sensor boot and auto-exposure adjustment
        myCAM.begin();
        isCameraOn = true;
      }

      // Read RTC time for Metadata
      rtc.getTime();
      
      // --- CAPTURE & SAVE IMAGE ---
      Serial.print("Taking picture... ");
      myCAM.takePicture(CAM_IMAGE_MODE_VGA, CAM_IMAGE_PIX_FMT_JPG);

      headFlag = 0;
      buffIndex = 0;
      imageData = 0;
      imageDataNext = 0;

      while (myCAM.getReceivedLength()) {
        imageData = imageDataNext;
        imageDataNext = myCAM.readByte();

        if (headFlag == 1) {
          imageBuff[buffIndex++] = imageDataNext;
          if (buffIndex >= BUFFER_SIZE) {
            file.write(imageBuff, buffIndex);
            buffIndex = 0;
          }
        }

        // Check for JPEG start (0xFF 0xD8)
        if (imageData == 0xff && imageDataNext == 0xd8) {
          headFlag = 1;
          sprintf(imageName, "IMG_%d.JPG", imageCount);
          imageCount++;
          // O_TRUNC ensures we overwrite old files completely instead of merging them
          if (!file.open(imageName, O_RDWR | O_CREAT | O_TRUNC)) {
            Serial.println("File open failed!");
            break;
          }
          imageBuff[buffIndex++] = imageData;
          imageBuff[buffIndex++] = imageDataNext;
        }

        // Check for JPEG end (0xFF 0xD9)
        if (imageData == 0xff && imageDataNext == 0xd9) {
          headFlag = 0;
          file.write(imageBuff, buffIndex);
          buffIndex = 0;
          file.close();
          Serial.print("Saved to SD card as: ");
          Serial.println(imageName);
          break;
        }
      }
      
      // --- METADATA LOGGING ---
      if (file.open("METADATA.TXT", O_RDWR | O_CREAT | O_APPEND)) {
        file.print("Time: ");
        file.print(rtc.hour); file.print(":"); file.print(rtc.minute); file.print(":"); file.print(rtc.second);
        file.print(" | Location: ");
        file.print(currentLat, 6); file.print(", "); file.print(currentLon, 6);
        file.print(" | Image: "); file.println(imageName);
        file.close();
        Serial.println("Metadata saved successfully.");
      } else {
        Serial.println("Failed to open METADATA.TXT");
      }

      Serial.println("Payload execution completed.");
      
    } else {
      // Smart Power Management: Turn off if leaving zone
      if (isCameraOn) {
        Serial.println("Outside ROI. Entering Power Save Mode.");
        digitalWrite(CAMERA_POWER_PIN, LOW);
        isCameraOn = false;
      }
    }

    runMissionTestbench(currentLat, currentLon, inTargetArea, sd, CAMERA_POWER_PIN, imageName);
  }
}