/*
 * FlatSat New Architecture
 * Communication Relay Module (COMMU) - STM32F411RE
 * Transparent KISS <-> AX.25 bridge with RSSI/SNR injection.
 */

#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>

// ====================================================================
// HARDWARE PIN DEFINITIONS (STM32F411RE - Nucleo-64)
// ====================================================================

// --- SX1278 LoRa Radio (SPI1) ---
#define RADIO_SCK PA5
#define RADIO_MISO PA6
#define RADIO_MOSI PA7
#define RADIO_NSS PB6
#define RADIO_DIO0 PA10
#define RADIO_RESET PC7
#define RADIO_DIO1 -1

// --- UART to OBC ---
HardwareSerial ObcUART(PA12, PA11);

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
// KISS FRAME BUFFER (OBC -> Space direction)
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

// Builds a minimal AX.25 Unnumbered Information (UI) frame
// Header: Destination(7) + Source(7) + Control(1) + PID(1) = 16 bytes
size_t wrapAX25(const uint8_t *payload, size_t payloadLen, uint8_t *ax25Buf) {
  size_t idx = 0;

  // Destination callsign: "GROUND" (6 chars, each shifted left 1 bit)
  const char* dest = "GROUND";
  for (int i = 0; i < 6; i++) ax25Buf[idx++] = (dest[i] << 1);
  ax25Buf[idx++] = (0 << 1); // SSID 0

  // Source callsign: "FLTSAT" (6 chars, each shifted left 1 bit)
  const char* src = "FLTSAT";
  for (int i = 0; i < 6; i++) ax25Buf[idx++] = (src[i] << 1);
  ax25Buf[idx++] = (0 << 1) | 0x01; // SSID 0, Last Address Bit set

  ax25Buf[idx++] = 0x03; // Control: UI frame
  ax25Buf[idx++] = 0xF0; // PID: No layer 3 protocol

  // Copy application payload
  memcpy(&ax25Buf[idx], payload, payloadLen);
  return idx + payloadLen;
}

// Extracts application payload from AX.25 frame (strips 16-byte header)
size_t unwrapAX25(const uint8_t *ax25Buf, size_t rxLen, uint8_t *payload) {
  const size_t AX25_HEADER_LEN = 16;
  if (rxLen < AX25_HEADER_LEN) return 0;
  size_t payloadLen = rxLen - AX25_HEADER_LEN;
  memcpy(payload, &ax25Buf[AX25_HEADER_LEN], payloadLen);
  return payloadLen;
}

// Helper: KISS-encode and write to a HardwareSerial port
void kissEncodeAndSend(HardwareSerial &port, const uint8_t *data, size_t len) {
  port.write(FEND);
  for (size_t i = 0; i < len; i++) {
    if (data[i] == FEND) {
      port.write(FESC);
      port.write(TFEND);
    } else if (data[i] == FESC) {
      port.write(FESC);
      port.write(TFESC);
    } else {
      port.write(data[i]);
    }
  }
  port.write(FEND);
}

// ====================================================================
// SETUP
// ====================================================================
void setup() {
  Serial.begin(115200); // Debug to PC USB
  ObcUART.begin(115200);
  delay(2000);

  Serial.println("\n=== FlatSat COMMU: Radio Relay ===");
  Serial.println("[SYSTEM] STM32F411RE Initializing...");

  // Flush phantom UART data from power-on transients
  delay(500);
  while (ObcUART.available()) ObcUART.read();

  // Initialize SPI for Radio
  SPI.setMISO(RADIO_MISO);
  SPI.setMOSI(RADIO_MOSI);
  SPI.setSCLK(RADIO_SCK);
  SPI.begin();

  // Initialize SX1278 in FSK mode
  Serial.print("[SYSTEM] Initializing RF Module... ");
  if (radio.beginFSK() == RADIOLIB_ERR_NONE) {
    radio.setFrequency(433.0);
    radio.setBitRate(9.6);
    radio.setOutputPower(2); // Low power to prevent near-field overload

    // Enable interrupt-driven reception
    radio.setDio0Action(setFlag, RISING);
    radio.startReceive();

    Serial.println("OK!");
    Serial.println("[SYSTEM] RF Interrupt enabled. Listening...");
  } else {
    Serial.println("FAILED!");
    while (true); // Halt on radio fail
  }

  Serial.println("[SYSTEM] COMMU Ready.");
}

// ====================================================================
// MAIN LOOP
// ====================================================================
void loop() {

  // ================================================================
  // 1. UART KISS from OBC -> Unwrap KISS -> Wrap AX.25 -> RF Transmit
  // ================================================================
  while (ObcUART.available()) {
    uint8_t c = ObcUART.read();

    if (c == FEND) {
      if (inFrame && kissIndex > 0) {
        // Complete KISS frame received from OBC
        // kissBuffer now contains the raw application packet
        uint8_t ax25Buffer[300];
        size_t ax25Len = wrapAX25(kissBuffer, kissIndex, ax25Buffer);

        Serial.print("[RELAY UP] OBC->Space: ");
        Serial.print(kissIndex);
        Serial.print(" bytes -> AX.25 ");
        Serial.print(ax25Len);
        Serial.print(" bytes... ");

        int txState = radio.transmit(ax25Buffer, ax25Len);
        if (txState == RADIOLIB_ERR_NONE) {
          Serial.println("TX OK");
        } else {
          Serial.print("TX Error: ");
          Serial.println(txState);
        }

        // Resume listening after transmit
        radio.startReceive();
        receivedFlag = false; // Clear ghost interrupt from TX

        kissIndex = 0;
        inFrame = false;
        escapeNext = false;
      } else {
        // Start of new KISS frame
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
          // Buffer overflow - discard frame
          inFrame = false;
          kissIndex = 0;
          Serial.println("[ERROR] KISS RX buffer overflow from OBC");
        }
      }
    }
  }

  // ================================================================
  // 2. RF AX.25 from GS -> Unwrap AX.25 -> Wrap KISS -> UART to OBC
  // ================================================================
  if (receivedFlag) {
    receivedFlag = false;

    uint8_t rxBuffer[256];
    size_t rxSize = radio.getPacketLength();
    int state = radio.readData(rxBuffer, rxSize);

    if (state == RADIOLIB_ERR_NONE) {
      // Get signal quality metrics
      float rssi = radio.getRSSI();
      float snr = radio.getSNR();

      Serial.print("[RELAY DOWN] Space->OBC: AX.25 ");
      Serial.print(rxSize);
      Serial.print(" bytes, RSSI=");
      Serial.print(rssi);
      Serial.print(" dBm, SNR=");
      Serial.print(snr);
      Serial.print(" dB... ");

      // Extract application payload from AX.25
      uint8_t rawPayload[256];
      size_t rawLen = unwrapAX25(rxBuffer, rxSize, rawPayload);

      if (rawLen > 0) {
        // KISS encode and forward to OBC
        kissEncodeAndSend(ObcUART, rawPayload, rawLen);
        Serial.print("Forwarded ");
        Serial.print(rawLen);
        Serial.println(" bytes to OBC");
      } else {
        Serial.println("AX.25 unwrap failed (too short)");
      }
    } else if (state == RADIOLIB_ERR_CRC_MISMATCH) {
      Serial.println("[WARNING] RF CRC Mismatch! Bad signal.");
    } else {
      Serial.print("[WARNING] RF Read error: ");
      Serial.println(state);
    }

    // Resume listening
    radio.startReceive();
    receivedFlag = false; // Clear any ghost interrupt
  }
}
