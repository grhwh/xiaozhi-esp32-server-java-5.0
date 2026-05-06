package com.xiaozhi.knowledge.embedding;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import lombok.extern.slf4j.Slf4j;

/**
 * 基于词表的分词器
 * 适用于中文 BERT 类模型（如 BAAI/bge-small-zh-v1.5）
 *
 * @author xiaozhi
 * @since 5.0.0
 */
@Slf4j
public class VocabularyTokenizer {

    private final Map<String, Integer> vocab;
    private final int padTokenId;
    private final int unkTokenId;
    private final int clsTokenId;
    private final int sepTokenId;

    /**
     * 构造函数
     *
     * @param vocabPath 词表文件路径
     * @throws IOException 文件读取异常
     */
    public VocabularyTokenizer(String vocabPath) throws IOException {
        this.vocab = loadVocab(vocabPath);
        this.padTokenId = vocab.getOrDefault("[PAD]", 0);
        this.unkTokenId = vocab.getOrDefault("[UNK]", 1);
        this.clsTokenId = vocab.getOrDefault("[CLS]", 2);
        this.sepTokenId = vocab.getOrDefault("[SEP]", 3);

        log.info("词表加载完成，词表大小: {}", vocab.size());
    }

    /**
     * 对文本进行分词
     *
     * @param text 待分词文本
     * @param maxLength 最大长度（包括 [CLS] 和 [SEP]）
     * @return 分词结果
     */
    public TokenizationResult tokenize(String text, int maxLength) {
        List<Integer> inputIds = new ArrayList<>();
        List<Integer> attentionMask = new ArrayList<>();

        // [CLS] token
        inputIds.add(clsTokenId);
        attentionMask.add(1);

        // 字符级分词（适合中文）
        for (char c : text.toCharArray()) {
            String token = String.valueOf(c);
            int id = vocab.getOrDefault(token, unkTokenId);
            inputIds.add(id);
            attentionMask.add(1);

            // 超过最大长度则截断（保留 [SEP] 位置）
            if (inputIds.size() >= maxLength - 1) {
                break;
            }
        }

        // [SEP] token
        inputIds.add(sepTokenId);
        attentionMask.add(1);

        // Padding 到最大长度
        while (inputIds.size() < maxLength) {
            inputIds.add(padTokenId);
            attentionMask.add(0);
        }

        return new TokenizationResult(
            inputIds.stream().mapToLong(Integer::longValue).toArray(),
            attentionMask.stream().mapToLong(Integer::longValue).toArray()
        );
    }

    /**
     * 加载词表文件
     *
     * @param path 词表文件路径
     * @return 词表映射
     * @throws IOException 文件读取异常
     */
    private Map<String, Integer> loadVocab(String path) throws IOException {
        Map<String, Integer> vocabMap = new HashMap<>();
        try (BufferedReader reader = new BufferedReader(new FileReader(path))) {
            String line;
            int index = 0;
            while ((line = reader.readLine()) != null) {
                vocabMap.put(line.trim(), index++);
            }
        }
        return vocabMap;
    }
}