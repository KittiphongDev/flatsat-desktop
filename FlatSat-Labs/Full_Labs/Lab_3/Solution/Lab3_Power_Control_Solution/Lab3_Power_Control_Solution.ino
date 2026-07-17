
// NBSPACE Labs: FlatSat Learning Set
// Lab 3.2: OBC Power Control (Interactive Serial Control)
// Solution Code

#include <Arduino.h>

#define PIN_COMMS      PD1
#define PIN_PAYLOAD_1  PD2
#define PIN_PAYLOAD_2  PD3 

void setup() {
  Serial.setRx(PD9);
  Serial.setTx(PD8);
  Serial.begin(115200);

  delay(4000);

  Serial.println("\n=== FlatSat Lab 3.2: Interactive Power Control ===");
  Serial.println("Type the following keys in the Serial Monitor and press Enter:");
  Serial.println("  '1' = Payload 1 ON   |  'q' = Payload 1 OFF");
  Serial.println("  '2' = Payload 2 ON   |  'w' = Payload 2 OFF");
  Serial.println("  '3' = COMMS ON       |  'e' = COMMS OFF");
  Serial.println("  '0' = Turn ALL OFF");
  Serial.println("--------------------------------------------------");

  pinMode(PIN_PAYLOAD_1, OUTPUT);
  pinMode(PIN_PAYLOAD_2, OUTPUT);
  pinMode(PIN_COMMS, OUTPUT);

  digitalWrite(PIN_PAYLOAD_1, HIGH);
  digitalWrite(PIN_PAYLOAD_2, HIGH);
  digitalWrite(PIN_COMMS, HIGH);
  Serial.println("Initial State: All Subsystems ON\n");
}

void loop() {
  // Check if any data has been typed into the Serial Monitor
  if (Serial.available() > 0) {
    char cmd = Serial.read(); // Read the first character

    // Match the character to the corresponding command
    switch (cmd) {
      // --- Payload 1 (PD2) ---
      case '1':
        digitalWrite(PIN_PAYLOAD_1, HIGH);
        Serial.println("Payload 1 (PD2) -> ON");
        break;
      case 'q':
        digitalWrite(PIN_PAYLOAD_1, LOW);
        Serial.println("Payload 1 (PD2) -> OFF");
        break;

      // --- Payload 2 (PD3) ---
      case '2':
        digitalWrite(PIN_PAYLOAD_2, HIGH);
        Serial.println("Payload 2 (PD3) -> ON");
        break;
      case 'w':
        digitalWrite(PIN_PAYLOAD_2, LOW);
        Serial.println("Payload 2 (PD3) -> OFF");
        break;

      // --- COMMS (PD1) ---
      case '3':
        digitalWrite(PIN_COMMS, HIGH);
        Serial.println("COMMS (PD1)     -> ON");
        break;
      case 'e':
        digitalWrite(PIN_COMMS, LOW);
        Serial.println("COMMS (PD1)     -> OFF");
        break;

      // --- ALL OFF ---
      case '0':
        digitalWrite(PIN_PAYLOAD_1, LOW);
        digitalWrite(PIN_PAYLOAD_2, LOW);
        digitalWrite(PIN_COMMS, LOW);
        Serial.println("All Subsystems  -> OFF");
        break;

      // Ignore standard invisible line-ending characters
      case '\n':
      case '\r':
      case ' ':
        break;

      // Handle unrecognized inputs
      default:
        Serial.println("Unknown command. Use 1/q, 2/w, 3/e, or 0.");
        break;
    }
  }
}