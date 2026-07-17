#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>

// ====================================================================
// HARDWARE PIN DEFINITIONS (STM32F411RE - Nucleo-64)
// ====================================================================
#define RADIO_SCK PA5
#define RADIO_MISO PA6
#define RADIO_MOSI PA7
#define RADIO_NSS PB6
#define RADIO_DIO0 PA10
#define RADIO_RESET PC7
#define RADIO_DIO1 -1

HardwareSerial ObcUART(PA12, PA11); // UART to OBC
SX1278 radio = new Module(RADIO_NSS, RADIO_DIO0, RADIO_RESET, RADIO_DIO1, SPI);

// ====================================================================
// KISS PROTOCOL DEFINITIONS
// ====================================================================
#define FEND 0xC0
#define FESC 0xDB
#define TFEND 0xDC
#define TFESC 0xDD

uint8_t kissBuffer[256];
uint16_t kissIndex = 0;
bool inFrame = false;
bool escapeNext = false;

// ====================================================================
// SETUP
// ====================================================================
void setup() {
  Serial.begin(115200); // Debug to PC USB
  ObcUART.begin(115200);
  delay(2000);
  
  SPI.setMISO(RADIO_MISO);
  SPI.setMOSI(RADIO_MOSI);
  SPI.setSCLK(RADIO_SCK);
  SPI.begin();

  if (radio.beginFSK() == RADIOLIB_ERR_NONE) {
    radio.setFrequency(433.0);
    radio.setBitRate(9.6);
    radio.setOutputPower(2);
  } else {
    while (true); // Halt on radio fail
  }
}

// ====================================================================
// AX.25 UI FRAME ENCAPSULATION
// ====================================================================
// Builds a minimal AX.25 Unnumbered Information (UI) frame
size_t wrapAX25(const uint8_t *payload, size_t payloadLen, uint8_t *ax25Buf) {
  size_t idx = 0;
  // Destination: "GROUND"
  const char* dest = "GROUND";
  for(int i=0; i<6; i++) ax25Buf[idx++] = (dest[i] << 1);
  ax25Buf[idx++] = (0 << 1); // SSID 0
  
  // Source: "FLTSAT"
  const char* src = "FLTSAT";
  for(int i=0; i<6; i++) ax25Buf[idx++] = (src[i] << 1);
  ax25Buf[idx++] = (0 << 1) | 0x01; // SSID 0, Last Address Bit
  
  ax25Buf[idx++] = 0x03; // Control (UI)
  ax25Buf[idx++] = 0xF0; // PID (No layer 3 protocol)
  
  memcpy(&ax25Buf[idx], payload, payloadLen);
  return idx + payloadLen;
}

// Minimal AX.25 payload extractor
size_t unwrapAX25(const uint8_t *ax25Buf, size_t rxLen, uint8_t *payload) {
  if (rxLen < 16) return 0;
  size_t headerLen = 16;
  size_t payloadLen = rxLen - headerLen;
  memcpy(payload, &ax25Buf[headerLen], payloadLen);
  return payloadLen;
}

// ====================================================================
// MAIN LOOP
// ====================================================================
void loop() {
  // 1. Listen for KISS from OBC -> Send via RF AX.25
  while (ObcUART.available()) {
    uint8_t c = ObcUART.read();
    
    if (c == FEND) {
      if (inFrame && kissIndex > 0) {
        // We have a fully unwrapped raw application packet in kissBuffer
        uint8_t ax25Buffer[300];
        size_t ax25Len = wrapAX25(kissBuffer, kissIndex, ax25Buffer);
        
        radio.transmit(ax25Buffer, ax25Len);
        radio.startReceive(); // Go back to listening
        
        kissIndex = 0;
        inFrame = false;
      } else {
        inFrame = true;
      }
    } else if (inFrame) {
      if (c == FESC) {
        escapeNext = true;
      } else if (escapeNext) {
        if (c == TFEND) kissBuffer[kissIndex++] = FEND;
        else if (c == TFESC) kissBuffer[kissIndex++] = FESC;
        escapeNext = false;
      } else {
        kissBuffer[kissIndex++] = c;
      }
    }
  }

  // 2. Listen for RF AX.25 from GS -> Send via KISS to OBC
  String rxStr;
  if (radio.receive(rxStr) == RADIOLIB_ERR_NONE) {
    uint8_t ax25Rx[300];
    memcpy(ax25Rx, rxStr.c_str(), rxStr.length());
    
    uint8_t rawPayload[256];
    size_t rawLen = unwrapAX25(ax25Rx, rxStr.length(), rawPayload);
    
    if (rawLen > 0) {
      // Encode back to KISS and send to OBC
      ObcUART.write(FEND);
      for(size_t i=0; i<rawLen; i++) {
        if (rawPayload[i] == FEND) {
          ObcUART.write(FESC); ObcUART.write(TFEND);
        } else if (rawPayload[i] == FESC) {
          ObcUART.write(FESC); ObcUART.write(TFESC);
        } else {
          ObcUART.write(rawPayload[i]);
        }
      }
      ObcUART.write(FEND);
    }
  }
}
