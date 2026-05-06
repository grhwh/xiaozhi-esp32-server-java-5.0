package com.xiaozhi.knowledge.embedding;

import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtException;
import ai.onnxruntime.OrtSession;
import ai.onnxruntime.OnnxTensor;

import lombok.extern.slf4j.Slf4j;

import java.nio.LongBuffer;
import java.util.HashMap;
import java.util.Map;

/**
 * 本地 ONNX Embedding 模型
 * 使用 ONNX Runtime 进行文本向量化
 *
 * @author xiaozhi
 * @since 5.0.0
 */
@Slf4j
public class LocalEmbeddingModel {

    private final OrtEnvironment env;
    private final OrtSession session;
    private final VocabularyTokenizer tokenizer;

    /**
     * 构造函数
     *
     * @param modelPath ONNX 模型文件路径
     * @param vocabPath 词表文件路径
     * @throws OrtException ONNX Runtime 异常
     * @throws java.io.IOException 词表加载异常
     */
    public LocalEmbeddingModel(String modelPath, String vocabPath) throws OrtException, java.io.IOException {
        // 初始化 ONNX Runtime 环境
        this.env = OrtEnvironment.getEnvironment();

        // 创建会话
        OrtSession.SessionOptions options = new OrtSession.SessionOptions();
        this.session = env.createSession(modelPath, options);

        // 初始化分词器
        this.tokenizer = new VocabularyTokenizer(vocabPath);

        log.info("本地 Embedding 模型加载成功: {}", modelPath);
    }

    /**
     * 将文本转换为向量
     *
     * @param text 待向量化的文本
     * @return 向量数组
     */
    public float[] embed(String text) {
        try {
            // 1. 分词
            TokenizationResult tokens = tokenizer.tokenize(text, 512);

            // 2. 创建输入张量
            OnnxTensor inputIdsTensor = createTensor(tokens.inputIds());
            OnnxTensor attentionMaskTensor = createTensor(tokens.attentionMask());

            // 3. 执行推理
            Map<String, OnnxTensor> inputs = new HashMap<>();
            inputs.put("input_ids", inputIdsTensor);
            inputs.put("attention_mask", attentionMaskTensor);

            OrtSession.Result output = session.run(inputs);

            // 4. 获取输出向量并进行池化
            float[][][] embeddings = (float[][][]) output.get(0).getValue();
            float[] sentenceEmbedding = meanPooling(embeddings[0], tokens.attentionMask());

            // 5. 归一化
            normalize(sentenceEmbedding);

            // 清理资源
            inputIdsTensor.close();
            attentionMaskTensor.close();
            output.close();

            return sentenceEmbedding;

        } catch (OrtException e) {
            log.error("向量化失败: {}", text, e);
            throw new RuntimeException("Embedding failed", e);
        }
    }

    /**
     * 创建 ONNX 张量
     *
     * @param data 数据数组
     * @return ONNX 张量
     * @throws OrtException ONNX Runtime 异常
     */
    private OnnxTensor createTensor(long[] data) throws OrtException {
        LongBuffer buffer = LongBuffer.wrap(data);
        return OnnxTensor.createTensor(env, buffer, new long[]{1, data.length});
    }

    /**
     * 平均池化
     * 根据注意力掩码对 token embeddings 进行平均池化
     *
     * @param tokenEmbeddings token 级别的向量
     * @param attentionMask 注意力掩码
     * @return 句子级别的向量
     */
    private float[] meanPooling(float[][] tokenEmbeddings, long[] attentionMask) {
        int dim = tokenEmbeddings[0].length;
        float[] result = new float[dim];
        int count = 0;

        for (int i = 0; i < tokenEmbeddings.length; i++) {
            if (attentionMask[i] == 1) {
                for (int j = 0; j < dim; j++) {
                    result[j] += tokenEmbeddings[i][j];
                }
                count++;
            }
        }

        // 计算平均值
        if (count > 0) {
            for (int j = 0; j < dim; j++) {
                result[j] /= count;
            }
        }

        return result;
    }

    /**
     * 归一化向量（L2 归一化）
     *
     * @param vector 待归一化的向量
     */
    private void normalize(float[] vector) {
        float norm = 0;
        for (float v : vector) {
            norm += v * v;
        }
        norm = (float) Math.sqrt(norm);

        if (norm > 0) {
            for (int i = 0; i < vector.length; i++) {
                vector[i] /= norm;
            }
        }
    }

    /**
     * 关闭资源
     */
    public void close() {
        try {
            if (session != null) {
                session.close();
            }
        } catch (OrtException e) {
            log.error("关闭 ONNX Session 失败", e);
        }
    }
}