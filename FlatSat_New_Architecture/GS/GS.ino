/*
 * FlatSat New Architecture
 * Ground Station (GS) - STM32F103RC
 * Interrupt-driven AX.25 reception, RSSI injection, KISS bridge to PC.
 */

#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>

// ====================================================================
// HARDWARE PIN DEFINITIONS (STM32F103RC)
// ====================================================================

// --- SX1278 LoRa Radio (SPI1) ---
#define RADIO_SCK PA5
#define RADIO_MISO PA6
#define RADIO_MOSI PA7
#define RADIO_NSS PB6
#define RADIO_DIO0 PA10
#define RADIO_RESET PC7
#define RADIO_DIO1 -1

// --- Radio Instance ---
SX1278 radio = new Module(RADIO_NSS, RADIO_DIO0, RADIO_RESET, RADIO_DIO1, SPI);

// ====================================================================
// KISS PROTOCOL DEFINITIONS
// ====================================================================
#define FEND  0xC0
#define FESC  0xDB
#define TFEND 0xDC
#define TFESC 0xDD

// ====================================================================
// KISS FRAME BUFFER (PC -> Space direction)
// ====================================================================
uint8_t kissBuffer[256];
uint16_t kissIndex = 0;
bool inFrame = false;
bool escapeNext = false;

// ====================================================================
// INTERRUPT FLAG FOR RF RECEPTION
// ====================================================================
volatile bool receivedFlag = false;

void setFlag(void) {
  receivedFlag = true;
}

// ====================================================================
// AX.25 UI FRAME ENCAPSULATION
// ====================================================================

// For uplink: GS -> COMMU, destination is FLTSAT, source is GROUND
size_t wrapAX25(const uint8_t *payload, size_t payloadLen, uint8_t *ax25Buf) {
  size_t idx = 0;

  // Destination: "FLTSAT"
  const char* dest = "FLTSAT";
  for (int i = 0; i < 6; i++) ax25Buf[idx++] = (dest[i] << 1);
  ax25Buf[idx++] = (0 << 1); // SSID 0

  // Source: "GROUND"
  const char* src = "GROUND";
  for (int i = 0; i < 6; i++) ax25Buf[idx++] = (src[i] << 1);
  ax25Buf[idx++] = (0 << 1) | 0x01; // SSID 0, Last Address Bit

  ax25Buf[idx++] = 0x03; // Control: UI frame
  ax25Buf[idx++] = 0xF0; // PID: No layer 3 protocol

  memcpy(&ax25Buf[idx], payload, payloadLen);
  return idx + payloadLen;
}

// Extract application payload from AX.25 frame
size_t unwrapAX25(const uint8_t *ax25Buf, size_t rxLen, uint8_t *payload) {
  const size_t AX25_HEADER_LEN = 16;
  if (rxLen < AX25_HEADER_LEN) return 0;
  size_t payloadLen = rxLen - AX25_HEADER_LEN;
  memcpy(payload, &ax25Buf[AX25_HEADER_LEN], payloadLen);
  return payloadLen;
}

// ====================================================================
// KISS ENCODE HELPER
// ====================================================================
void kissEncodeAndSend(const uint8_t *data, size_t len) {
  Serial.write(FEND);
  for (size_t i = 0; i < len; i++) {
    if (data[i] == FEND) {
      Serial.write(FESC);
      Serial.write(TFEND);
    } else if (data[i] == FESC) {
      Serial.write(FESC);
      Serial.write(TFESC);
    } else {
      Serial.write(data[i]);
    }
  }
  Serial.write(FEND);
}

// ====================================================================
// SETUP
// ====================================================================
void setup() {
  // Serial to PC Bridge (KISS data channel)
  Serial.setTx(PC10);
  Serial.setRx(PC11);
  Serial.begin(115200);
  delay(2000);

  // Initialize SPI
  SPI.setMISO(RADIO_MISO);
  SPI.setMOSI(RADIO_MOSI);
  SPI.setSCLK(RADIO_SCK);
  SPI.begin();

  // Initialize SX1278
  if (radio.beginFSK() == RADIOLIB_ERR_NONE) {
    radio.setFrequency(433.0);
    radio.setBitRate(9.6);
    radio.setOutputPower(2);

    // Enable interrupt-driven reception
    radio.setDio0Action(setFlag, RISING);
    radio.startReceive();
  } else {
    while (true); // Halt on radio fail
  }
}

// ====================================================================
// MAIN LOOP
// ====================================================================
void loop() {

  // ================================================================
  // 1. RF AX.25 from Space -> Unwrap AX.25 -> KISS to PC
  // ================================================================
  if (receivedFlag) {
    receivedFlag = false;

    uint8_t rxBuffer[256];
    size_t rxSize = radio.getPacketLength();
    int state = radio.readData(rxBuffer, rxSize);

    if (state == RADIOLIB_ERR_NONE) {
      // Get signal quality from the SX1278
      float rssi = radio.getRSSI();
      float snr = radio.getSNR();

      // Extract application payload from AX.25 frame
      uint8_t rawPayload[256];
      size_t rawLen = unwrapAX25(rxBuffer, rxSize, rawPayload);

      if (rawLen > 0) {
        // Append RSSI and SNR metadata to the end of the payload
        // so the PC Bridge can extract them.
        // Format: [original app packet] [RSSI as int16, 2 bytes] [SNR as int8, 1 byte]
        int16_t rssiInt = (int16_t)(rssi * 10); // -1234 = -123.4 dBm
        int8_t snrInt = (int8_t)(snr * 10);     // 75 = 7.5 dB

        uint8_t enrichedPayload[260];
        memcpy(enrichedPayload, rawPayload, rawLen);
        enrichedPayload[rawLen]     = (rssiInt >> 8) & 0xFF;
        enrichedPayload[rawLen + 1] = rssiInt & 0xFF;
        enrichedPayload[rawLen + 2] = snrInt;

        // KISS encode and send to PC
        kissEncodeAndSend(enrichedPayload, rawLen + 3);
      }
    }
    // CRC mismatch or other errors are silently dropped

    // Resume listening
    radio.startReceive();
    receivedFlag = false; // Clear ghost interrupt from readData
  }

  // ================================================================
  // 2. KISS from PC -> Unwrap KISS -> Wrap AX.25 -> RF Transmit to Space
  // ================================================================
  while (Serial.available()) {
    uint8_t c = Serial.read();

    if (c == FEND) {
      if (inFrame && kissIndex > 0) {
        // Complete KISS frame from PC
        uint8_t ax25Buffer[300];
        size_t ax25Len = wrapAX25(kissBuffer, kissIndex, ax25Buffer);

        radio.transmit(ax25Buffer, ax25Len);

        // Resume listening after TX
        radio.startReceive();
        receivedFlag = false; // Clear ghost interrupt

        kissIndex = 0;
        inFrame = false;
        escapeNext = false;
      } else {
        inFrame = true;
        kissIndex = 0;
        escapeNext = false;
      }
    } else if (inFrame) {
      if (c == FESC) {
        escapeNext = true;
      } else if (escapeNext) {
        if (c == TFEND) kissBuffer[kissIndex++] = FEND;
        else if (c == TFESC) kissBuffer[kissIndex++] = FESC;
        escapeNext = false;
      } else {
        if (kissIndex < sizeof(kissBuffer)) {
          kissBuffer[kissIndex++] = c;
        } else {
          // Buffer overflow - discard
          inFrame = false;
          kissIndex = 0;
        }
      }
    }
  }
}
