package com.xiaozhi.knowledge;

import lombok.extern.slf4j.Slf4j;
import org.springframework.ai.document.Document;
import org.springframework.ai.vectorstore.SearchRequest;
import org.springframework.ai.vectorstore.VectorStore;
import org.springframework.stereotype.Service;

import jakarta.annotation.Resource;
import java.util.List;
import java.util.Optional;

/**
 * 知识库检索服务
 * 负责执行向量相似度检索，返回音频路径
 *
 * @author xiaozhi
 * @since 5.0.0
 */
@Slf4j
@Service
public class KnowledgeSearchService {

    @Resource
    private KnowledgeBaseLoader loader;

    @Resource
    private KnowledgeConfig config;

    /**
     * 知识库检索
     *
     * @param query 用户查询文本
     * @return 音频文件路径，未命中返回 Optional.empty()
     */
    public Optional<String> search(String query) {
        if (!config.isEnabled()) {
            return Optional.empty();
        }

        try {
            VectorStore vectorStore = loader.getVectorStore();
            if (vectorStore == null) {
                log.warn("VectorStore 未初始化");
                return Optional.empty();
            }

            // 执行相似度搜索，设置相似度阈值和 TopK
            SearchRequest request = SearchRequest.builder()
                .query(query)
                .topK(1)
                .similarityThreshold(config.getSimilarityThreshold())
                .build();

            List<Document> results = vectorStore.similaritySearch(request);

            if (results.isEmpty()) {
                log.debug("知识库未命中: query={}", query);
                return Optional.empty();
            }

            Document topResult = results.get(0);
            String audioPath = (String) topResult.getMetadata().get("audioPath");

            log.info("知识库命中: query={}, audioPath={}, content={}",
                query, audioPath, topResult.getText().substring(0, Math.min(50, topResult.getText().length())));

            return Optional.ofNullable(audioPath);

        } catch (Exception e) {
            log.error("知识库检索失败: query={}", query, e);
            return Optional.empty();
        }
    }
}