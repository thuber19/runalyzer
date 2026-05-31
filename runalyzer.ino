// Runalyzer v3 — Store & Sync Firmware
// Seeed XIAO nRF52840 Sense
// Records 6-axis IMU to onboard QSPI flash, syncs to phone via BLE

#include <Wire.h>
#include <ArduinoBLE.h>

// ===================== IMU (LSM6DS3TR-C via I2C on Wire1) =====================

#define IMU_ADDR         0x6A
#define LSM6DS3_WHO_AM_I 0x0F
#define LSM6DS3_CTRL1_XL 0x10
#define LSM6DS3_CTRL2_G  0x11
#define LSM6DS3_OUTX_L_G 0x22
#define LSM6DS3_OUTX_L_XL 0x28

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
  for (uint8_t i = 0; i < len; i++) buf[i] = Wire1.read();
}

bool imuBegin() {
  // Power on IMU — requires high-drive GPIO on P1.08
  NRF_P1->PIN_CNF[8] = ((uint32_t)GPIO_PIN_CNF_DIR_Output << GPIO_PIN_CNF_DIR_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_INPUT_Disconnect << GPIO_PIN_CNF_INPUT_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_PULL_Disabled << GPIO_PIN_CNF_PULL_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_DRIVE_H0H1 << GPIO_PIN_CNF_DRIVE_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_SENSE_Disabled << GPIO_PIN_CNF_SENSE_Pos);
  NRF_P1->OUTSET = (1UL << 8);
  delay(100);

  Wire1.begin();
  delay(10);

  // Verify WHO_AM_I (0x69=LSM6DS3, 0x6A=LSM6DS3TR-C)
  uint8_t whoami = 0;
  for (int i = 0; i < 5; i++) {
    whoami = imuReadReg(LSM6DS3_WHO_AM_I);
    if (whoami == 0x69 || whoami == 0x6A) break;
    delay(50);
  }
  if (whoami != 0x69 && whoami != 0x6A) return false;

  imuWriteReg(LSM6DS3_CTRL1_XL, 0x40);  // 104 Hz, ±2g
  imuWriteReg(LSM6DS3_CTRL2_G, 0x40);   // 104 Hz, ±245 dps
  return true;
}

// ===================== QSPI Flash (nRF52840 HAL) =====================
// P25Q16H: 2MB, 4KB sectors, 256-byte pages

#define FLASH_SIZE        (2 * 1024 * 1024)
#define FLASH_PAGE_SIZE   256
#define FLASH_SECTOR_SIZE 4096
#define HEADER_SECTOR     0
#define DATA_START        4096
#define SAMPLE_SIZE       16        // 4B timestamp + 6×2B axes
#define HEADER_MAGIC      0x524E4C59  // "RNLY"

struct FlashHeader {
  uint32_t magic;
  uint32_t sampleCount;
  uint32_t sampleRateHz;
  uint32_t recordingStartMs;
  uint32_t recordingEndMs;
  uint8_t  isRecording;
  uint8_t  hasData;
  uint8_t  reserved[2];
};

static FlashHeader header;
static uint32_t maxSamples = 0;
static uint32_t lastErasedSector = 0xFFFFFFFF;

#define WRITE_BUF_SAMPLES 256  // 256 × 16 = 4KB = 1 sector
static uint8_t writeBuf[WRITE_BUF_SAMPLES * SAMPLE_SIZE];
static uint32_t writeBufCount = 0;

bool qspiInit() {
  NRF_QSPI->PSEL.SCK = P0_21;
  NRF_QSPI->PSEL.CSN = P0_25;
  NRF_QSPI->PSEL.IO0 = P0_20;
  NRF_QSPI->PSEL.IO1 = P0_24;
  NRF_QSPI->PSEL.IO2 = P0_22;
  NRF_QSPI->PSEL.IO3 = P0_23;
  NRF_QSPI->IFCONFIG0 = 0;
  NRF_QSPI->IFCONFIG1 = (1 << 25) | (15 << 0);  // MODE0, 2MHz
  NRF_QSPI->ENABLE = 1;
  NRF_QSPI->TASKS_ACTIVATE = 1;
  while (!NRF_QSPI->EVENTS_READY);
  NRF_QSPI->EVENTS_READY = 0;
  return true;
}

void qspiRead(uint32_t addr, void* buf, uint32_t len) {
  NRF_QSPI->READ.DST = (uint32_t)buf;
  NRF_QSPI->READ.SRC = addr;
  NRF_QSPI->READ.CNT = len;
  NRF_QSPI->EVENTS_READY = 0;
  NRF_QSPI->TASKS_READSTART = 1;
  while (!NRF_QSPI->EVENTS_READY);
  NRF_QSPI->EVENTS_READY = 0;
}

