#!/bin/bash
# FunASR WebSocket 服务启动脚本
# 用于本地部署 FunASR 实时语音识别服务

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置参数
FUNASR_MODEL_DIR="${1:-$(pwd)/models/stt/FunASR}"
FUNASR_PORT="${2:-10095}"
HOST_IP="${3:-0.0.0.0}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  FunASR WebSocket 服务启动脚本${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 检查模型目录是否存在
if [ ! -d "$FUNASR_MODEL_DIR" ]; then
    echo -e "${RED}错误: 模型目录不存在: $FUNASR_MODEL_DIR${NC}"
    echo -e "${YELLOW}请确保已下载 FunASR 模型到该目录${NC}"
    exit 1
fi

# 检查必要的模型文件
REQUIRED_FILES=("model.pt" "config.yaml" "am.mvn" "tokens.json")
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$FUNASR_MODEL_DIR/$file" ]; then
        echo -e "${RED}错误: 缺少必要的模型文件: $file${NC}"
        exit 1
    fi
done

echo -e "${GREEN}✓ 模型文件检查通过${NC}"
echo ""

# 检查 Python 是否安装
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}错误: 未找到 python3，请先安装 Python 3${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Python3 版本: $(python3 --version)${NC}"
echo ""

# 检查并安装依赖
echo -e "${YELLOW}检查 FunASR 依赖...${NC}"

# 检查 funasr_onnx
if python3 -c "import funasr_onnx" 2>/dev/null; then
    echo -e "${GREEN}✓ funasr_onnx 已安装${NC}"
else
    echo -e "${YELLOW}正在安装 funasr_onnx...${NC}"
    pip3 install funasr_onnx -q
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}尝试使用国内镜像源安装...${NC}"
        pip3 install funasr_onnx -i https://mirror.sjtu.edu.cn/pypi/web/simple -q
    fi
fi

# 检查 websockets
if python3 -c "import websockets" 2>/dev/null; then
    echo -e "${GREEN}✓ websockets 已安装${NC}"
else
    echo -e "${YELLOW}正在安装 websockets...${NC}"
    pip3 install websockets -q
fi

# 检查 numpy
if python3 -c "import numpy" 2>/dev/null; then
    echo -e "${GREEN}✓ numpy 已安装${NC}"
