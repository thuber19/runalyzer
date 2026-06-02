// Runalyzer v4 — Store & Sync Firmware
// Seeed XIAO nRF52840 Sense
// Records 6-axis IMU to onboard QSPI flash, syncs to phone via BLE

// Comment out for release builds to save CPU cycles
#define DEBUG_LOG

#ifdef DEBUG_LOG
  #define LOG(x) Serial.print(x)
  #define LOGLN(x) Serial.println(x)
#else
  #define LOG(x)
  #define LOGLN(x)
#endif

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
  NRF_P1->PIN_CNF[8] = ((uint32_t)GPIO_PIN_CNF_DIR_Output << GPIO_PIN_CNF_DIR_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_INPUT_Disconnect << GPIO_PIN_CNF_INPUT_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_PULL_Disabled << GPIO_PIN_CNF_PULL_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_DRIVE_H0H1 << GPIO_PIN_CNF_DRIVE_Pos)
                      | ((uint32_t)GPIO_PIN_CNF_SENSE_Disabled << GPIO_PIN_CNF_SENSE_Pos);
  NRF_P1->OUTSET = (1UL << 8);
  delay(100);
  Wire1.begin();
  delay(10);

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
#define SAMPLE_SIZE       12
#define HEADER_MAGIC      0x524E4C59
#define HEADER_VERSION    1         // increment when flash format changes
#define PROTOCOL_VERSION  1         // increment when BLE protocol changes
#define QSPI_TIMEOUT_MS   500

// Event log
#define EVT_START_APP     1
#define EVT_START_BUTTON  2
#define EVT_STOP_APP      3
#define EVT_STOP_BUTTON   4
#define EVT_STOP_BATTERY  5
#define EVT_STOP_MEMORY   6
#define EVT_STOP_POWER    7
#define EVT_DOWNLOAD      8
#define EVT_ERASE         9
#define MAX_EVENTS        16

struct EventEntry {
  uint8_t  reason;
  uint32_t offsetMs;  // H7 fix: always relative to recordingStartUnix
};

struct FlashHeader {
  uint32_t magic;
  uint8_t  version;           // HEADER_VERSION — for format compatibility
  uint8_t  isRecording;
  uint8_t  hasData;
  uint8_t  eventCount;
  uint32_t sampleCount;
  uint32_t sampleRateHz;
  uint64_t recordingStartUnix;
  uint64_t recordingEndUnix;
  uint8_t  timeSynced;
  uint8_t  reserved[3];
  EventEntry events[MAX_EVENTS];
};

static FlashHeader header;
static uint32_t maxSamples = 0;
static uint32_t lastErasedSector = 0xFFFFFFFF;

// Time sync
static uint64_t syncUnixMs = 0;
static uint32_t syncMillis = 0;
static bool hasTimeSync = false;

uint64_t wallClockMs() {
  if (hasTimeSync) return syncUnixMs + (uint64_t)(millis() - syncMillis);
  return 0;
}

// Write buffer — aligned to sector size
#define WRITE_BUF_SAMPLES (FLASH_SECTOR_SIZE / SAMPLE_SIZE)
static __attribute__((aligned(4))) uint8_t writeBuf[WRITE_BUF_SAMPLES * SAMPLE_SIZE];
static uint32_t writeBufCount = 0;

// H1: QSPI with timeout — returns false on failure
bool qspiWait() {
  uint32_t start = millis();
  while (!NRF_QSPI->EVENTS_READY) {
    if (millis() - start > QSPI_TIMEOUT_MS) return false;
  }
  NRF_QSPI->EVENTS_READY = 0;
  return true;
}

bool qspiInit() {
  NRF_QSPI->PSEL.SCK = P0_21;
  NRF_QSPI->PSEL.CSN = P0_25;
  NRF_QSPI->PSEL.IO0 = P0_20;
  NRF_QSPI->PSEL.IO1 = P0_24;
  NRF_QSPI->PSEL.IO2 = P0_22;
  NRF_QSPI->PSEL.IO3 = P0_23;
  NRF_QSPI->IFCONFIG0 = 0;
  NRF_QSPI->IFCONFIG1 = (1 << 25) | (15 << 0);
  NRF_QSPI->ENABLE = 1;
  NRF_QSPI->TASKS_ACTIVATE = 1;
  return qspiWait();
}