void qspiWrite(uint32_t addr, const void* buf, uint32_t len) {
  NRF_QSPI->WRITE.DST = addr;
  NRF_QSPI->WRITE.SRC = (uint32_t)buf;
  NRF_QSPI->WRITE.CNT = len;
  NRF_QSPI->EVENTS_READY = 0;
  NRF_QSPI->TASKS_WRITESTART = 1;
  while (!NRF_QSPI->EVENTS_READY);
  NRF_QSPI->EVENTS_READY = 0;
}

void qspiEraseSector(uint32_t addr) {
  NRF_QSPI->ERASE.PTR = addr;
  NRF_QSPI->ERASE.LEN = 0;  // 0 = 4KB sector
  NRF_QSPI->EVENTS_READY = 0;
  NRF_QSPI->TASKS_ERASESTART = 1;
  while (!NRF_QSPI->EVENTS_READY);
  NRF_QSPI->EVENTS_READY = 0;
}

void flashWriteHeader() {
  qspiEraseSector(HEADER_SECTOR);
  __attribute__((aligned(4))) FlashHeader tmp;
  memcpy(&tmp, &header, sizeof(header));
  qspiWrite(HEADER_SECTOR, &tmp, sizeof(tmp));
}

bool flashInit() {
  if (!qspiInit()) return false;
  maxSamples = (FLASH_SIZE - DATA_START) / SAMPLE_SIZE;

  __attribute__((aligned(4))) FlashHeader tmp;
  qspiRead(HEADER_SECTOR, &tmp, sizeof(tmp));
  memcpy(&header, &tmp, sizeof(header));

  if (header.magic != HEADER_MAGIC) {
    memset(&header, 0, sizeof(header));
    header.magic = HEADER_MAGIC;
    header.sampleRateHz = 25;
    flashWriteHeader();
  }
  Serial.print("Flash: "); Serial.print(header.sampleCount);
  Serial.print(" samples, "); Serial.print(header.sampleRateHz);
  Serial.print(" Hz, max="); Serial.println(maxSamples);
  return true;
}

void flashFlushBuffer() {
  if (writeBufCount == 0) return;
  uint32_t writeOffset = DATA_START + (header.sampleCount * SAMPLE_SIZE);
  uint32_t writeSize = writeBufCount * SAMPLE_SIZE;

  uint32_t startSector = writeOffset & ~(FLASH_SECTOR_SIZE - 1);
  uint32_t endSector = (writeOffset + writeSize - 1) & ~(FLASH_SECTOR_SIZE - 1);
  for (uint32_t s = startSector; s <= endSector; s += FLASH_SECTOR_SIZE) {
    if (s != lastErasedSector) {
      qspiEraseSector(s);
      lastErasedSector = s;
    }
  }

  uint32_t off = 0;
  while (off < writeSize) {
    uint32_t chunk = min((uint32_t)FLASH_PAGE_SIZE, writeSize - off);
    uint32_t aligned = (chunk + 3) & ~3;
    __attribute__((aligned(4))) uint8_t buf[FLASH_PAGE_SIZE];
    memcpy(buf, &writeBuf[off], chunk);
    if (aligned > chunk) memset(&buf[chunk], 0xFF, aligned - chunk);
    qspiWrite(writeOffset + off, buf, aligned);
    off += chunk;
  }

  header.sampleCount += writeBufCount;
  writeBufCount = 0;
}

void flashAddSample(uint32_t ts, int16_t ax, int16_t ay, int16_t az,
                    int16_t gx, int16_t gy, int16_t gz) {
  if (header.sampleCount + writeBufCount >= maxSamples) return;
  uint8_t* p = &writeBuf[writeBufCount * SAMPLE_SIZE];
  p[0] = ts; p[1] = ts >> 8; p[2] = ts >> 16; p[3] = ts >> 24;
  p[4] = ax; p[5] = ax >> 8; p[6] = ay; p[7] = ay >> 8;
  p[8] = az; p[9] = az >> 8; p[10] = gx; p[11] = gx >> 8;
  p[12] = gy; p[13] = gy >> 8; p[14] = gz; p[15] = gz >> 8;
  writeBufCount++;
  if (writeBufCount >= WRITE_BUF_SAMPLES) flashFlushBuffer();
}

