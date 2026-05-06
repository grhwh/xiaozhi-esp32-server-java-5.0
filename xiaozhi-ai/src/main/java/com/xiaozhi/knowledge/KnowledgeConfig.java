package com.xiaozhi.knowledge;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

import lombok.Data;

/**
 * 知识库配置类
 *
 * @author xiaozhi
 * @since 5.0.0
 */
@Data
@Configuration
@ConfigurationProperties(prefix = "knowledge.base")
public class KnowledgeConfig {

    /**
     * 是否启用知识库功能
     */
    private boolean enabled = true;

    /**
     * 知识库根目录路径
     */
    private String path = "./knowledge-base";

    /**
     * 文本分块大小（字符数）
     */
    private int chunkSize = 500;

    /**
     * 相似度阈值（0-1）
     */
    private double similarityThreshold = 0.8;

    /**
     * 向量存储文件路径
     */
    private String vectorStorePath = "./data/knowledge-vector-store.json";

    /**
     * ONNX Embedding 模型路径
     */
    private String embeddingModelPath = "./models/embedding-model.onnx";

    /**
     * 词表文件路径
     */
    private String vocabPath = "./models/vocab.txt";

    /**
     * 获取知识库音频目录路径
     */
    public String getAudioPath() {
        return path + "/audio";
    }

    /**
     * 获取知识库文本目录路径
     */
    public String getTextPath() {
        return path + "/text";
    }
}