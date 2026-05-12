#!/bin/bash

# 测试 OTA 接口
# 替换下面的 MAC 地址为您的 ESP32 设备的实际 MAC 地址

MAC_ADDRESS="AA:BB:CC:DD:EE:FF"

echo "=== 测试 OTA 接口 ==="
echo "设备 MAC: $MAC_ADDRESS"
echo ""

# 发送 POST 请求到 OTA 接口
curl -v -X POST http://192.168.1.100:8091/api/device/ota \
  -H "Device-Id: $MAC_ADDRESS" \
  -H "Content-Type: application/json" \
  -d '{
    "mac_address": "'$MAC_ADDRESS'",
    "chip_model_name": "esp32s3",
    "application": {
      "version": "1.0.0"
    },
    "board": {
      "ssid": "TestWiFi",
      "type": "esp32s3"
    }
  }'

echo ""
echo "=== 测试完成 ==="