void flashEraseData() {
  header.sampleCount = 0;
  header.recordingStartMs = 0;
  header.recordingEndMs = 0;
  header.isRecording = 0;
  header.hasData = 0;
  lastErasedSector = 0xFFFFFFFF;
  flashWriteHeader();
}

// ===================== BLE Service & Characteristics =====================

#define IMU_SERVICE_UUID   "12345678-1234-5678-1234-56789abcdef0"
#define IMU_CHAR_UUID      "12345678-1234-5678-1234-56789abcdef1"  // live stream
#define CONTROL_CHAR_UUID  "12345678-1234-5678-1234-56789abcdef2"  // commands
#define STATUS_CHAR_UUID   "12345678-1234-5678-1234-56789abcdef3"  // device status
#define DOWNLOAD_CHAR_UUID "12345678-1234-5678-1234-56789abcdef4"  // download chunks
#define CONFIG_CHAR_UUID   "12345678-1234-5678-1234-56789abcdef5"  // sample rate

// Commands: 1=start, 2=stop, 3=erase, 4=begin download, 5=next chunk
// Status byte 0: 0=idle, 1=recording, 2=hasData, 3=downloading

BLEService imuService(IMU_SERVICE_UUID);
BLECharacteristic imuChar(IMU_CHAR_UUID, BLERead | BLENotify, 16);
BLEByteCharacteristic controlChar(CONTROL_CHAR_UUID, BLEWrite);
BLECharacteristic statusChar(STATUS_CHAR_UUID, BLERead | BLENotify, 20);
BLECharacteristic downloadChar(DOWNLOAD_CHAR_UUID, BLERead | BLENotify, 240);
BLEByteCharacteristic configChar(CONFIG_CHAR_UUID, BLERead | BLEWrite);

BLEService battService("180F");
BLEByteCharacteristic battChar("2A19", BLERead | BLENotify);

// ===================== Battery =====================

#define VBAT_PIN    PIN_VBAT
#define VBAT_ENABLE PIN_VBAT_ENABLE
#define CHG_PIN     22

static uint8_t cachedBattPct = 0;

uint8_t readBatteryPercent() {
  digitalWrite(VBAT_ENABLE, HIGH);
  delay(1);
  int raw = analogRead(VBAT_PIN);
  digitalWrite(VBAT_ENABLE, LOW);
  int pct = (int)(((raw / 4095.0f) * 3.3f * 2.0f - 3.0f) / 1.2f * 100.0f);
  return (uint8_t)constrain(pct, 0, 100);
}

// ===================== LED =====================

void setLED(bool r, bool g, bool b) {
  digitalWrite(LEDR, r ? LOW : HIGH);
  digitalWrite(LEDG, g ? LOW : HIGH);
  digitalWrite(LEDB, b ? LOW : HIGH);
}

// ===================== Runtime State =====================

static bool bleConnected = false;
static bool isRecording = false;
static bool isDownloading = false;
static uint32_t downloadOffset = 0;
static bool ledToggle = false;

static unsigned long lastSample_us = 0;
static unsigned long lastBatt_ms = 0;
static unsigned long lastBlink_ms = 0;
static unsigned long lastStatus_ms = 0;
static unsigned long lastFlush_ms = 0;
static unsigned long sampleInterval_us = 40000;  // recalculated from sampleRateHz

// ===================== BLE Callbacks =====================

void onConnect(BLEDevice central) {
  bleConnected = true;
  // Flush any buffered samples from disconnected recording
  if (isRecording && writeBufCount > 0) {
    flashFlushBuffer();
    flashWriteHeader();
  }
  // Mark data available if we have samples and aren't recording
  if (header.sampleCount > 0 && !isRecording) {
    header.hasData = 1;
    flashWriteHeader();
  }
}

void onDisconnect(BLEDevice central) {
  bleConnected = false;
  isDownloading = false;
}

// ===================== Status Reporting =====================

