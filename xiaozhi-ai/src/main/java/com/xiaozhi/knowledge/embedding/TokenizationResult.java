package com.xiaozhi.knowledge.embedding;

/**
 * 分词结果
 *
 * @param inputIds 输入ID序列
 * @param attentionMask 注意力掩码
 *
 * @author xiaozhi
 * @since 5.0.0
 */
public record TokenizationResult(long[] inputIds, long[] attentionMask) {
}