bool qspiRead(uint32_t addr, void* buf, uint32_t len) {
  NRF_QSPI->READ.DST = (uint32_t)buf;
  NRF_QSPI->READ.SRC = addr;
  NRF_QSPI->READ.CNT = len;
  NRF_QSPI->EVENTS_READY = 0;
  NRF_QSPI->TASKS_READSTART = 1;
  return qspiWait();
}

bool qspiWrite(uint32_t addr, const void* buf, uint32_t len) {
  NRF_QSPI->WRITE.DST = addr;
  NRF_QSPI->WRITE.SRC = (uint32_t)buf;
  NRF_QSPI->WRITE.CNT = len;
  NRF_QSPI->EVENTS_READY = 0;
  NRF_QSPI->TASKS_WRITESTART = 1;
  return qspiWait();
}

bool qspiEraseSector(uint32_t addr) {
  NRF_QSPI->ERASE.PTR = addr;
  NRF_QSPI->ERASE.LEN = 0;
  NRF_QSPI->EVENTS_READY = 0;
  NRF_QSPI->TASKS_ERASESTART = 1;
  return qspiWait();
}

void flashWriteHeader() {
  qspiEraseSector(HEADER_SECTOR);
  __attribute__((aligned(4))) FlashHeader tmp;
  memcpy(&tmp, &header, sizeof(header));
  qspiWrite(HEADER_SECTOR, &tmp, sizeof(tmp));
}

