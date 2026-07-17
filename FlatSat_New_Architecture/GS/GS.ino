#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>

// ====================================================================
// HARDWARE PIN DEFINITIONS (STM32F103RC)
// ====================================================================
#define RADIO_SCK PA5
#define RADIO_MISO PA6
#define RADIO_MOSI PA7
#define RADIO_NSS PB6
#define RADIO_DIO0 PA10
#define RADIO_RESET PC7
#define RADIO_DIO1 -1

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

volatile bool receivedFlag = false;

void setFlag(void) {
  receivedFlag = true;
}

// ====================================================================
// SETUP
// ====================================================================
void setup() {
  Serial.setTx(PC10);
  Serial.setRx(PC11);
  Serial.begin(115200); // UART to PC Bridge
  delay(2000);
  
  SPI.setMISO(RADIO_MISO);
  SPI.setMOSI(RADIO_MOSI);
  SPI.setSCLK(RADIO_SCK);
  SPI.begin();

  if (radio.beginFSK() == RADIOLIB_ERR_NONE) {
    radio.setFrequency(433.0);
    radio.setBitRate(9.6);
    radio.setOutputPower(2);
    radio.setDio0Action(setFlag, RISING);
    radio.startReceive();
  } else {
    while (true); // Halt on radio fail
  }
}

// ====================================================================
// AX.25 UI FRAME ENCAPSULATION
// ====================================================================
size_t wrapAX25(const uint8_t *payload, size_t payloadLen, uint8_t *ax25Buf) {
  size_t idx = 0;
  const char* dest = "FLTSAT";
  for(int i=0; i<6; i++) ax25Buf[idx++] = (dest[i] << 1);
  ax25Buf[idx++] = (0 << 1);
  const char* src = "GROUND";
  for(int i=0; i<6; i++) ax25Buf[idx++] = (src[i] << 1);
  ax25Buf[idx++] = (0 << 1) | 0x01;
  ax25Buf[idx++] = 0x03;
  ax25Buf[idx++] = 0xF0;
  memcpy(&ax25Buf[idx], payload, payloadLen);
  return idx + payloadLen;
}

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
  // 1. Interrupt-driven RF AX.25 Reception -> KISS to PC
  if (receivedFlag) {
    receivedFlag = false;
    
    uint8_t rxBuffer[256];
    size_t rxSize = radio.getPacketLength();
    int state = radio.readData(rxBuffer, rxSize);
    
    if (state == RADIOLIB_ERR_NONE) {
      uint8_t rawPayload[256];
      size_t rawLen = unwrapAX25(rxBuffer, rxSize, rawPayload);
      
      if (rawLen > 0) {
        // Send KISS down Serial to PC
        Serial.write(FEND);
        for(size_t i=0; i<rawLen; i++) {
          if (rawPayload[i] == FEND) {
            Serial.write(FESC); Serial.write(TFEND);
          } else if (rawPayload[i] == FESC) {
            Serial.write(FESC); Serial.write(TFESC);
          } else {
            Serial.write(rawPayload[i]);
          }
        }
        Serial.write(FEND);
      }
    }
    radio.startReceive();
  }

  // 2. Poll UART for KISS from PC -> AX.25 to Space
  while (Serial.available()) {
    uint8_t c = Serial.read();
    
    if (c == FEND) {
      if (inFrame && kissIndex > 0) {
        uint8_t ax25Buffer[300];
        size_t ax25Len = wrapAX25(kissBuffer, kissIndex, ax25Buffer);
        
        radio.transmit(ax25Buffer, ax25Len);
        radio.startReceive();
        
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
}
