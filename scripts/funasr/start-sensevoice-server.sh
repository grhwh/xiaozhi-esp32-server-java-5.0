#!/bin/bash
# SenseVoiceSmall WebSocket 服务启动脚本
# 基于 FunASR 框架的轻量级多语言语音识别服务
# 支持情感识别、事件检测，推理速度极快

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 设置 ModelScope 缓存目录（可选，默认 ~/.cache/modelscope）
export MODELSCOPE_CACHE="$PROJECT_ROOT/models/stt/SenseVoiceSmall/modelscope"

# 配置参数（使用项目根目录的模型路径）
SENSEVOICE_MODEL_DIR="${1:-$PROJECT_ROOT/models/stt/SenseVoiceSmall}"
SENSEVOICE_PORT="${2:-10095}"
HOST_IP="${3:-0.0.0.0}"
# CPU 核心数：SenseVoiceSmall 更轻量，可适当提高并发
# - 单用户/测试环境: 1-2
# - 小团队 (3-5人): 2-4
# - 中等并发 (10+人): 4-8
PYTHON_CORES="${4:-2}"  # 默认 2 核，SenseVoiceSmall 更高效

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  SenseVoiceSmall WebSocket 服务启动脚本${NC}"
echo -e "${GREEN}  (轻量高效 - 多语言支持)${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}资源配置说明:${NC}"
echo -e "  - CPU核心: ${GREEN}$PYTHON_CORES 核${NC}"
echo -e "  - 工作线程: ${GREEN}2${NC} (SenseVoiceSmall 更快)"
echo -e "  - VAD模型: ${RED}已禁用${NC} (Java端处理)"
echo -e "  - 在线ASR: ${YELLOW}批量模式${NC} (说完后统一识别)"
echo -e "  - 离线ASR: ${GREEN}极速识别${NC} (10秒音频仅需70ms)"
echo -e "  - 情感识别: ${GREEN}已启用${NC} (自动标注情绪)"
echo -e "  - 事件检测: ${GREEN}已启用${NC} (笑声/掌声/BGM等)"
echo -e "  - 多语言支持: ${GREEN}50+语言${NC} (中英日韩粤等)"
echo -e "  - 预计内存: ${GREEN}~600-800MB${NC} (比FunASR更低)"
echo ""

# 检查 Python 版本
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}错误: 未找到 python3，请先安装 Python 3.10+${NC}"
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)

if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 10 ]); then
    echo -e "${RED}错误: Python 版本过低 ($PYTHON_VERSION)，需要 Python 3.10+${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Python3 版本: $PYTHON_VERSION${NC}"
echo ""

# 检查并安装依赖
echo -e "${YELLOW}检查 SenseVoiceSmall 依赖...${NC}"

# 检查 funasr（官方 SDK）
if python3 -c "import funasr" 2>/dev/null; then
    echo -e "${GREEN}✓ funasr 已安装${NC}"
else
    echo -e "${YELLOW}正在安装 funasr...${NC}"
    pip3 install funasr -q
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}尝试使用国内镜像源安装...${NC}"
        pip3 install funasr -i https://mirror.sjtu.edu.cn/pypi/web/simple -q
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: funasr 安装失败${NC}"
            exit 1
        fi
    fi
fi

# 检查 modelscope（用于下载模型）
if python3 -c "import modelscope" 2>/dev/null; then
    echo -e "${GREEN}✓ modelscope 已安装${NC}"
else
    echo -e "${YELLOW}正在安装 modelscope...${NC}"
    pip3 install modelscope -q
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}尝试使用国内镜像源安装...${NC}"
        pip3 install modelscope -i https://mirror.sjtu.edu.cn/pypi/web/simple -q
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: modelscope 安装失败${NC}"
            exit 1
        fi
    fi
fi

# 检查 websockets
if python3 -c "import websockets" 2>/dev/null; then
    echo -e "${GREEN}✓ websockets 已安装${NC}"
