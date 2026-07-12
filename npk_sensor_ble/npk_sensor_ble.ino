#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>

// ==========================================
// BLE UUID (ต้องตรงกับ Flutter)
// ==========================================
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define ACK_UUID            "beb5483e-36e1-4688-b7f5-ea07361b26a9"

// ==========================================
// PIN
// ==========================================
#define RE            4
#define RXD2          17
#define TXD2          16
#define ANALOG_IN_PIN 36
#define SLEEP_BTN_PIN 14
#define SEND_BTN_PIN  33
#define Relay         13
#define SDA           21
#define SCL           22
#define BUZZER_PIN    26 

#define REF_VOLTAGE    3.3
#define ADC_RESOLUTION 4096.0
#define R1             30000.0
#define R2             7500.0

// ==========================================
// ตัวแปร global
// ==========================================
const unsigned long interval = 5000;
unsigned long previousMillis = 0, relayMillis = 0;

const byte read_all[] = { 0x01, 0x03, 0x00, 0x00, 0x00, 0x08, 0x44, 0x0C };
byte values[25];

uint8_t lastN = 0, lastP = 0, lastK = 0, lastMoist = 0, lastPh = 0;
bool hasValidData = false;

volatile bool sleepBtnPressed = false;
volatile bool ackReceived     = false;
volatile bool failReceived    = false;

// ตัวแปรสำหรับจับเวลารอ ACK
bool          waitingForAck   = false;
unsigned long ackTimeoutMs    = 0;
#define ACK_TIMEOUT 6000  // รอ 6 วินาที

BLECharacteristic *pCharacteristic;
bool deviceConnected = false;

LiquidCrystal_I2C lcd(0x27, 20, 4);

// ==========================================
// ตัวแปรสำหรับระบบ Auto Deep Sleep
// ==========================================
unsigned long lastActivityMillis = 0; 
const unsigned long SLEEP_TIMEOUT_DISCONNECT = 5 * 60 * 1000;  // 5 นาที 
const unsigned long SLEEP_TIMEOUT_CONNECT    = 10 * 60 * 1000; // 10 นาที 

// ==========================================
// ฟังก์ชันสำหรับ Buzzer (Active Low)
// ==========================================
void beepBuzzer() {
  digitalWrite(BUZZER_PIN, LOW); // LOW = เสียงดัง
  delay(100); 
  digitalWrite(BUZZER_PIN, HIGH); // HIGH = ปิดเสียง
}

// ==========================================
// ฟังก์ชันสำหรับเข้าโหมด Deep Sleep
// ==========================================
void goToDeepSleep(String msg, bool waitForButtonRelease) {
  beepBuzzer();
  Serial.println("Going to Deep Sleep... Reason: " + msg);
  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print(msg);
  delay(1000); 
  
  lcd.noDisplay();
  lcd.noBacklight();
  
  if (waitForButtonRelease) {
    while (digitalRead(SLEEP_BTN_PIN) == LOW) delay(10);
  }
  
  digitalWrite(Relay, HIGH);
  delay(100);
  gpio_hold_en(GPIO_NUM_13);
  gpio_deep_sleep_hold_en();
  esp_sleep_enable_ext0_wakeup(GPIO_NUM_14, 0);
  delay(100);
  esp_deep_sleep_start();
}

// ==========================================
// ACK Callbacks
// ==========================================
class AckCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pChar) {
    String value = pChar->getValue().c_str();
    if (value == "OK") {
      ackReceived = true;
      Serial.println("✅ Flutter บันทึกสำเร็จแล้ว! ล้างค่าเป็น 0");

      hasValidData = false; 

      // ✅ ขยายอาเรย์ส่งค่าเคลียร์เป็น 5 ไบต์ (เพิ่มของ pH)
      if (pCharacteristic != nullptr) {
        uint8_t zeroData[5] = {0, 0, 0, 0, 0};
        pCharacteristic->setValue(zeroData, 5);
        pCharacteristic->notify();
      }

    } else if (value == "FAIL") {
      failReceived = true;
      Serial.println("❌ Flutter บันทึกไม่สำเร็จ!");
    }
  }
};

