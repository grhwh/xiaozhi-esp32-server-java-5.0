#!/bin/bash
# FunASR WebSocket 服务启动脚本（已更新为官方 funasr_wss_server.py）
# 用于本地部署 FunASR 实时语音识别服务

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
# 如需自定义，取消下面注释并修改路径
export MODELSCOPE_CACHE="$PROJECT_ROOT/models/stt/FunASR/modelscope"

# 配置参数（使用项目根目录的模型路径）
FUNASR_MODEL_DIR="${1:-$PROJECT_ROOT/models/stt/FunASR}"
FUNASR_PORT="${2:-10095}"
HOST_IP="${3:-0.0.0.0}"
# CPU 核心数：根据实际并发需求调整
# - 单用户/测试环境: 1-2
# - 小团队 (3-5人): 2-4
# - 中等并发 (10+人): 4-8
PYTHON_CORES="${4:-2}"  # 默认 2 核，适合低并发场景

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
echo -e "${YELLOW}检查 FunASR 依赖...${NC}"

# 检查 funasr（官方 SDK，不是 funasr_onnx）
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

# 检查 onnxscript（必需依赖）
if python3 -c "import onnxscript" 2>/dev/null; then
    echo -e "${GREEN}✓ onnxscript 已安装${NC}"
else
    echo -e "${YELLOW}正在安装 onnxscript...${NC}"
    pip3 install onnxscript -q
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}尝试使用国内镜像源安装...${NC}"
        pip3 install onnxscript -i https://mirror.sjtu.edu.cn/pypi/web/simple -q
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: onnxscript 安装失败${NC}"
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
echo -e "${GREEN}  启动 FunASR WebSocket 服务${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "模型目录: ${GREEN}$FUNASR_MODEL_DIR${NC}"
echo -e "监听地址: ${GREEN}$HOST_IP:$FUNASR_PORT${NC}"
echo ""

# 检查端口是否被占用
if command -v lsof &> /dev/null; then
    if lsof -Pi :$FUNASR_PORT -sTCP:LISTEN -t >/dev/null 2>&1 ; then
        echo -e "${RED}错误: 端口 $FUNASR_PORT 已被占用${NC}"
        echo -e "${YELLOW}请使用其他端口或停止占用该端口的进程${NC}"
        exit 1
    fi
elif command -v netstat &> /dev/null; then
    if netstat -tuln | grep -q ":$FUNASR_PORT "; then
        echo -e "${RED}错误: 端口 $FUNASR_PORT 已被占用${NC}"
        echo -e "${YELLOW}请使用其他端口或停止占用该端口的进程${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✓ 端口 $FUNASR_PORT 可用${NC}"
echo ""

# 设置 Python 服务器脚本路径和日志路径
SERVER_SCRIPT="$SCRIPT_DIR/funasr_wss_server.py"
LOG_FILE="$PROJECT_ROOT/logs/funasr-server.log"

# 检查 Python 服务器文件是否存在
if [ ! -f "$SERVER_SCRIPT" ]; then
    echo -e "${RED}错误: 找不到 FunASR 服务器脚本: $SERVER_SCRIPT${NC}"
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

echo -e "${YELLOW}启动 FunASR WebSocket 服务器...${NC}"
echo -e "${YELLOW}按 Ctrl+C 停止服务${NC}"
echo -e "${YELLOW}日志文件: $LOG_FILE${NC}"
echo ""

# 设置清理函数
cleanup() {
    echo -e "\n${YELLOW}正在关闭服务器...${NC}"
    exit 0
}

trap cleanup EXIT INT TERM

# 启动服务器（同时输出到控制台和日志文件）
# FunASR 官方版本使用 argparse 参数
# 根据 CPU 核心数自动调整并发参数，禁用 SSL
echo -e "${YELLOW}启动命令: python3 $SERVER_SCRIPT --host $HOST_IP --port $FUNASR_PORT --device cpu --ngpu 0 --ncpu $PYTHON_CORES --certfile ''${NC}"
echo ""

python3 "$SERVER_SCRIPT" \
    --host "$HOST_IP" \
    --port "$FUNASR_PORT" \
    --device cpu \
    --ngpu 0 \
    --ncpu "$PYTHON_CORES" \
    --worker_threads "$((PYTHON_CORES * 2))" \
    --concurrent_vad "$PYTHON_CORES" \
    --concurrent_asr_online "$PYTHON_CORES" \
    --concurrent_asr_offline "$(( PYTHON_CORES / 2 > 0 ? PYTHON_CORES / 2 : 1 ))" \
    --concurrent_punc 1 \
    --concurrent_sv 1 \
    --certfile "" \
    2>&1 | tee -a "$LOG_FILE"