else
    echo -e "${YELLOW}正在安装 numpy...${NC}"
    pip3 install numpy -q
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  启动 FunASR WebSocket 服务${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "模型目录: ${GREEN}$FUNASR_MODEL_DIR${NC}"
echo -e "监听地址: ${GREEN}$HOST_IP:$FUNASR_PORT${NC}"
echo ""

# 创建 FunASR WebSocket 服务器脚本
cat > /tmp/funasr_websocket_server.py << 'PYTHON_EOF'
import asyncio
import websockets
import json
import struct
import numpy as np
import sys
import os
from pathlib import Path

try:
    from funasr import AutoModel
except ImportError:
    print("错误: 未安装 funasr，请先安装: pip install funasr")
    sys.exit(1)

class FunASRServer:
    def __init__(self, model_dir, host="0.0.0.0", port=10095):
        self.model_dir = model_dir
        self.host = host
        self.port = port
        self.model = None
        
    def load_model(self):
        """加载 Paraformer 模型"""
        print(f"正在加载模型: {self.model_dir}")
        try:
            # 使用 AutoModel 加载,更稳定
            self.model = AutoModel(
                model=self.model_dir,
                trust_remote_code=True,
                device="cpu",  # 使用 CPU,如需 GPU 改为 "cuda"
                disable_update=True  # 禁用版本检查
            )
            print("✓ 模型加载成功")
        except Exception as e:
            print(f"✗ 模型加载失败: {e}")
            raise
    
    async def handle_client(self, websocket):
        """处理客户端连接"""
        client_id = id(websocket)
        print(f"[{client_id}] 新客户端连接")
        
        audio_buffer = bytearray()
        is_speaking = False
        chunk_size_config = [5, 10, 5]  # 默认配置
        
        try:
            async for message in websocket:
                # 处理文本消息（控制指令）
                if isinstance(message, str):
                    try:
                        data = json.loads(message)
                        
                        # 开始说话
                        if data.get('is_speaking') == True:
                            is_speaking = True
                            audio_buffer.clear()
                            print(f"[{client_id}] 开始接收音频")
                            
                            # 获取配置
                            if 'chunk_size' in data:
                                chunk_size_config = data['chunk_size']
                        
                        # 结束说话
                        elif data.get('is_speaking') == False:
                            is_speaking = False
                            print(f"[{client_id}] 音频接收完成，总大小: {len(audio_buffer)} bytes")
                            
                            # 进行识别
                            if len(audio_buffer) > 0:
                                result = await self.recognize(audio_buffer)
                                
                                # 发送结果
                                response = {
                                    "text": result,
                                    "is_final": True,
                                    "mode": "2pass-offline"
                                }
                                await websocket.send(json.dumps(response))
                                print(f"[{client_id}] 识别结果: {result}")
                            
                            # 发送关闭信号
                            await websocket.close()
                    
                    except json.JSONDecodeError:
                        print(f"[{client_id}] 无效的 JSON 消息")
                
                # 处理二进制消息（音频数据）
                elif isinstance(message, bytes):
                    if is_speaking:
                        audio_buffer.extend(message)
                    else:
                        print(f"[{client_id}] 收到音频数据但未处于说话状态")
        
        except websockets.exceptions.ConnectionClosed:
            print(f"[{client_id}] 连接已关闭")
        except Exception as e:
            print(f"[{client_id}] 错误: {e}")
            import traceback
            traceback.print_exc()
    
    async def recognize(self, audio_data):
        """识别音频数据"""
        try:
            # 将 PCM 数据转换为 float32 数组 (假设是 16kHz, 16bit, mono)
            audio_int16 = np.frombuffer(audio_data, dtype=np.int16)
            audio_float32 = audio_int16.astype(np.float32) / 32768.0
            
            # 调用模型进行识别
            # AutoModel 返回格式: [{"text": "识别结果"}]
            result = self.model.generate(
                input=[audio_float32],
                batch_size_s=300  # 批量大小(秒)
            )
            
            # 提取识别文本
            if result and len(result) > 0:
                text = result[0].get('text', '')
                return text
            else:
                return ""
        
        except Exception as e:
            print(f"识别错误: {e}")
            import traceback
            traceback.print_exc()
            return ""
    
    async def start(self):
        """启动 WebSocket 服务器"""
        # 加载模型
        self.load_model()
        
        # 启动 WebSocket 服务器
        print(f"\n启动 WebSocket 服务器 ws://{self.host}:{self.port}")
        print("等待客户端连接...\n")
        
        async with websockets.serve(
            self.handle_client,
            self.host,
            self.port,
            max_size=10 * 1024 * 1024,  # 10MB
            ping_interval=None  # 禁用 ping/pong
        ):
            await asyncio.Future()  # 永远运行

def main():
    if len(sys.argv) < 2:
        print("用法: python funasr_websocket_server.py <model_dir> [port] [host]")
        sys.exit(1)
    
    model_dir = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 10095
    host = sys.argv[3] if len(sys.argv) > 3 else "0.0.0.0"
    
    # 验证模型目录
    if not os.path.exists(model_dir):
        print(f"错误: 模型目录不存在: {model_dir}")
        sys.exit(1)
    
    server = FunASRServer(model_dir, host, port)
    
    try:
        asyncio.run(server.start())
    except KeyboardInterrupt:
        print("\n服务器已停止")
    except Exception as e:
        print(f"服务器错误: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()
PYTHON_EOF

echo -e "${YELLOW}启动 FunASR WebSocket 服务器...${NC}"
echo -e "${YELLOW}按 Ctrl+C 停止服务${NC}"
echo ""

# 启动服务器
python3 /tmp/funasr_websocket_server.py "$FUNASR_MODEL_DIR" "$FUNASR_PORT" "$HOST_IP"
