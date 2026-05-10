#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SenseVoiceSmall WebSocket 服务器
基于 FunASR 框架，支持多语言语音识别、情感识别、事件检测
保持与 funasr_wss_server.py 相同的 WebSocket 协议，确保 Java 端兼容
"""

import asyncio
import json
import websockets
import time
import numpy as np
import argparse
import ssl
import os
import re
import logging
from concurrent.futures import ThreadPoolExecutor

# 配置日志级别为 ERROR
logging.basicConfig(level=logging.ERROR)
logger = logging.getLogger(__name__)

# 只在启动时打印必要信息
print("model loading")
from funasr import AutoModel  # noqa

parser = argparse.ArgumentParser()
parser.add_argument("--host", type=str, default="0.0.0.0", required=False, help="host ip")
parser.add_argument("--port", type=int, default=10095, required=False, help="grpc server port")

# SenseVoiceSmall 模型配置
parser.add_argument(
    "--asr_model",
    type=str,
    default="iic/SenseVoiceSmall",
    help="SenseVoiceSmall model from modelscope",
)
parser.add_argument("--asr_model_revision", type=str, default="master", help="model revision")

parser.add_argument("--ngpu", type=int, default=0, help="0 for cpu, 1 for gpu")
parser.add_argument("--device", type=str, default="cpu", help="cuda, cpu")
parser.add_argument("--ncpu", type=int, default=2, help="cpu cores")

parser.add_argument(
    "--certfile",
    type=str,
    default="",
    required=False,
    help="certfile for ssl",
)
parser.add_argument(
    "--keyfile",
    type=str,
    default="",
    required=False,
    help="keyfile for ssl",
)

# ====== 并发控制 ======
parser.add_argument(
    "--worker_threads",
    type=int,
    default=1,  # 降低默认值，减少资源消耗
    help="ThreadPoolExecutor max_workers",
)
parser.add_argument("--concurrent_vad", type=int, default=0, help="Max concurrent VAD calls (disabled)")
parser.add_argument("--concurrent_asr_online", type=int, default=1, help="Max concurrent streaming ASR calls")
parser.add_argument("--concurrent_asr_offline", type=int, default=1, help="Max concurrent offline ASR calls")
parser.add_argument("--concurrent_punc", type=int, default=0, help="Max concurrent punctuation calls (disabled)")
parser.add_argument("--concurrent_sv", type=int, default=0, help="Max concurrent speaker verification calls (disabled)")

args = parser.parse_args()

# Java端已处理VAD，跳过Python端的VAD检测
args.enable_vad = False

websocket_users = set()


def _pcm_duration_ms(pcm_bytes: bytes, fs: int, ch: int = 1, sampwidth: int = 2) -> int:
    """根据 fs/ch/sampwidth 计算 PCM 时长"""
    if not pcm_bytes:
        return 0
    bytes_per_ms = (fs * ch * sampwidth) / 1000.0
    if bytes_per_ms <= 0:
        return 0
    return int(len(pcm_bytes) / bytes_per_ms)


def _safe_int(v, default):
    try:
        return int(v)
    except Exception:
        return default


def clean_sensevoice_text(text: str) -> str:
    """
    清洗 SenseVoice 富文本标签
    移除语言标签、情感标签、事件标签，保留纯文本
    """
    if not text:
        return ""
    
    # 移除语言标签 <|zh|>, <|en|>, <|ja|>, <|ko|>, <|yue|>
    text = re.sub(r'<\|(zh|en|ja|ko|yue)\|>', '', text)
    
    # 移除情感标签 <|NEUTRAL|>, <|HAPPY|>, <|SAD|>, <|ANGRY|>
    text = re.sub(r'<\|(NEUTRAL|HAPPY|SAD|ANGRY)\|>', '', text)
    text = re.sub(r'<\/(NEUTRAL|HAPPY|SAD|ANGRY)\|>', '', text)
    
    # 移除事件标签 [laughter], [applause], [music], [cough], [sneeze]
    text = re.sub(r'\[(laughter|applause|music|cough|sneeze|breath)\]', '', text, flags=re.IGNORECASE)
    
    # 移除其他可能的特殊标记
    text = re.sub(r'<[^>]+>', '', text)
    
    return text.strip()


# 静默加载模型（禁用更新检查以加快启动速度）
model_asr = AutoModel(
    model=args.asr_model,
    model_revision=args.asr_model_revision,
    ngpu=args.ngpu,
    ncpu=args.ncpu,
    device=args.device,
    disable_pbar=True,
    disable_log=True,
    disable_update=True,  # 禁用版本检查，加快启动
    punc_model="iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch",  # 启用标点模型
)

# 在线流式模型（SenseVoiceSmall 不支持真正的流式，使用相同模型）
model_asr_streaming = model_asr

# 模型加载完成


# ====== 线程池 + 并发阈值 ======
EXECUTOR = ThreadPoolExecutor(max_workers=int(args.worker_threads))

SEM_VAD = asyncio.Semaphore(max(1, int(args.concurrent_vad))) if args.concurrent_vad > 0 else None
SEM_ASR_ONLINE = asyncio.Semaphore(max(1, int(args.concurrent_asr_online)))
SEM_ASR_OFFLINE = asyncio.Semaphore(max(1, int(args.concurrent_asr_offline)))
SEM_PUNC = asyncio.Semaphore(max(1, int(args.concurrent_punc))) if args.concurrent_punc > 0 else None
SEM_SV = asyncio.Semaphore(max(1, int(args.concurrent_sv))) if args.concurrent_sv > 0 else None


async def run_blocking(fn, *a, sem=None, **kw):
    """
    把阻塞函数丢线程池执行，避免卡 event loop。
    sem 用于限流（避免模型被打爆）。
    """
    import functools
    loop = asyncio.get_running_loop()
    call = functools.partial(fn, *a, **kw)
    if sem is None:
        return await loop.run_in_executor(EXECUTOR, call)
    async with sem:
        return await loop.run_in_executor(EXECUTOR, call)


def _generate_sync(model, audio_or_text, status_dict):
    """同步调用模型生成（启用标点）"""
    # 启用标点符号输出
    status_dict_with_punc = status_dict.copy()
    status_dict_with_punc["use_itn"] = True  # 启用逆文本标准化（包含标点）
    return model.generate(input=audio_or_text, **status_dict_with_punc)


async def ws_reset(websocket):
    """重置 WebSocket 连接状态"""
    websocket.status_dict_asr_online["cache"] = {}
    websocket.status_dict_asr_online["is_final"] = True
    websocket.status_dict_vad["cache"] = {}
    websocket.status_dict_vad["is_final"] = True
    websocket.status_dict_punc["cache"] = {}

    await websocket.close()


async def clear_websocket():
    """清理所有 WebSocket 连接"""
    for websocket in list(websocket_users):
        await ws_reset(websocket)
    websocket_users.clear()


async def ws_serve(websocket, path=None):
    """WebSocket 服务主逻辑"""
    # websockets 新版本不会传 path，这里做兼容
    if path is None:
        path = getattr(websocket, "path", None)
    
    frames = []
    frames_asr = []
    frames_asr_online = []
    global websocket_users
    websocket_users.add(websocket)

    websocket.status_dict_asr = {}  # hotword 等
    websocket.status_dict_asr_online = {"cache": {}, "is_final": False}
    websocket.status_dict_vad = {"cache": {}, "is_final": False}
    websocket.status_dict_punc = {"cache": {}}

    websocket.chunk_interval = 10
    websocket.vad_pre_idx = 0
    speech_start = False
    speech_end_i = -1

    websocket.wav_name = "microphone"
    websocket.mode = "2pass"
    websocket.is_speaking = True  # ✅ 默认初始化，避免 AttributeError

    # 保存离线片段
    websocket.audio_fs = 16000
    websocket.offline_seg_idx = 0

    try:
        async for message in websocket:
            # ========== 1) 先处理"文本配置消息" ==========
            if isinstance(message, str):
                try:
                    messagejson = json.loads(message)
                except Exception as e:
                    logger.error(f"bad json message: {e}")
                    continue

                if "is_speaking" in messagejson:
                    websocket.is_speaking = bool(messagejson["is_speaking"])
                    websocket.status_dict_asr_online["is_final"] = (not websocket.is_speaking)
                    
                    # 如果从 True 变为 False，立即触发识别
                    if not websocket.is_speaking and len(frames_asr) > 0:
                        if websocket.mode in ("2pass", "offline"):
                            audio_in = b"".join(frames_asr)
                            duration_ms_check = _pcm_duration_ms(audio_in, fs=websocket.audio_fs, ch=1, sampwidth=2)
                            
                            if duration_ms_check >= 100:
                                try:
                                    await async_asr(websocket, audio_in)
                                except Exception as e:
                                    logger.error(f"error in asr offline: {e}")
                        
                        # 重置状态
                        frames_asr = []
                        speech_start = False
                        frames_asr_online = []
                        websocket.status_dict_asr_online["cache"] = {}
                        websocket.vad_pre_idx = 0
                        frames = []
                        websocket.status_dict_vad["cache"] = {}
                        speech_end_i = -1
                        continue

                if "chunk_interval" in messagejson:
                    websocket.chunk_interval = _safe_int(
                        messagejson["chunk_interval"], websocket.chunk_interval
                    )

                if "wav_name" in messagejson:
                    websocket.wav_name = messagejson.get("wav_name") or websocket.wav_name

                if "chunk_size" in messagejson:
                    chunk_size = messagejson["chunk_size"]
                    if isinstance(chunk_size, str):
                        chunk_size = [x.strip() for x in chunk_size.split(",") if x.strip()]
                    websocket.status_dict_asr_online["chunk_size"] = [int(x) for x in chunk_size]

                if "encoder_chunk_look_back" in messagejson:
                    websocket.status_dict_asr_online["encoder_chunk_look_back"] = messagejson[
                        "encoder_chunk_look_back"
                    ]

                if "decoder_chunk_look_back" in messagejson:
                    websocket.status_dict_asr_online["decoder_chunk_look_back"] = messagejson[
                        "decoder_chunk_look_back"
                    ]

                if "hotwords" in messagejson:
                    hotword_data = messagejson["hotwords"]
                    websocket.status_dict_asr["hotword"] = hotword_data
                    websocket.status_dict_asr_online["hotword"] = hotword_data

                if "mode" in messagejson:
                    websocket.mode = messagejson["mode"] or websocket.mode

                if "audio_fs" in messagejson:
                    websocket.audio_fs = _safe_int(messagejson["audio_fs"], 16000)

                continue

            # ========== 2) 处理"二进制音频消息" ==========
            if "chunk_size" not in websocket.status_dict_asr_online:
                logger.warning("chunk_size not set yet, skip audio frame")
                continue
            
            try:
                websocket.status_dict_vad["chunk_size"] = int(
                    websocket.status_dict_asr_online["chunk_size"][1] * 60 / websocket.chunk_interval
                )
            except Exception as e:
                logger.error(f"set vad chunk_size failed: {e}")
                continue
            
            pcm = message
            frames.append(pcm)

            duration_ms = _pcm_duration_ms(pcm, fs=websocket.audio_fs, ch=1, sampwidth=2)
            websocket.vad_pre_idx += duration_ms

            # online asr (SenseVoiceSmall 不支持真流式，仅累积音频)
            frames_asr_online.append(pcm)
            websocket.status_dict_asr_online["is_final"] = (speech_end_i != -1)

            if (len(frames_asr_online) % websocket.chunk_interval == 0) or websocket.status_dict_asr_online["is_final"]:
                if websocket.mode in ("2pass", "online"):
                    audio_in = b"".join(frames_asr_online)
                    try:
                        await async_asr_online(websocket, audio_in)
                    except Exception as e:
                        logger.error(f"error in asr streaming: {e}")
                frames_asr_online = []

            # Java端已处理VAD，直接收集所有音频数据到 frames_asr
            frames_asr.append(pcm)

            # vad online (Java端已处理，跳过)
            speech_start_i, speech_end_i = -1, -1

            if speech_start_i != -1:
                speech_start = True
                if duration_ms > 0:
                    beg_bias = (websocket.vad_pre_idx - speech_start_i) // duration_ms
                else:
                    beg_bias = 0
                frames_pre = frames[-beg_bias:] if beg_bias > 0 else []
                frames_asr = []
                frames_asr.extend(frames_pre)

            # ========== 3) 2pass：离线阶段触发点 ==========
            if (speech_end_i != -1) or (not websocket.is_speaking):
                if websocket.mode in ("2pass", "offline"):
                    audio_in = b"".join(frames_asr)
                    
                    # SenseVoiceSmall 需要至少 0.1 秒音频才识别（降低阈值避免误跳过）
                    duration_ms_check = _pcm_duration_ms(audio_in, fs=websocket.audio_fs, ch=1, sampwidth=2)
                    if duration_ms_check < 100:
                        logger.warning(f"Audio too short: {duration_ms_check}ms, skipped")
                        frames_asr = []
                        speech_start = False
                        frames_asr_online = []
                        websocket.status_dict_asr_online["cache"] = {}
                        
                        if not websocket.is_speaking:
                            websocket.vad_pre_idx = 0
                            frames = []
                            websocket.status_dict_vad["cache"] = {}
                            speech_end_i = -1
                        else:
                            frames = frames[-20:]
                        continue

                    try:
                        await async_asr(websocket, audio_in)
                    except Exception as e:
                        logger.error(f"error in asr offline: {e}")

                frames_asr = []
                speech_start = False
                frames_asr_online = []
                websocket.status_dict_asr_online["cache"] = {}

                if not websocket.is_speaking:
                    websocket.vad_pre_idx = 0
                    frames = []
                    websocket.status_dict_vad["cache"] = {}
                    speech_end_i = -1
                else:
                    frames = frames[-20:]

    except websockets.ConnectionClosed:
        await ws_reset(websocket)
        if websocket in websocket_users:
            websocket_users.remove(websocket)
    except websockets.InvalidState:
        logger.error("InvalidState error")
    except Exception as e:
        logger.error(f"Exception in ws_serve: {e}", exc_info=True)
        try:
            await ws_reset(websocket)
        except Exception:
            pass
        if websocket in websocket_users:
            websocket_users.remove(websocket)


async def async_asr(websocket, audio_in: bytes):
    """离线 ASR 识别（SenseVoiceSmall 主要工作模式）"""
    mode = "2pass-offline" if "2pass" in (websocket.mode or "") else websocket.mode

    if len(audio_in) <= 0:
        message = {
            "mode": mode,
            "text": "",
            "wav_name": websocket.wav_name,
            "is_final": True,
        }
        await websocket.send(json.dumps(message, ensure_ascii=False))
        return

    # 1) ASR 识别（阻塞，线程池执行）
    rec_result_list = await run_blocking(
        _generate_sync,
        model_asr,
        audio_in,
        websocket.status_dict_asr,
        sem=SEM_ASR_OFFLINE,
    )
    rec_result = rec_result_list[0]

    text = rec_result.get("text", "")
    
    # 2) 清洗 SenseVoice 富文本标签
    text = clean_sensevoice_text(text)
    
    timestamp = rec_result.get("timestamp", None)
    sentence_info = rec_result.get("sentence_info", None)

    # 3) 构造最终 message（SenseVoiceSmall 不带声纹识别）
    if len(text) > 0:
        message = {
            "mode": mode,
            "text": text,
            "wav_name": websocket.wav_name,
            "is_final": True,
        }
        if timestamp is not None:
            message["timestamp"] = timestamp
        if sentence_info is not None:
            message["sentence_info"] = sentence_info

        try:
            await websocket.send(json.dumps(message, ensure_ascii=False))
        except Exception as e:
            logger.error(f"send json failed: {e}")
    else:
        message = {
            "mode": mode,
            "text": "",
            "wav_name": websocket.wav_name,
            "is_final": True,
        }
        await websocket.send(json.dumps(message, ensure_ascii=False))


async def async_asr_online(websocket, audio_in: bytes):
    """在线 ASR 识别（SenseVoiceSmall 伪流式，批量返回）"""
    if len(audio_in) <= 0:
        return

    # SenseVoiceSmall 不支持真流式，仅在 is_final 时返回结果
    if not websocket.status_dict_asr_online.get("is_final", False):
        return

    # streaming generate 也是阻塞：线程池执行
    rec_out = await run_blocking(
        _generate_sync,
        model_asr_streaming,
        audio_in,
        websocket.status_dict_asr_online,
        sem=SEM_ASR_ONLINE,
    )
    rec_result = rec_out[0]

    # 2pass：online 只要 partial，不发 final（final 交给 offline）
    if websocket.mode == "2pass" and websocket.status_dict_asr_online.get("is_final", False):
        return

    if rec_result.get("text"):
        # 清洗富文本标签
        text = clean_sensevoice_text(rec_result["text"])
        
        mode = "2pass-online" if "2pass" in (websocket.mode or "") else websocket.mode
        message = {
            "mode": mode,
            "text": text,
            "wav_name": websocket.wav_name,
            "is_final": bool(
                websocket.status_dict_asr_online.get("is_final", False) or (not websocket.is_speaking)
            ),
        }
        await websocket.send(json.dumps(message, ensure_ascii=False))


# ===================== 启动服务 =====================

async def main():
    if len(args.certfile) > 0:
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.load_cert_chain(args.certfile, keyfile=args.keyfile)
        server = await websockets.serve(
            ws_serve,
            args.host,
            args.port,
            ping_interval=None,
            ssl=ssl_context,
        )
    else:
        server = await websockets.serve(
            ws_serve,
            args.host,
            args.port,
            ping_interval=None,
        )

    print(f"SenseVoiceSmall WS server started at ws(s)://{args.host}:{args.port}")
    await server.wait_closed()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    finally:
        try:
            EXECUTOR.shutdown(wait=False, cancel_futures=True)
        except Exception:
            pass
