// NBSPACE Labs: FlatSat Learning Set
// Lab 1.3: Timestamp Integration
// Solution Code

#include <Wire.h>
#include <PCF85063TP.h>

TwoWire I2C_EPS(PF0, PF1);
PCD85063TP rtc;

#define TMP102_ADDRESS 0x49

const int UPLOAD_DELAY_SECONDS = 11;

void syncToCompileTimeWithOffset() {

  char monthStr[4];
  int day, year, hour, minute, second;

  sscanf(__DATE__, "%s %d %d", monthStr, &day, &year);
  sscanf(__TIME__, "%d:%d:%d", &hour, &minute, &second);

  second += UPLOAD_DELAY_SECONDS;

  while (second >= 60) {
    second -= 60;
    minute++;
  } 

  while (minute >= 60) {
    minute -= 60;
    hour++;
  }

  while (hour >= 24) {
    hour -= 24;
    day++;
  }

  int month = 1;

  const char* months[] = {
    "Jan","Feb","Mar","Apr","May","Jun",
    "Jul","Aug","Sep","Oct","Nov","Dec"
  };

  for (int i = 0; i < 12; i++) {
    if (strcmp(monthStr, months[i]) == 0) {
      month = i + 1;
      break;
    }
  }

  rtc.getTime();
  int c_year = year - 2000;
  bool needsSync = false;

  // Only sync if the compile time is newer than the RTC's current time
  if (rtc.year < c_year) needsSync = true;
  else if (rtc.year == c_year) {
    if (rtc.month < month) needsSync = true;
    else if (rtc.month == month) {
      if (rtc.dayOfMonth < day) needsSync = true;     // FIXED HERE
      else if (rtc.dayOfMonth == day) {               // FIXED HERE
        if (rtc.hour < hour) needsSync = true;
        else if (rtc.hour == hour) {
          if (rtc.minute <= minute) needsSync = true;
        }
      }
    }
  }

  if (!needsSync) {
    Serial.println("RTC time is up-to-date. Skipping compile-time sync.");
    return;
  }

  int y = year;
  int m = month;

  if (m < 3) {
    m += 12;
    y--;
  }

  int dow =
      (day +
       13 * (m + 1) / 5 +
       (y % 100) +
       (y % 100) / 4 +
       (y / 100) / 4 +
       5 * (y / 100)) % 7;

  dow = (dow + 6) % 7;

  rtc.stopClock();

  rtc.fillByYMD(year - 2000, month, day);
  rtc.fillByHMS(hour, minute, second);
  rtc.fillDayOfWeek(dow);

  rtc.setTime();

  rtc.startClock();

  Serial.println("RTC synced from compile time");
}

void setup() {

  Serial.setRx(PD9);
  Serial.setTx(PD8);
  Serial.begin(115200);

  delay(4000);

  I2C_EPS.begin();

  Wire.setSDA(PB9);
  Wire.setSCL(PB8);
  Wire.begin();

  rtc.begin();

  syncToCompileTimeWithOffset();

  Serial.println("OBC Telemetry System Started...");
}

void loop() {

  rtc.getTime();

  int h = rtc.hour;
  int m = rtc.minute;
  int s = rtc.second;

  float boardTemp = 0.0;

  Wire.requestFrom(TMP102_ADDRESS, 2);

  if (Wire.available() == 2) {

    byte msb = Wire.read();
    byte lsb = Wire.read();

    int tempRaw = ((msb << 8) | lsb) >> 4;

    boardTemp = tempRaw * 0.0625f;
  }

  String telemetryPacket = "[";

  if (h < 10) telemetryPacket += "0";
  telemetryPacket += String(h);

  telemetryPacket += ":";

  if (m < 10) telemetryPacket += "0";
  telemetryPacket += String(m);

  telemetryPacket += ":";

  if (s < 10) telemetryPacket += "0";
  telemetryPacket += String(s);

  telemetryPacket += "] OBC Temperature: ";
  telemetryPacket += String(boardTemp, 2);
  telemetryPacket += " °C";

  Serial.println(telemetryPacket);

  delay(1000);
}