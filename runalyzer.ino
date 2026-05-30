#include <Wire.h>
#include <ArduinoBLE.h>

// ----------------- IMU (LSM6DS3 via raw I2C) -----------------
#define IMU_ADDR        0x6A

// LSM6DS3 registers
#define LSM6DS3_WHO_AM_I    0x0F
#define LSM6DS3_CTRL1_XL    0x10  // Accel control
#define LSM6DS3_CTRL2_G     0x11  // Gyro control
#define LSM6DS3_OUTX_L_G    0x22  // Gyro data start (6 bytes: GX, GY, GZ)
#define LSM6DS3_OUTX_L_XL   0x28  // Accel data start (6 bytes: AX, AY, AZ)

// IMU power pin — use board-defined constant
// PIN_LSM6DS3TR_C_POWER is defined in pins_arduino.h as pin 15

uint8_t imuReadReg(uint8_t reg) {
  Wire1.beginTransmission(IMU_ADDR);
  Wire1.write(reg);
  Wire1.endTransmission(false);
  Wire1.requestFrom((uint8_t)IMU_ADDR, (uint8_t)1);
  return Wire1.read();
}

void imuWriteReg(uint8_t reg, uint8_t val) {
  Wire1.beginTransmission(IMU_ADDR);
  Wire1.write(reg);
  Wire1.write(val);
  Wire1.endTransmission();
}

void imuReadBytes(uint8_t reg, uint8_t* buf, uint8_t len) {
  Wire1.beginTransmission(IMU_ADDR);
  Wire1.write(reg);
  Wire1.endTransmission(false);
  Wire1.requestFrom((uint8_t)IMU_ADDR, len);
  for (uint8_t i = 0; i < len; i++) {
    buf[i] = Wire1.read();
  }
}

bool imuBegin() {
  // Power on the IMU using high-drive GPIO (required on XIAO Sense)
  // The standard digitalWrite may not provide enough current.
  // P1_8 = port 1, pin 8 → NRF_P1->PIN_CNF[8]
  NRF_P1->PIN_CNF[8] = ((uint32_t)GPIO_PIN_CNF_DIR_Output << GPIO_PIN_CNF_DIR_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_INPUT_Disconnect << GPIO_PIN_CNF_INPUT_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_PULL_Disabled << GPIO_PIN_CNF_PULL_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_DRIVE_H0H1 << GPIO_PIN_CNF_DRIVE_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_SENSE_Disabled << GPIO_PIN_CNF_SENSE_Pos);
  NRF_P1->OUTSET = (1UL << 8);  // set P1.08 HIGH
  delay(100);  // give IMU time to boot

  Wire1.begin();
  delay(10);

  // Verify WHO_AM_I: 0x69 = LSM6DS3, 0x6A = LSM6DS3TR-C
  // Retry a few times — IMU may need extra time after power-on
  uint8_t whoami = 0;
  for (int attempt = 0; attempt < 5; attempt++) {
    whoami = imuReadReg(LSM6DS3_WHO_AM_I);
    Serial.print("IMU WHO_AM_I: 0x");
    Serial.println(whoami, HEX);
    if (whoami == 0x69 || whoami == 0x6A) break;
    delay(50);
  }
  if (whoami != 0x69 && whoami != 0x6A) {
    return false;
  }

  // CTRL1_XL: 104 Hz, ±2g, default filter
  imuWriteReg(LSM6DS3_CTRL1_XL, 0x40);
  // CTRL2_G: 104 Hz, 245 dps
  imuWriteReg(LSM6DS3_CTRL2_G, 0x40);

  return true;
}

// ----------------- BLE UUIDs -----------------
#define IMU_SERVICE_UUID        "12345678-1234-5678-1234-56789abcdef0"
#define IMU_CHARACTERISTIC_UUID "12345678-1234-5678-1234-56789abcdef1"

// ----------------- BLE Objects -----------------
BLEService imuService(IMU_SERVICE_UUID);
BLECharacteristic imuCharacteristic(IMU_CHARACTERISTIC_UUID, BLERead | BLENotify, 16);

BLEService batteryService("180F");
BLEByteCharacteristic batteryLevelChar("2A19", BLERead | BLENotify);

// ----------------- LED Pins (active LOW) -----------------
#define LED_RED   LEDR
#define LED_GREEN LEDG
#define LED_BLUE  LEDB

// ----------------- Timing -----------------
static const unsigned long IMU_INTERVAL_US  = 10000;  // 100 Hz
static const unsigned long BATT_INTERVAL_MS = 10000;  // every 10s
static const unsigned long BLINK_INTERVAL_MS = 500;

static unsigned long lastIMU_us   = 0;
static unsigned long lastBatt_ms  = 0;
static unsigned long lastBlink_ms = 0;

// ----------------- State -----------------
static bool deviceConnected = false;
static bool ledBlueOn       = false;

// ----------------- Battery -----------------
#define VBAT_PIN       PIN_VBAT        // pin 6
#define VBAT_ENABLE    PIN_VBAT_ENABLE // pin 32
#define CHG_PIN        22              // D22 = P0_17, ~CHG: LOW when charging

static const float VBAT_MIN = 3.0f;
static const float VBAT_MAX = 4.2f;

uint8_t readBatteryPercent() {
  digitalWrite(VBAT_ENABLE, HIGH);
  delay(1);
  int raw = analogRead(VBAT_PIN);
  digitalWrite(VBAT_ENABLE, LOW);

  float voltage = (raw / 4095.0f) * 3.3f * 2.0f;

  int percent = (int)((voltage - VBAT_MIN) / (VBAT_MAX - VBAT_MIN) * 100.0f);
  if (percent < 0)   percent = 0;
  if (percent > 100)  percent = 100;
  return (uint8_t)percent;
}

