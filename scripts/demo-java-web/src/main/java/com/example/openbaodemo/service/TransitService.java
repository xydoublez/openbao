package com.example.openbaodemo.service;

import com.example.openbaodemo.config.OpenBaoProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.vault.core.VaultTemplate;
import org.springframework.vault.support.VaultTransitContext;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Map;

/**
 * OpenBao Transit 加密/解密服务
 *
 * 使用 OpenBao Transit 引擎实现 Encryption-as-a-Service：
 * - 应用不持有加密密钥，密钥由 OpenBao 管理
 * - 支持密钥自动轮转（OpenBao 侧配置）
 * - 加密后的密文格式: vault:v1:xxxxx (v1 表示密钥版本)
 */
@Service
public class TransitService {

    private static final Logger log = LoggerFactory.getLogger(TransitService.class);

    private final VaultTemplate vaultTemplate;
    private final String keyName;

    public TransitService(VaultTemplate vaultTemplate, OpenBaoProperties properties) {
        this.vaultTemplate = vaultTemplate;
        this.keyName = properties.getTransitKey();
    }

    /**
     * 加密明文数据
     *
     * @param plaintext 明文字符串
     * @return 密文 (格式: vault:v1:xxxxx)
     */
    public String encrypt(String plaintext) {
        String encoded = Base64.getEncoder().encodeToString(
                plaintext.getBytes(StandardCharsets.UTF_8));

        Map<String, String> request = Map.of("plaintext", encoded);
        Map<String, Object> response = vaultTemplate.write(
                "transit/encrypt/" + keyName, request, Map.class);

        if (response == null || !response.containsKey("data")) {
            throw new RuntimeException("OpenBao 加密失败: 响应为空");
        }

        @SuppressWarnings("unchecked")
        Map<String, String> data = (Map<String, String>) response.get("data");
        String ciphertext = data.get("ciphertext");

        log.debug("加密成功: plaintext长度={}, ciphertext={}",
                plaintext.length(), ciphertext.substring(0, Math.min(30, ciphertext.length())) + "...");
        return ciphertext;
    }

    /**
     * 解密密文数据
     *
     * @param ciphertext 密文 (格式: vault:v1:xxxxx)
     * @return 明文字符串
     */
    public String decrypt(String ciphertext) {
        Map<String, String> request = Map.of("ciphertext", ciphertext);
        Map<String, Object> response = vaultTemplate.write(
                "transit/decrypt/" + keyName, request, Map.class);

        if (response == null || !response.containsKey("data")) {
            throw new RuntimeException("OpenBao 解密失败: 响应为空");
        }

        @SuppressWarnings("unchecked")
        Map<String, String> data = (Map<String, String>) response.get("data");
        String encoded = data.get("plaintext");

        String plaintext = new String(
                Base64.getDecoder().decode(encoded), StandardCharsets.UTF_8);

        log.debug("解密成功: ciphertext={}, plaintext长度={}",
                ciphertext.substring(0, Math.min(30, ciphertext.length())) + "...",
                plaintext.length());
        return plaintext;
    }

    /**
     * 批量加密 (性能更好)
     */
    public java.util.List<String> batchEncrypt(java.util.List<String> plaintexts) {
        java.util.List<Map<String, String>> batch = plaintexts.stream()
                .map(pt -> Map.of("plaintext",
                        Base64.getEncoder().encodeToString(pt.getBytes(StandardCharsets.UTF_8))))
                .toList();

        Map<String, Object> request = Map.of("batch", batch);
        Map<String, Object> response = vaultTemplate.write(
                "transit/encrypt/" + keyName, request, Map.class);

        @SuppressWarnings("unchecked")
        java.util.List<Map<String, String>> results =
                (java.util.List<Map<String, String>>) ((Map<String, Object>) response.get("data")).get("batch");

        return results.stream()
                .map(r -> r.get("ciphertext"))
                .toList();
    }
}
