package com.xiaozhi.knowledge;

import com.xiaozhi.knowledge.embedding.LocalEmbeddingModel;
import jakarta.annotation.Resource;
import lombok.extern.slf4j.Slf4j;
import org.springframework.ai.document.Document;
import org.springframework.ai.vectorstore.SimpleVectorStore;
import org.springframework.ai.vectorstore.VectorStore;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.*;
import java.util.stream.Collectors;

/**
 * 知识库加载器
 * 负责在应用启动时加载知识库文件、文本分块、向量化并存储到 VectorStore
 *
 * @author xiaozhi
 * @since 5.0.0
 */
@Slf4j
@Service
public class KnowledgeBaseLoader {

    @Autowired(required = false)
    private LocalEmbeddingModel localEmbeddingModel;

    @Autowired(required = false)
    private VectorStore vectorStore;

    @Resource
    private KnowledgeConfig config;

    /**
     * 初始化方法：应用启动时自动执行
     */
    @PostConstruct
    public void init() {
        if (!config.isEnabled()) {
            log.info("知识库功能已禁用");
            return;
        }

        if (localEmbeddingModel == null) {
            log.warn("未配置本地 Embedding 模型，知识库功能不可用");
            return;
        }

        if (vectorStore == null) {
            log.warn("VectorStore 未注入，知识库功能不可用");
            return;
        }

        try {
            // 检查向量存储文件是否存在
            Path vectorStoreFile = Paths.get(config.getVectorStorePath());
            if (Files.exists(vectorStoreFile) && vectorStore instanceof SimpleVectorStore) {
                log.info("加载已有的向量存储文件: {}", config.getVectorStorePath());
                loadVectorStore(vectorStoreFile);
            } else {
                log.info("向量存储文件不存在，开始加载知识库文件并进行向量化");
                loadAndVectorize();
            }

            log.info("知识库加载完成");

        } catch (Exception e) {
            log.error("知识库加载失败", e);
        }
    }

    /**
     * 加载已有的向量存储文件
     */
    private void loadVectorStore(Path vectorStoreFile) {
        try {
            ((SimpleVectorStore) vectorStore).load(vectorStoreFile.toFile());
            log.info("向量存储文件加载成功");
        } catch (Exception e) {
            log.error("加载向量存储文件失败，将重新向量化", e);
            loadAndVectorize();
        }
    }

    /**
     * 加载文件并向量化
     */
    private void loadAndVectorize() {
        try {
            Path textDir = Paths.get(config.getTextPath());
            Path audioDir = Paths.get(config.getAudioPath());

            if (!Files.exists(textDir)) {
                log.warn("文本目录不存在: {}", textDir);
                return;
            }

            List<Document> allDocuments = new ArrayList<>();

            // 扫描文本文件
            Files.list(textDir)
                .filter(p -> p.toString().endsWith(".txt"))
                .forEach(textFile -> {
                    try {
                        String fileName = textFile.getFileName().toString();
                        String baseName = fileName.substring(0, fileName.lastIndexOf('.'));

                        // 查找对应的音频文件
                        Path audioFile = findAudioFile(audioDir, baseName);
                        if (audioFile == null) {
                            log.warn("未找到对应的音频文件: {}", baseName);
                            return;
                        }

                        // 读取文本内容
                        String content = Files.readString(textFile);

                        // 文本分块
                        List<String> chunks = splitIntoChunks(content, config.getChunkSize());

                        // 创建 Document 列表
                        for (int i = 0; i < chunks.size(); i++) {
                            Document doc = new Document(
                                baseName + "-chunk-" + i,
                                chunks.get(i),
                                Map.of(
                                    "audioPath", audioFile.toString(),
                                    "sourceFile", fileName,
                                    "chunkIndex", i
                                )
                            );
                            allDocuments.add(doc);
                        }

                        log.info("加载文本文件: {}, 分块数: {}", fileName, chunks.size());

                    } catch (Exception e) {
                        log.error("处理文本文件失败: {}", textFile, e);
                    }
                });

            if (!allDocuments.isEmpty()) {
                // 添加到 VectorStore
                vectorStore.add(allDocuments);

                // 持久化到文件
                saveVectorStore();

                log.info("知识库向量化完成，总文档数: {}", allDocuments.size());
            }

        } catch (Exception e) {
            log.error("加载知识库文件失败", e);
        }
    }

    /**
     * 查找音频文件（支持多种格式）
     */
    private Path findAudioFile(Path audioDir, String baseName) {
        String[] extensions = {".mp3", ".wav", ".ogg", ".opus", ".m4a"};
        for (String ext : extensions) {
            Path audioFile = audioDir.resolve(baseName + ext);
            if (Files.exists(audioFile)) {
                return audioFile;
            }
        }
        return null;
    }

    /**
     * 文本分块
     */
    private List<String> splitIntoChunks(String content, int chunkSize) {
        List<String> chunks = new ArrayList<>();

        // 简单按字符数分块
        for (int i = 0; i < content.length(); i += chunkSize) {
            int end = Math.min(i + chunkSize, content.length());
            chunks.add(content.substring(i, end));
        }

        return chunks;
    }

    /**
     * 保存向量存储到文件
     */
    private void saveVectorStore() {
        try {
            if (!(vectorStore instanceof SimpleVectorStore)) {
                log.warn("VectorStore 不是 SimpleVectorStore 类型，无法保存到文件");
                return;
            }
            Path vectorStoreFile = Paths.get(config.getVectorStorePath());
            Files.createDirectories(vectorStoreFile.getParent());
            ((SimpleVectorStore) vectorStore).save(vectorStoreFile.toFile());
            log.info("向量存储已保存到: {}", config.getVectorStorePath());
        } catch (IOException e) {
            log.error("保存向量存储失败", e);
        }
    }

    /**
     * 获取 VectorStore 实例
     */
    public VectorStore getVectorStore() {
        return vectorStore;
    }

    /**
     * 销毁方法：应用关闭时清理资源
     */
    @PreDestroy
    public void destroy() {
        if (localEmbeddingModel != null) {
            localEmbeddingModel.close();
        }
    }
}