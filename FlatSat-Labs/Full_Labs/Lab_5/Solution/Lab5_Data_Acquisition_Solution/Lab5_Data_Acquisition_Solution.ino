// NBSPACE Labs: FlatSat Learning Set
// Lab 5.1: Data Acquisition (GPS & RTC)
// Solution Code

HardwareSerial gps_uart(PE0,PE1);
void setup(){
    gps_uart.begin(9600);
    Serial.setTx(PD8);
    Serial.setRx(PD9);
    Serial.begin(115200);
    delay(4000);
    Serial.println("Hello from OBC!");
}

void loop(){
    while (gps_uart.available()){
        char c = gps_uart.read();
        Serial.write(c);
    }
}