void updateStatus() {
  // [0]     state: 0=idle 1=recording 2=hasData 3=downloading
  // [1-4]   sampleCount (LE)
  // [5]     sampleRateHz
  // [6]     batteryPercent
  // [7]     isCharging
  // [8-11]  maxSamples (LE)
  // [12-15] durationSec (LE)
  uint8_t buf[20] = {0};

  if (isDownloading)                              buf[0] = 3;
  else if (isRecording)                           buf[0] = 1;
  else if (header.hasData && header.sampleCount)  buf[0] = 2;

  uint32_t sc = header.sampleCount + writeBufCount;
  buf[1] = sc; buf[2] = sc >> 8; buf[3] = sc >> 16; buf[4] = sc >> 24;
  buf[5] = (uint8_t)header.sampleRateHz;
  buf[6] = cachedBattPct;
  buf[7] = (digitalRead(CHG_PIN) == LOW && cachedBattPct > 5 && cachedBattPct < 100) ? 1 : 0;
  buf[8] = maxSamples; buf[9] = maxSamples >> 8;
  buf[10] = maxSamples >> 16; buf[11] = maxSamples >> 24;

  uint32_t dur = 0;
  if (isRecording && header.recordingStartMs)
    dur = (millis() - header.recordingStartMs) / 1000;
  else if (header.recordingEndMs > header.recordingStartMs)
    dur = (header.recordingEndMs - header.recordingStartMs) / 1000;
  buf[12] = dur; buf[13] = dur >> 8; buf[14] = dur >> 16; buf[15] = dur >> 24;

  statusChar.writeValue(buf, 20);
}

// ===================== Download (Request-Response) =====================

#define DL_SAMPLES_PER_PACKET 14  // 4 + 14*16 = 228 bytes

void sendNextDownloadChunk() {
  if (downloadOffset >= header.sampleCount) {
    uint8_t end[4] = {0xFF, 0xFF, 0xFF, 0xFF};
    downloadChar.writeValue(end, 4);
    isDownloading = false;
    Serial.print("DL done: "); Serial.println(header.sampleCount);
    updateStatus();
    return;
  }

  uint32_t remaining = header.sampleCount - downloadOffset;
  uint8_t n = min((uint32_t)DL_SAMPLES_PER_PACKET, remaining);

  uint8_t packet[240];
  packet[0] = downloadOffset; packet[1] = downloadOffset >> 8;
  packet[2] = downloadOffset >> 16; packet[3] = downloadOffset >> 24;

  __attribute__((aligned(4))) uint8_t fb[DL_SAMPLES_PER_PACKET * SAMPLE_SIZE];
  qspiRead(DATA_START + downloadOffset * SAMPLE_SIZE, fb, n * SAMPLE_SIZE);
  memcpy(&packet[4], fb, n * SAMPLE_SIZE);

  downloadChar.writeValue(packet, 4 + n * SAMPLE_SIZE);
  downloadOffset += n;
}

// ===================== Recording Control =====================

void startRecording() {
  if (isRecording || isDownloading) return;
  flashEraseData();
  header.isRecording = 1;
  header.recordingStartMs = millis();
  isRecording = true;
  sampleInterval_us = 1000000UL / header.sampleRateHz;
  Serial.print("REC @ "); Serial.print(header.sampleRateHz); Serial.println(" Hz");
  updateStatus();
}

void stopRecording() {
  if (!isRecording) return;
  flashFlushBuffer();
  header.isRecording = 0;
  header.hasData = (header.sampleCount > 0) ? 1 : 0;
  header.recordingEndMs = millis();
  flashWriteHeader();
  isRecording = false;
  Serial.print("STOP: "); Serial.print(header.sampleCount); Serial.println(" samples");
  updateStatus();
}

void handleControl(uint8_t cmd) {
  switch (cmd) {
    case 1: startRecording(); break;
    case 2: stopRecording(); break;
    case 3:
      if (!isRecording && !isDownloading) {
        flashEraseData();
        updateStatus();
      }
      break;
    case 4:
      if (!isRecording && header.hasData && header.sampleCount > 0) {
        isDownloading = true;
        downloadOffset = 0;
        Serial.print("DL: "); Serial.println(header.sampleCount);
        sendNextDownloadChunk();
      }
      break;
    case 5:
      if (isDownloading) sendNextDownloadChunk();
      break;
  }
}

// ===================== Setup =====================

