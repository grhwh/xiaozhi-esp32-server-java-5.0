package com.xiaozhi.knowledge;

import com.xiaozhi.knowledge.embedding.LocalEmbeddingModel;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.ai.embedding.EmbeddingRequest;
import org.springframework.ai.embedding.EmbeddingResponse;
import org.springframework.ai.vectorstore.SimpleVectorStore;
import org.springframework.ai.vectorstore.VectorStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.List;
import java.util.stream.Collectors;

/**
 * 知识库向量存储配置
 * 配置 Spring AI 的 SimpleVectorStore Bean
 *
 * @author xiaozhi
 * @since 5.0.0
 */
@Configuration
@ConditionalOnProperty(prefix = "knowledge.base", name = "enabled", havingValue = "true")
public class KnowledgeVectorStoreConfig {

    /**
     * 创建本地 Embedding 模型 Bean
     *
     * @param modelPath ONNX 模型文件路径
     * @param vocabPath 词表文件路径
     * @return LocalEmbeddingModel 实例
     * @throws Exception 模型加载异常
     */
    @Bean
    public LocalEmbeddingModel localEmbeddingModel(
            @Value("${knowledge.base.embedding-model-path}") String modelPath,
            @Value("${knowledge.base.vocab-path}") String vocabPath) throws Exception {
        return new LocalEmbeddingModel(modelPath, vocabPath);
    }

    /**
     * 创建 VectorStore Bean
     *
     * @param localEmbeddingModel 本地 Embedding 模型
     * @return VectorStore 实例
     */
    @Bean
    public VectorStore knowledgeVectorStore(LocalEmbeddingModel localEmbeddingModel) {
        // 创建 EmbeddingModel 适配器
        EmbeddingModel embeddingModelAdapter = createEmbeddingModelAdapter(localEmbeddingModel);

        // 使用 SimpleVectorStore.builder() 创建实例
        return SimpleVectorStore.builder(embeddingModelAdapter).build();
    }

    /**
     * 创建 EmbeddingModel 适配器（适配 Spring AI 接口）
     *
     * @param localEmbeddingModel 本地 Embedding 模型
     * @return EmbeddingModel 适配器
     */
    private EmbeddingModel createEmbeddingModelAdapter(LocalEmbeddingModel localEmbeddingModel) {
        return new EmbeddingModel() {
            @Override
            public EmbeddingResponse call(EmbeddingRequest request) {
                List<float[]> embeddings = request.getInstructions().stream()
                    .map(instruction -> localEmbeddingModel.embed(instruction))
                    .collect(Collectors.toList());

                return new EmbeddingResponse(
                    embeddings.stream()
                        .map(emb -> new org.springframework.ai.embedding.Embedding(emb, 0, null))
                        .collect(Collectors.toList())
                );
            }

            @Override
            public float[] embed(Document document) {
                return localEmbeddingModel.embed(document.getText());
            }
        };
    }
}