// -------------------------------------------------
// Helper: set RGB LED (active LOW)
// -------------------------------------------------
void setLED(bool r, bool g, bool b) {
  digitalWrite(LED_RED,   r ? LOW : HIGH);
  digitalWrite(LED_GREEN, g ? LOW : HIGH);
  digitalWrite(LED_BLUE,  b ? LOW : HIGH);
}

// -------------------------------------------------
// BLE event callbacks
// -------------------------------------------------
void onConnect(BLEDevice central) {
  deviceConnected = true;
  setLED(false, true, false);  // solid green
}

void onDisconnect(BLEDevice central) {
  deviceConnected = false;
  setLED(false, false, false);
}

// -------------------------------------------------
// setup()
// -------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(2000);  // wait for serial monitor to connect
  Serial.println("Runalyzer starting...");

  // LED init
  pinMode(LED_RED,   OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE,  OUTPUT);
  setLED(false, false, false);

  // Battery ADC init
  pinMode(VBAT_ENABLE, OUTPUT);
  digitalWrite(VBAT_ENABLE, LOW);
  analogReadResolution(12);
  pinMode(CHG_PIN, INPUT_PULLUP); // ~CHG pin: LOW = charging

  // IMU init
  if (!imuBegin()) {
    Serial.println("IMU init failed!");
    while (1) {
      setLED(true, false, false);
      delay(200);
      setLED(false, false, false);
      delay(200);
    }
  }
  Serial.println("IMU ready");

  // BLE init
  if (!BLE.begin()) {
    Serial.println("BLE init failed!");
    while (1) {
      setLED(true, false, false);
      delay(200);
      setLED(false, false, false);
      delay(200);
    }
  }

  BLE.setLocalName("Runalyzer");
  BLE.setDeviceName("Runalyzer");

  // IMU service
  imuService.addCharacteristic(imuCharacteristic);
  BLE.addService(imuService);

  // Battery service
  batteryService.addCharacteristic(batteryLevelChar);
  BLE.addService(batteryService);

  batteryLevelChar.writeValue(readBatteryPercent());

  BLE.setAdvertisedService(imuService);

  BLE.setEventHandler(BLEConnected, onConnect);
  BLE.setEventHandler(BLEDisconnected, onDisconnect);

  BLE.advertise();
  Serial.println("BLE advertising as 'Runalyzer'");

  // Send initial battery status
  uint8_t pct = readBatteryPercent();
  bool charging = (digitalRead(CHG_PIN) == LOW);
  Serial.print("BAT,");
  Serial.print(pct);
  Serial.print(',');
  Serial.println(charging ? 1 : 0);

  lastIMU_us   = micros();
  lastBatt_ms  = millis();
  lastBlink_ms = millis();
}

// -------------------------------------------------
// loop()
// -------------------------------------------------
void loop() {
  BLE.poll();

  unsigned long now_us = micros();
  unsigned long now_ms = millis();

  // --- IMU at 100 Hz ---
  if (now_us - lastIMU_us >= IMU_INTERVAL_US) {
    lastIMU_us += IMU_INTERVAL_US;

    // Read accel (6 bytes) and gyro (6 bytes) raw data
    uint8_t accelData[6];
    uint8_t gyroData[6];
    imuReadBytes(LSM6DS3_OUTX_L_XL, accelData, 6);
    imuReadBytes(LSM6DS3_OUTX_L_G, gyroData, 6);

    int16_t ax = (int16_t)(accelData[0] | (accelData[1] << 8));
    int16_t ay = (int16_t)(accelData[2] | (accelData[3] << 8));
    int16_t az = (int16_t)(accelData[4] | (accelData[5] << 8));
    int16_t gx = (int16_t)(gyroData[0] | (gyroData[1] << 8));
    int16_t gy = (int16_t)(gyroData[2] | (gyroData[3] << 8));
    int16_t gz = (int16_t)(gyroData[4] | (gyroData[5] << 8));

    // Stream CSV over serial: timestamp,ax,ay,az,gx,gy,gz
    Serial.print(now_ms);
    Serial.print(','); Serial.print(ax);
    Serial.print(','); Serial.print(ay);
    Serial.print(','); Serial.print(az);
    Serial.print(','); Serial.print(gx);
    Serial.print(','); Serial.print(gy);
    Serial.print(','); Serial.println(gz);

    // BLE notify if connected
    if (deviceConnected && imuCharacteristic.subscribed()) {
      uint8_t buf[16];
      uint32_t ts = (uint32_t)now_ms;
      buf[0] = ts & 0xFF;
      buf[1] = (ts >> 8) & 0xFF;
      buf[2] = (ts >> 16) & 0xFF;
      buf[3] = (ts >> 24) & 0xFF;
      memcpy(&buf[4], accelData, 6);
      memcpy(&buf[10], gyroData, 6);
      imuCharacteristic.writeValue(buf, 16);
    }
  }

  // --- Battery every 10s ---
  if (now_ms - lastBatt_ms >= BATT_INTERVAL_MS) {
    lastBatt_ms = now_ms;
    uint8_t pct = readBatteryPercent();
    bool charging = (digitalRead(CHG_PIN) == LOW);
    batteryLevelChar.writeValue(pct);
    // Send battery status over serial: BAT,percent,charging
    Serial.print("BAT,");
    Serial.print(pct);
    Serial.print(',');
    Serial.println(charging ? 1 : 0);
  }

  // --- LED blink when advertising ---
  if (!deviceConnected) {
    if (now_ms - lastBlink_ms >= BLINK_INTERVAL_MS) {
      lastBlink_ms = now_ms;
      ledBlueOn = !ledBlueOn;
      setLED(false, false, ledBlueOn);
    }
  }
}