else
    echo -e "${YELLOW}正在安装 websockets...${NC}"
    pip3 install websockets -q
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: websockets 安装失败${NC}"
        exit 1
    fi
fi

# 检查 numpy
if python3 -c "import numpy" 2>/dev/null; then
    echo -e "${GREEN}✓ numpy 已安装${NC}"
else
    echo -e "${YELLOW}正在安装 numpy...${NC}"
    pip3 install numpy -q
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: numpy 安装失败${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  启动 SenseVoiceSmall WebSocket 服务${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "监听地址: ${GREEN}$HOST_IP:$SENSEVOICE_PORT${NC}"
echo -e "日志文件: ${GREEN}$PROJECT_ROOT/logs/sensevoice-server.log${NC}"
echo ""

# 检查端口是否被占用
if command -v lsof &> /dev/null; then
    if lsof -Pi :$SENSEVOICE_PORT -sTCP:LISTEN -t >/dev/null 2>&1 ; then
        echo -e "${RED}错误: 端口 $SENSEVOICE_PORT 已被占用${NC}"
        echo -e "${YELLOW}请使用其他端口或停止占用该端口的进程${NC}"
        exit 1
    fi
elif command -v netstat &> /dev/null; then
    if netstat -tuln | grep -q ":$SENSEVOICE_PORT "; then
        echo -e "${RED}错误: 端口 $SENSEVOICE_PORT 已被占用${NC}"
        echo -e "${YELLOW}请使用其他端口或停止占用该端口的进程${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✓ 端口 $SENSEVOICE_PORT 可用${NC}"
echo ""

# 设置 Python 服务器脚本路径和日志路径
SERVER_SCRIPT="$SCRIPT_DIR/sensevoice_wss_server.py"
LOG_FILE="$PROJECT_ROOT/logs/sensevoice-server.log"

# 检查 Python 服务器文件是否存在
if [ ! -f "$SERVER_SCRIPT" ]; then
    echo -e "${RED}错误: 找不到 SenseVoiceSmall 服务器脚本: $SERVER_SCRIPT${NC}"
    exit 1
fi

# 确保 Python 脚本有执行权限
if [ ! -x "$SERVER_SCRIPT" ]; then
    echo -e "${YELLOW}正在为 Python 脚本添加执行权限...${NC}"
    chmod +x "$SERVER_SCRIPT"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 无法添加执行权限${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ 执行权限已添加${NC}"
fi

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"

echo -e "${YELLOW}启动 SenseVoiceSmall WebSocket 服务器...${NC}"
echo -e "${YELLOW}按 Ctrl+C 停止服务${NC}"
echo -e "${YELLOW}首次启动会自动下载模型 (~300MB)，请耐心等待...${NC}"
echo ""

# 设置清理函数
cleanup() {
    echo -e "\n${YELLOW}正在关闭服务器...${NC}"
    exit 0
}

trap cleanup EXIT INT TERM

# 启动服务器（同时输出到控制台和日志文件）
# SenseVoiceSmall 优化配置：更高并发，禁用标点模型（自带标点）
echo -e "${YELLOW}启动命令: python3 $SERVER_SCRIPT --host $HOST_IP --port $SENSEVOICE_PORT --device cpu --ngpu 0 --ncpu $PYTHON_CORES --certfile ''${NC}"
echo ""

python3 -u "$SERVER_SCRIPT" \
    --host "$HOST_IP" \
    --port "$SENSEVOICE_PORT" \
    --device cpu \
    --ngpu 0 \
    --ncpu "$PYTHON_CORES" \
    --worker_threads 2 \
    --concurrent_vad 0 \
    --concurrent_asr_online 2 \
    --concurrent_asr_offline 2 \
    --concurrent_punc 0 \
    --concurrent_sv 0 \
    --certfile "" \
    2>&1 | tee -a "$LOG_FILE"