void setup() {
  Serial.begin(115200);
  delay(1000);

  pinMode(LEDR, OUTPUT); pinMode(LEDG, OUTPUT); pinMode(LEDB, OUTPUT);
  setLED(false, false, false);

  pinMode(VBAT_ENABLE, OUTPUT);
  digitalWrite(VBAT_ENABLE, LOW);
  analogReadResolution(12);
  pinMode(CHG_PIN, INPUT_PULLUP);

  if (!imuBegin()) {
    Serial.println("IMU FAIL");
    while (1) { setLED(true,false,false); delay(200); setLED(false,false,false); delay(200); }
  }

  if (!flashInit()) {
    Serial.println("FLASH FAIL");
    while (1) { setLED(true,true,false); delay(200); setLED(false,false,false); delay(200); }
  }

  if (header.isRecording) {
    isRecording = true;
    Serial.println("Resuming recording");
  }
  sampleInterval_us = 1000000UL / header.sampleRateHz;
  cachedBattPct = readBatteryPercent();

  if (!BLE.begin()) {
    Serial.println("BLE FAIL");
    while (1) { setLED(true,false,false); delay(200); setLED(false,false,false); delay(200); }
  }

  BLE.setLocalName("Runalyzer");
  BLE.setDeviceName("Runalyzer");

  imuService.addCharacteristic(imuChar);
  imuService.addCharacteristic(controlChar);
  imuService.addCharacteristic(statusChar);
  imuService.addCharacteristic(downloadChar);
  imuService.addCharacteristic(configChar);
  BLE.addService(imuService);

  battService.addCharacteristic(battChar);
  BLE.addService(battService);

  configChar.writeValue((uint8_t)header.sampleRateHz);
  battChar.writeValue(cachedBattPct);
  BLE.setAdvertisedService(imuService);
  BLE.setEventHandler(BLEConnected, onConnect);
  BLE.setEventHandler(BLEDisconnected, onDisconnect);
  BLE.advertise();

  Serial.print("Ready @ "); Serial.print(header.sampleRateHz); Serial.println(" Hz");

  lastSample_us = micros();
  lastBatt_ms = lastBlink_ms = lastStatus_ms = lastFlush_ms = millis();
}

// ===================== Loop =====================

void loop() {
  BLE.poll();
  unsigned long now_us = micros();
  unsigned long now_ms = millis();

  // BLE commands
  if (controlChar.written()) handleControl(controlChar.value());
  if (configChar.written() && !isRecording) {
    uint8_t rate = configChar.value();
    if (rate >= 10 && rate <= 100) {
      header.sampleRateHz = rate;
      sampleInterval_us = 1000000UL / rate;
      flashWriteHeader();
    }
  }

  // IMU sampling
  if (now_us - lastSample_us >= sampleInterval_us) {
    lastSample_us += sampleInterval_us;

    uint8_t ad[6], gd[6];
    imuReadBytes(LSM6DS3_OUTX_L_XL, ad, 6);
    imuReadBytes(LSM6DS3_OUTX_L_G, gd, 6);

    if (isRecording) {
      int16_t ax = ad[0] | (ad[1] << 8), ay = ad[2] | (ad[3] << 8), az = ad[4] | (ad[5] << 8);
      int16_t gx = gd[0] | (gd[1] << 8), gy = gd[2] | (gd[3] << 8), gz = gd[4] | (gd[5] << 8);
      flashAddSample((uint32_t)now_ms, ax, ay, az, gx, gy, gz);
    }

    if (bleConnected && imuChar.subscribed() && !isDownloading) {
      uint8_t buf[16];
      uint32_t ts = (uint32_t)now_ms;
      buf[0] = ts; buf[1] = ts >> 8; buf[2] = ts >> 16; buf[3] = ts >> 24;
      memcpy(&buf[4], ad, 6);
      memcpy(&buf[10], gd, 6);
      imuChar.writeValue(buf, 16);
    }
  }

  // Periodic flash flush during recording (max 10s data loss on crash)
  if (isRecording && now_ms - lastFlush_ms >= 10000) {
    lastFlush_ms = now_ms;
    if (writeBufCount > 0) { flashFlushBuffer(); flashWriteHeader(); }
  }

  // Battery check + low-battery shutdown
  if (now_ms - lastBatt_ms >= 30000) {
    lastBatt_ms = now_ms;
    cachedBattPct = readBatteryPercent();
    battChar.writeValue(cachedBattPct);
    if (cachedBattPct > 0 && cachedBattPct <= 10) {
      if (isRecording) stopRecording();
      setLED(true, false, false); delay(2000); setLED(false, false, false);
      NRF_POWER->SYSTEMOFF = 1;
    }
  }

  // Status update to connected phone
  if (now_ms - lastStatus_ms >= 2000) {
    lastStatus_ms = now_ms;
    if (bleConnected) updateStatus();
  }

  // LED indicator
  if (now_ms - lastBlink_ms >= 500) {
    lastBlink_ms = now_ms;
    ledToggle = !ledToggle;
    if (isRecording)          setLED(ledToggle, false, false);  // red blink
    else if (header.hasData)  setLED(false, false, ledToggle);  // blue blink
    else if (bleConnected)    setLED(false, true, false);       // solid green
    else                      setLED(false, false, ledToggle);  // blue blink (advertising)
  }
}