// ==========================================
// BLE Callbacks
// ==========================================
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    lastActivityMillis = millis(); 
    Serial.println("📱 โทรศัพท์เชื่อมต่อแล้ว!");
  }
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    waitingForAck   = false;
    lastActivityMillis = millis(); 
    Serial.println("❌ โทรศัพท์ตัดการเชื่อมต่อ...");
    BLEDevice::startAdvertising();
  }
};

// ==========================================
// Interrupt
// ==========================================
void IRAM_ATTR handleSleepBtn() {
  sleepBtnPressed = true;
}

// ==========================================
// Setup
// ==========================================
void setup() {
  Serial.begin(9600);
  gpio_hold_dis(GPIO_NUM_13);
  gpio_deep_sleep_hold_dis();

  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, HIGH);

  beepBuzzer(); 
  delay(100); 
  beepBuzzer();

  Wire.begin(SDA, SCL);
  lcd.init();
  lcd.backlight();
  lcd.setCursor(0, 0);
  lcd.print("Soil Monitor");
  
  pinMode(SLEEP_BTN_PIN, INPUT_PULLUP);
  
  int start_adc = analogRead(ANALOG_IN_PIN);
  float start_v_adc = ((float)start_adc * REF_VOLTAGE) / ADC_RESOLUTION;
  float start_v_in  = 0.5 + start_v_adc * (R1 + R2) / R2;
  float start_batt = constrain((start_v_in - 10.8) * 100.0 / (12.0 - 10.8), 0, 100);

  if (start_batt < 9.75) {
    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("Low Battery!");
    lcd.setCursor(0, 1);
    lcd.print("Batt: "); lcd.print(start_batt, 0); lcd.print("%");
    lcd.setCursor(0, 2);
    lcd.print("Please charge...");
    
    while (digitalRead(SLEEP_BTN_PIN) == LOW) delay(10); 
    delay(2000); 
    goToDeepSleep("Sleep (Low Batt)", false); 
  }

  delay(2000);
  lcd.clear();

  attachInterrupt(digitalPinToInterrupt(SLEEP_BTN_PIN), handleSleepBtn, FALLING);
  pinMode(SEND_BTN_PIN, INPUT_PULLUP);

  Serial1.begin(9600, SERIAL_8N1, RXD2, TXD2);
  pinMode(RE, OUTPUT);
  digitalWrite(RE, LOW);

  pinMode(Relay, OUTPUT);
  digitalWrite(Relay, LOW);

  BLEDevice::init("NPK_Sensor");
  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(BLEUUID(SERVICE_UUID), 20);
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );

  BLECharacteristic *pAckChar = pService->createCharacteristic(
    ACK_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pAckChar->setCallbacks(new AckCallbacks());

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  lastActivityMillis = millis(); 
  Serial.println("📡 BLE พร้อมแล้ว! กดปุ่มขา 33 เพื่อส่งค่า NPK และ pH");
}

