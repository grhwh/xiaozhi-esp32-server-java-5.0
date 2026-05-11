package com.xiaozhi.communication.server.websocket;

import com.xiaozhi.communication.common.ChatSession;
import org.springframework.web.socket.BinaryMessage;
import org.springframework.web.socket.TextMessage;

import java.io.IOException;

import lombok.extern.slf4j.Slf4j;

@Slf4j
public class WebSocketSession extends ChatSession {
    /**
     * 当前会话的链接 session
     */
    protected org.springframework.web.socket.WebSocketSession session;

    /**
     * 用于同步发送消息的锁对象，防止并发发送导致UTF-8多字节字符损坏
     */
    private final Object sendLock = new Object();

    public WebSocketSession(String sessionId) {
        super(sessionId);
    }

    public WebSocketSession(org.springframework.web.socket.WebSocketSession session) {
        super(session.getId());
        this.session = session;
    }

    @Override
    public String getSessionId() {
        return session.getId();
    }

    public org.springframework.web.socket.WebSocketSession getSession() {
        return this.session;
    }

    @Override
    public void close() {
        if(session != null){
            try {
                session.close();
            } catch (IOException e) {
                log.error("关闭WebSocket会话时发生错误 - SessionId: {}", getSessionId(), e);
            }
        }
    }

    @Override
    public boolean isOpen() {
        return session.isOpen();
    }

    @Override
    public boolean isAudioChannelOpen() {
        return session.isOpen();
    }

    @Override
    public void sendTextMessage(String message) {
        // 使用同步锁确保消息按顺序发送，避免UTF-8多字节字符在并发发送时被截断或错乱
        synchronized (sendLock) {
            try {
                // 排查中文缺失问题：记录最终发送的消息详情
                log.info("【WebSocket最终发送】SessionId: {}, 消息长度: {}, 消息内容: [{}], 字节数: {}", 
                    getSessionId(), 
                    message.length(), 
                    message,
                    message.getBytes(java.nio.charset.StandardCharsets.UTF_8).length);
                
                session.sendMessage(new TextMessage(message));
            } catch (IOException e) {
                log.error("发送Text消息失败, message: {}", message, e);
            }
        }
    }

    @Override
    public void sendBinaryMessage(byte[] message) {
        try {
            session.sendMessage(new BinaryMessage(message));
        } catch (IOException e) {
            log.error("发送Binary消息失败", e);
        }
    }
}