// H2: Scan flash to find actual sample count (for power-loss recovery)
uint32_t flashScanSampleCount() {
  // Binary search for the boundary between data and erased (0xFF) sectors
  uint32_t lo = 0, hi = maxSamples;
  __attribute__((aligned(4))) uint8_t buf[SAMPLE_SIZE];
  while (lo < hi) {
    uint32_t mid = (lo + hi) / 2;
    qspiRead(DATA_START + mid * SAMPLE_SIZE, buf, SAMPLE_SIZE);
    bool allFF = true;
    for (int i = 0; i < SAMPLE_SIZE; i++) { if (buf[i] != 0xFF) { allFF = false; break; } }
    if (allFF) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

bool flashInit() {
  if (!qspiInit()) return false;
  maxSamples = (FLASH_SIZE - DATA_START) / SAMPLE_SIZE;

  __attribute__((aligned(4))) FlashHeader tmp;
  qspiRead(HEADER_SECTOR, &tmp, sizeof(tmp));
  memcpy(&header, &tmp, sizeof(header));

  if (header.magic != HEADER_MAGIC || header.version != HEADER_VERSION) {
    // Fresh init or incompatible version — reset
    if (header.magic == HEADER_MAGIC && header.version != HEADER_VERSION) {
      LOGLN("Flash: incompatible version, resetting");
    }
    memset(&header, 0, sizeof(header));
    header.magic = HEADER_MAGIC;
    header.version = HEADER_VERSION;
    header.sampleRateHz = 25;
    flashWriteHeader();
  }
  LOG("Flash: "); LOG(header.sampleCount);
  LOG(" samples, "); LOG(header.sampleRateHz);
  LOG(" Hz, max="); LOGLN(maxSamples);
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

void flashAddSample(int16_t ax, int16_t ay, int16_t az,
                    int16_t gx, int16_t gy, int16_t gz) {
  if (header.sampleCount + writeBufCount >= maxSamples) return;
  uint8_t* p = &writeBuf[writeBufCount * SAMPLE_SIZE];
  p[0] = ax; p[1] = ax >> 8; p[2] = ay; p[3] = ay >> 8;
  p[4] = az; p[5] = az >> 8; p[6] = gx; p[7] = gx >> 8;
  p[8] = gy; p[9] = gy >> 8; p[10] = gz; p[11] = gz >> 8;
  writeBufCount++;
  if (writeBufCount >= WRITE_BUF_SAMPLES) flashFlushBuffer();
}

// H7: Event timestamps always relative ms from recording start
void logEvent(uint8_t reason) {
  if (header.eventCount < MAX_EVENTS) {
    header.events[header.eventCount].reason = reason;
    uint32_t offset = 0;
    if (header.recordingStartUnix > 0 && hasTimeSync) {
      offset = (uint32_t)(wallClockMs() - header.recordingStartUnix);
    } else {
      offset = millis();  // fallback: uptime, but consistent within session
    }
    header.events[header.eventCount].offsetMs = offset;
    header.eventCount++;
  }
}

void flashEraseData() {
  header.sampleCount = 0;
  header.recordingStartUnix = 0;
  header.recordingEndUnix = 0;
  header.isRecording = 0;
  header.hasData = 0;
  header.eventCount = 0;
  lastErasedSector = 0xFFFFFFFF;
  flashWriteHeader();
}

// ===================== BLE =====================

#define IMU_SERVICE_UUID   "264f9cc7-8f8a-4aad-878a-d3615d12dccc"
#define IMU_CHAR_UUID      "264f9cc7-8f8a-4aad-878a-d3615d12dcc1"
#define CONTROL_CHAR_UUID  "264f9cc7-8f8a-4aad-878a-d3615d12dcc2"
#define STATUS_CHAR_UUID   "264f9cc7-8f8a-4aad-878a-d3615d12dcc3"
#define DOWNLOAD_CHAR_UUID "264f9cc7-8f8a-4aad-878a-d3615d12dcc4"
#define CONFIG_CHAR_UUID   "264f9cc7-8f8a-4aad-878a-d3615d12dcc5"
#define TIMESYNC_CHAR_UUID "264f9cc7-8f8a-4aad-878a-d3615d12dcc6"

BLEService imuService(IMU_SERVICE_UUID);
BLECharacteristic imuChar(IMU_CHAR_UUID, BLERead | BLENotify, 16);
BLEByteCharacteristic controlChar(CONTROL_CHAR_UUID, BLEWrite);
BLECharacteristic statusChar(STATUS_CHAR_UUID, BLERead | BLENotify, 28);
BLECharacteristic downloadChar(DOWNLOAD_CHAR_UUID, BLERead | BLENotify, 240);
BLEByteCharacteristic configChar(CONFIG_CHAR_UUID, BLERead | BLEWrite);
BLECharacteristic timesyncChar(TIMESYNC_CHAR_UUID, BLEWrite, 8);

BLEService battService("180F");
BLEByteCharacteristic battChar("2A19", BLERead | BLENotify);

// ===================== Battery =====================

#define VBAT_PIN    PIN_VBAT
#define VBAT_ENABLE PIN_VBAT_ENABLE
#define CHG_PIN     22

static uint8_t cachedBattPct = 0;

// M8: LiPo discharge curve lookup (voltage → percentage)
// Based on typical single-cell LiPo discharge profile
uint8_t voltageToPercent(float voltage) {
  if (voltage >= 4.15) return 100;
  if (voltage >= 4.05) return 90;
  if (voltage >= 3.95) return 80;
  if (voltage >= 3.85) return 70;
  if (voltage >= 3.80) return 60;
  if (voltage >= 3.75) return 50;
  if (voltage >= 3.70) return 40;
  if (voltage >= 3.65) return 30;
  if (voltage >= 3.55) return 20;
  if (voltage >= 3.40) return 10;
  if (voltage >= 3.20) return 5;
  return 0;
}

uint8_t readBatteryPercent() {
  digitalWrite(VBAT_ENABLE, HIGH);
  delay(1);
  // Average 4 readings for stability
  uint32_t sum = 0;
  for (int i = 0; i < 4; i++) sum += analogRead(VBAT_PIN);
  digitalWrite(VBAT_ENABLE, LOW);
  float voltage = (sum / 4.0f / 4095.0f) * 3.3f * 2.0f;
  return voltageToPercent(voltage);
}

// ===================== LED =====================

void setLED(bool r, bool g, bool b) {
  digitalWrite(LEDR, r ? LOW : HIGH);
  digitalWrite(LEDG, g ? LOW : HIGH);
  digitalWrite(LEDB, b ? LOW : HIGH);
}

// ===================== State =====================

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
static unsigned long sampleInterval_us = 40000;

// ===================== BLE Callbacks =====================

void onConnect(BLEDevice central) {
  bleConnected = true;
  if (isRecording && writeBufCount > 0) {
    flashFlushBuffer();
    // H2: don't write header on every connect — only on stop
  }
  if (header.sampleCount > 0 && !isRecording) {
    header.hasData = 1;
    flashWriteHeader();
  }
}

void onDisconnect(BLEDevice central) {
  bleConnected = false;
  isDownloading = false;
}

// ===================== Status =====================

void updateStatus() {
  uint8_t buf[28] = {0};

  if (isDownloading)                              buf[0] = 3;
  else if (isRecording)                           buf[0] = 1;
  else if (header.hasData && header.sampleCount)  buf[0] = 2;

  uint32_t sc = header.sampleCount + writeBufCount;
  buf[1] = sc; buf[2] = sc >> 8; buf[3] = sc >> 16; buf[4] = sc >> 24;
  buf[5] = (uint8_t)header.sampleRateHz;
  buf[6] = cachedBattPct;
  bool charging = (digitalRead(CHG_PIN) == LOW && cachedBattPct > 5 && cachedBattPct < 100);
  buf[7] = (charging ? 0x01 : 0) | (hasTimeSync ? 0x02 : 0);
  buf[8] = maxSamples; buf[9] = maxSamples >> 8;
  buf[10] = maxSamples >> 16; buf[11] = maxSamples >> 24;

  uint32_t dur = 0;
  if (isRecording && header.recordingStartUnix > 0)
    dur = (uint32_t)((wallClockMs() - header.recordingStartUnix) / 1000);
  else if (header.recordingEndUnix > header.recordingStartUnix)
    dur = (uint32_t)((header.recordingEndUnix - header.recordingStartUnix) / 1000);
  buf[12] = dur; buf[13] = dur >> 8; buf[14] = dur >> 16; buf[15] = dur >> 24;

  uint64_t startUnix = header.recordingStartUnix;
  for (int i = 0; i < 8; i++) buf[16 + i] = (startUnix >> (i * 8)) & 0xFF;

  buf[24] = PROTOCOL_VERSION;
  buf[25] = HEADER_VERSION;
  // buf[26-27] reserved

  statusChar.writeValue(buf, 28);
}

// ===================== Download =====================

#define DL_SAMPLES_PER_PACKET 19

// H7: Event log with relative ms offsets
void sendEventLog() {
  uint8_t packet[240];
  packet[0] = 0xFE; packet[1] = 0xFF; packet[2] = 0xFF; packet[3] = 0xFF;
  packet[4] = header.eventCount;
  uint16_t offset = 5;
  for (uint8_t i = 0; i < header.eventCount && offset + 5 <= 240; i++) {
    packet[offset] = header.events[i].reason;
    uint32_t ts = header.events[i].offsetMs;
    packet[offset+1] = ts; packet[offset+2] = ts >> 8;
    packet[offset+3] = ts >> 16; packet[offset+4] = ts >> 24;
    offset += 5;
  }
  downloadChar.writeValue(packet, offset);
}

// Returns true if packet was sent, false if BLE buffer was full
bool sendNextDownloadChunk() {
  if (downloadOffset >= header.sampleCount) {
    uint8_t end[4] = {0xFF, 0xFF, 0xFF, 0xFF};
    downloadChar.writeValue(end, 4);
    isDownloading = false;
    updateStatus();
    return true;
  }

  uint32_t remaining = header.sampleCount - downloadOffset;
  uint8_t n = min((uint32_t)DL_SAMPLES_PER_PACKET, remaining);

  uint8_t packet[240];
  packet[0] = downloadOffset; packet[1] = downloadOffset >> 8;
  packet[2] = downloadOffset >> 16; packet[3] = downloadOffset >> 24;

  __attribute__((aligned(4))) uint8_t fb[DL_SAMPLES_PER_PACKET * SAMPLE_SIZE];
  qspiRead(DATA_START + downloadOffset * SAMPLE_SIZE, fb, n * SAMPLE_SIZE);
  memcpy(&packet[4], fb, n * SAMPLE_SIZE);

  int sent = downloadChar.writeValue(packet, 4 + n * SAMPLE_SIZE);
  if (sent) {
    downloadOffset += n;
    return true;
  }
  return false;  // BLE buffer full
}

// ===================== Recording =====================

void startRecording(uint8_t reason) {
  if (isRecording || isDownloading) return;
  flashEraseData();
  header.isRecording = 1;
  header.recordingStartUnix = wallClockMs();
  header.timeSynced = hasTimeSync ? 1 : 0;
  logEvent(reason);
  // H2: write header once at start
  flashWriteHeader();
  isRecording = true;
  sampleInterval_us = 1000000UL / header.sampleRateHz;
  updateStatus();
}

void stopRecording(uint8_t reason) {
  if (!isRecording) return;
  flashFlushBuffer();
  header.isRecording = 0;
  header.hasData = (header.sampleCount > 0) ? 1 : 0;
  header.recordingEndUnix = wallClockMs();
  logEvent(reason);
  // H2: write header once at stop
  flashWriteHeader();
  isRecording = false;
  updateStatus();
}

void handleControl(uint8_t cmd) {
  switch (cmd) {
    case 1: startRecording(EVT_START_APP); break;
    case 2: stopRecording(EVT_STOP_APP); break;
    case 3:
      if (!isRecording && !isDownloading) {
        logEvent(EVT_ERASE);
        flashEraseData();
        updateStatus();
      }
      break;
    case 4:
      if (!isRecording && header.hasData && header.sampleCount > 0) {
        logEvent(EVT_DOWNLOAD);
        flashWriteHeader();  // persist the download event
        isDownloading = true;
        downloadOffset = 0;
        sendEventLog();
        sendNextDownloadChunk();
      }
      break;
    case 5:
      // Send as many chunks as the BLE stack accepts
      if (isDownloading) {
        for (int i = 0; i < 10 && isDownloading; i++) {
          if (!sendNextDownloadChunk()) break;  // BLE buffer full — stop
        }
      }
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
    LOGLN("IMU FAIL");
    while (1) { setLED(true,false,false); delay(200); setLED(false,false,false); delay(200); }
  }

  if (!flashInit()) {
    LOGLN("FLASH FAIL");
    while (1) { setLED(true,true,false); delay(200); setLED(false,false,false); delay(200); }
  }

  // H2: Power-loss recovery — scan flash for actual data instead of trusting header
  if (header.isRecording) {
    uint32_t scannedCount = flashScanSampleCount();
    header.sampleCount = scannedCount;
    logEvent(EVT_STOP_POWER);
    header.isRecording = 0;
    header.hasData = (scannedCount > 0) ? 1 : 0;
    header.recordingEndUnix = 0;  // unknown — time not synced at boot
    flashWriteHeader();
    LOG("Recovered: "); LOG(scannedCount); LOGLN(" samples");
  }

  sampleInterval_us = 1000000UL / header.sampleRateHz;
  cachedBattPct = readBatteryPercent();

  if (!BLE.begin()) {
    LOGLN("BLE FAIL");
    while (1) { setLED(true,false,false); delay(200); setLED(false,false,false); delay(200); }
  }

  BLE.setLocalName("Runalyzer");
  BLE.setDeviceName("Runalyzer");

  imuService.addCharacteristic(imuChar);
  imuService.addCharacteristic(controlChar);
  imuService.addCharacteristic(statusChar);
  imuService.addCharacteristic(downloadChar);
  imuService.addCharacteristic(configChar);
  imuService.addCharacteristic(timesyncChar);
  BLE.addService(imuService);

  battService.addCharacteristic(battChar);
  BLE.addService(battService);

  configChar.writeValue((uint8_t)header.sampleRateHz);
  battChar.writeValue(cachedBattPct);
  BLE.setAdvertisedService(imuService);
  BLE.setEventHandler(BLEConnected, onConnect);
  BLE.setEventHandler(BLEDisconnected, onDisconnect);
  BLE.advertise();

  lastSample_us = micros();
  lastBatt_ms = lastBlink_ms = lastStatus_ms = lastFlush_ms = millis();
}

// ===================== Loop =====================

void loop() {
  BLE.poll();
  unsigned long now_us = micros();
  unsigned long now_ms = millis();

  if (controlChar.written()) handleControl(controlChar.value());
  if (configChar.written() && !isRecording) {
    uint8_t rate = configChar.value();
    if (rate >= 10 && rate <= 100) {
      header.sampleRateHz = rate;
      sampleInterval_us = 1000000UL / rate;
      flashWriteHeader();
    }
  }

  if (timesyncChar.written()) {
    uint8_t buf[8];
    timesyncChar.readValue(buf, 8);
    syncUnixMs = 0;
    for (int i = 7; i >= 0; i--) syncUnixMs = (syncUnixMs << 8) | buf[i];
    syncMillis = millis();
    hasTimeSync = true;
  }

  // IMU sampling
  if (!isDownloading && now_us - lastSample_us >= sampleInterval_us) {
    lastSample_us += sampleInterval_us;

    uint8_t ad[6], gd[6];
    imuReadBytes(LSM6DS3_OUTX_L_XL, ad, 6);
    imuReadBytes(LSM6DS3_OUTX_L_G, gd, 6);

    if (isRecording) {
      int16_t ax = ad[0] | (ad[1] << 8), ay = ad[2] | (ad[3] << 8), az = ad[4] | (ad[5] << 8);
      int16_t gx = gd[0] | (gd[1] << 8), gy = gd[2] | (gd[3] << 8), gz = gd[4] | (gd[5] << 8);
      flashAddSample(ax, ay, az, gx, gy, gz);
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

  // H2: Periodic flush — only flush data, NOT header (saves sector wear)
  if (isRecording && now_ms - lastFlush_ms >= 10000) {
    lastFlush_ms = now_ms;
    if (writeBufCount > 0) flashFlushBuffer();

    uint32_t totalSamples = header.sampleCount + writeBufCount;
    if (totalSamples >= (maxSamples * 95 / 100)) {
      stopRecording(EVT_STOP_MEMORY);
    }
  }

  // Battery
  if (now_ms - lastBatt_ms >= 30000) {
    lastBatt_ms = now_ms;
    cachedBattPct = readBatteryPercent();
    battChar.writeValue(cachedBattPct);
    if (cachedBattPct > 0 && cachedBattPct <= 10) {
      if (isRecording) stopRecording(EVT_STOP_BATTERY);
      setLED(true, false, false); delay(2000); setLED(false, false, false);
      NRF_POWER->SYSTEMOFF = 1;
    }
  }

  // Status (pause during download to avoid BLE buffer congestion)
  if (!isDownloading && now_ms - lastStatus_ms >= 2000) {
    lastStatus_ms = now_ms;
    if (bleConnected) updateStatus();
  }

  // LED
  if (now_ms - lastBlink_ms >= 500) {
    lastBlink_ms = now_ms;
    ledToggle = !ledToggle;
    if (isRecording)          setLED(ledToggle, false, false);
    else if (header.hasData)  setLED(false, ledToggle, ledToggle);  // L7: cyan blink for hasData
    else if (bleConnected)    setLED(false, true, false);
    else                      setLED(false, false, ledToggle);      // blue blink for advertising
  }
}