// ==========================================
// Loop
// ==========================================
void loop() {
  unsigned long currentMillis = millis();

  // ── ตรวจสอบระบบ Auto Deep Sleep ──
  unsigned long timeThreshold = deviceConnected ? SLEEP_TIMEOUT_CONNECT : SLEEP_TIMEOUT_DISCONNECT;
  if (currentMillis - lastActivityMillis >= timeThreshold) {
    goToDeepSleep("Auto Sleep...", false); 
  }

  // ── ตรวจ ACK สำเร็จ ──
  if (ackReceived) {
    ackReceived   = false;
    waitingForAck = false;
    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("Save successful");
    lcd.setCursor(0, 1);
    lcd.print("N:"); lcd.print(lastN);
    lcd.print(" P:"); lcd.print(lastP);
    lcd.print(" K:"); lcd.print(lastK);
    // ✅ แสดง pH บนจอ
    lcd.setCursor(0, 2);
    lcd.print("M:"); lcd.print(lastMoist); lcd.print("% pH:"); lcd.print(lastPh / 10.0, 1);
    lcd.setCursor(0, 3);
    lcd.print("GPS + Firebase OK");
    digitalWrite(BUZZER_PIN, LOW);
    delay(2500);
    digitalWrite(BUZZER_PIN, HIGH);
    lastN = 0;
    lastP = 0;
    lastK = 0;
    lastMoist = 0;
    lastPh = 0; // ✅ ล้างค่า pH
  }

  // ── ตรวจ FAIL จาก Flutter ──
  if (failReceived) {
    failReceived  = false;
    waitingForAck = false;
    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("Save Failed!");
    lcd.setCursor(0, 1);
    lcd.print("Check GPS/Network");
    delay(3000);
  }

  // ── ตรวจ timeout รอ ACK ──
  if (waitingForAck && (currentMillis - ackTimeoutMs >= ACK_TIMEOUT)) {
    waitingForAck = false;
    Serial.println("⏱️ Timeout! ไม่ได้รับ ACK จาก Flutter");
    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("Error: No Response");
    lcd.setCursor(0, 1);
    lcd.print("Check BLE/App");
    lcd.setCursor(0, 2);
    lcd.print("Background ON?");
    delay(3000);
  }

  // ── ปุ่ม Deep Sleep (ขา 14) ──
  if (sleepBtnPressed) {
    sleepBtnPressed = false;
    if (digitalRead(SLEEP_BTN_PIN) == LOW) {
      goToDeepSleep("Sleep...", true); 
    }
  }

  // ── ปุ่มส่งค่า NPK และ pH (ขา 33) ──
  if (digitalRead(SEND_BTN_PIN) == LOW) {
    delay(50);
    if (digitalRead(SEND_BTN_PIN) == LOW) {
      lastActivityMillis = currentMillis; 
      beepBuzzer(); 
      
      if (!hasValidData) {
        Serial.println("⚠️ ยังไม่มีข้อมูลจากเซนเซอร์");
        lcd.clear();
        lcd.setCursor(0, 0);
        lcd.print("No Data Yet!");
        delay(1500);
      } else if (!deviceConnected) {
        Serial.println("⚠️ ยังไม่มีโทรศัพท์เชื่อมต่อ");
        lcd.clear();
        lcd.setCursor(0, 0);
        lcd.print("BLE Not Connected");
        delay(1500);
      } else if (lastMoist < 20) { 
        Serial.println("⚠️ ความชื้นต่ำกว่า 20%");
        lcd.clear();
        lcd.setCursor(0, 0);
        lcd.print("Cannot Send Data!");
        lcd.setCursor(0, 1);
        lcd.print("Moisture < 20%");
        lcd.setCursor(0, 2);
        lcd.print("NPK Not Accurate");
        delay(200); beepBuzzer(); delay(100); beepBuzzer();
        delay(1500);
      } else {
        // ✅ สร้าง Array 5 ช่อง ส่ง N, P, K, Moist และ pH
        uint8_t dataToSend[5] = { lastN, lastP, lastK, lastMoist, lastPh };
        pCharacteristic->setValue(dataToSend, 5); // ส่ง 5 ไบต์
        pCharacteristic->notify();
        delay(100);

        Serial.printf("📤 ส่งค่า BLE: N:%d P:%d K:%d Moist:%d pH:%.1f\n", lastN, lastP, lastK, lastMoist, lastPh / 10.0);

        waitingForAck = true;
        ackTimeoutMs  = millis();

        lcd.clear();
        lcd.setCursor(0, 0);
        lcd.print("Sending...");
        lcd.setCursor(0, 1);
        lcd.print("N:"); lcd.print(lastN);
        lcd.print(" P:"); lcd.print(lastP);
        lcd.print(" K:"); lcd.print(lastK);
        lcd.setCursor(0, 2);
       
        lcd.print("M:"); lcd.print(lastMoist); lcd.print("% pH:"); lcd.print(lastPh / 10.0, 1);
        lcd.setCursor(0, 3);
        lcd.print("Waiting response..");
      }
      while (digitalRead(SEND_BTN_PIN) == LOW) delay(10);
    }
  }

  // ── อ่านค่าเซนเซอร์ทุก 5 วิ ──
  if (currentMillis - previousMillis >= interval) {
    previousMillis = currentMillis;

    if (waitingForAck) return;

    digitalWrite(RE, HIGH);
    delay(10);
    Serial1.write(read_all, sizeof(read_all));
    Serial1.flush();
    digitalWrite(RE, LOW);
    delay(200);

    int i = 0;
    while (Serial1.available() && i < 25) {
      values[i++] = Serial1.read();
    }

    float temp = 0, humid = 0, ph = 0;
    int ec = 0, salinity = 0, n = 0, p = 0, k = 0;

    if (i >= 21) {
      temp     = (int16_t)((values[3]  << 8) | values[4])  / 10.0;
      humid    = (uint16_t)((values[5] << 8) | values[6])  / 10.0;
      ec       = (uint16_t)((values[7] << 8) | values[8]);
      ph       = (uint16_t)((values[17]<< 8) | values[18]) / 100.0;
      salinity = (uint16_t)((values[9] << 8) | values[10]);
      n        = (uint16_t)((values[11]<< 8) | values[12]);
      p        = (uint16_t)((values[13]<< 8) | values[14]);
      k        = (uint16_t)((values[15]<< 8) | values[16]);

      lastN     = (uint8_t)constrain(n, 0, 255);
      lastP     = (uint8_t)constrain(p, 0, 255);
      lastK     = (uint8_t)constrain(k, 0, 255);
      lastMoist = (uint8_t)constrain((int)humid, 0, 255);
      
      // ✅ แปลง pH เป็นจำนวนเต็ม (คูณ 10) เพื่อให้ส่งผ่าน byte เดียวได้ 
      // เช่น 6.5 จะเก็บเป็น 65
      lastPh    = (uint8_t)constrain((int)(ph * 10), 0, 140); 
      hasValidData = true;

      Serial.printf("N:%d P:%d K:%d Temp:%.1f Humid:%.1f EC:%d pH:%.2f\n", n, p, k, temp, humid, ec, ph);

      lcd.clear();
      lcd.setCursor(0, 0);
      lcd.print("N:"); lcd.print(n);
      lcd.print(" P:"); lcd.print(p);
      lcd.print(" K:"); lcd.print(k);

      lcd.setCursor(0, 1);
      // ✅ แสดงผลบรรทัดที่ 2 ปรับตัวหนังสือให้ย่อลง เพื่อให้โชว์ pH ได้พอดีจอ (T=Temp, H=Humid)
      lcd.print("T:"); lcd.print(temp, 1); lcd.print("C");
      lcd.print(" H:"); lcd.print(humid, 0); lcd.print("%");
      lcd.print(" pH:"); lcd.print(ph, 1);

      int adc_value = analogRead(ANALOG_IN_PIN);
      float voltage_adc = ((float)adc_value * REF_VOLTAGE) / ADC_RESOLUTION;
      float voltage_in  = 0.5 + voltage_adc * (R1 + R2) / R2;
      float mapped_value = constrain((voltage_in - 10.8) * 100.0 / (12.0 - 10.8), 0, 100);

      // ── ถ้าแบตตกต่ำกว่า 10% ระหว่างกำลังทำงานอยู่ ให้เข้าโหมด Sleep ทันที ──
      if (mapped_value < 9.75 && currentMillis > 3000) {
        goToDeepSleep("Low Battery!", false);
      }

      lcd.setCursor(0, 2);
      lcd.print("Batt:"); lcd.print(voltage_in, 2); lcd.print("V");
      lcd.print(" "); lcd.print(mapped_value, 0); lcd.print("%   "); 
      
      lcd.setCursor(0, 3);
      lcd.print(deviceConnected ? " BLE:Connect   " : " BLE:Disconnect");

    } else {
      Serial.println("❌ Error: No data from sensor");
      lcd.clear();
      lcd.setCursor(0, 0);
      lcd.print("Sensor Error!");
    }
  }
}