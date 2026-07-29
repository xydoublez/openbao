package com.example.openbaodemo;

import java.util.Arrays;
import java.util.List;

/**
 * OpenBao Transit 加密/解密示例程序
 *
 * 演示:
 * 1. 单条加密 + 解密
 * 2. 批量加密 + 批量解密
 * 3. 验证加解密结果一致性
 *
 * ===================== 配置说明 =====================
 * 所有配置必须通过环境变量提供:
 *   export OPENBAO_ADDR="https://kms.msuncloud-internal.com"
 *   export OPENBAO_NAMESPACE="devops"
 *   export OPENBAO_ROLE_ID="a7e0a617-64f2-1944-bd9e-9ebe18bf54cb"
 *   export OPENBAO_SECRET_ID="6f7cb405-cbf5-1419-21c4-9991622c1fd0"
 *   export OPENBAO_TRANSIT_KEY="msun-devops-knowledge"
 *   export OPENBAO_TRANSIT_MOUNT="transit"
 *
 * 缺少任何环境变量将导致程序退出
 *
 * 运行:
 *   mvn clean package
 *   java -jar target/openbao-transit-example-1.0.0.jar
 *
 * ===================== API 端点 =====================
 * AppRole 登录:  POST /v1/auth/approle/login
 * 单条加密:      POST /v1/{transit_mount}/encrypt/{key_name}
 * 单条解密:      POST /v1/{transit_mount}/decrypt/{key_name}
 * 批量加密:      POST /v1/{transit_mount}/encrypt/{key_name}  (使用 batch_input)
 * 批量解密:      POST /v1/{transit_mount}/decrypt/{key_name}  (使用 batch_input)
 */
public class OpenBaoTransitExample {

    // ==================== 配置 (全部从环境变量获取, 缺失则退出) ====================
    private static final String ADDR          = requireEnv("OPENBAO_ADDR");
    private static final String NAMESPACE     = requireEnv("OPENBAO_NAMESPACE");
    private static final String ROLE_ID       = requireEnv("OPENBAO_ROLE_ID");
    private static final String SECRET_ID     = requireEnv("OPENBAO_SECRET_ID");
    private static final String TRANSIT_KEY   = requireEnv("OPENBAO_TRANSIT_KEY");
    private static final String TRANSIT_MOUNT = requireEnv("OPENBAO_TRANSIT_MOUNT");

    public static void main(String[] args) {
        System.out.println("╔══════════════════════════════════════════════════════════╗");
        System.out.println("║       OpenBao Transit 加密/解密示例 (Java)             ║");
        System.out.println("╚══════════════════════════════════════════════════════════╝");
        System.out.println();

        // 打印配置
        System.out.println(">>> 配置信息 (来自环境变量):");
        System.out.println("    OPENBAO_ADDR          = " + ADDR);
        System.out.println("    OPENBAO_NAMESPACE     = " + NAMESPACE);
        System.out.println("    OPENBAO_TRANSIT_KEY   = " + TRANSIT_KEY);
        System.out.println("    OPENBAO_TRANSIT_MOUNT = " + TRANSIT_MOUNT);
        System.out.println("    OPENBAO_ROLE_ID       = " + ROLE_ID.substring(0, Math.min(8, ROLE_ID.length())) + "...");
        System.out.println();

        // 创建客户端
        OpenBaoTransitClient client = new OpenBaoTransitClient(
                ADDR, NAMESPACE, ROLE_ID, SECRET_ID, TRANSIT_MOUNT, TRANSIT_KEY);

        try {
            // ========== 1. AppRole 登录 ==========
            System.out.println(">>> [Step 1] AppRole 登录...");
            client.login();
            System.out.println("    登录成功!");
            System.out.println();

            // ========== 2. 单条加密 + 解密 ==========
            demoSingleEncryptDecrypt(client);

            // ========== 3. 批量加密 + 批量解密 ==========
            demoBatchEncryptDecrypt(client);

            System.out.println("╔══════════════════════════════════════════════════════════╗");
            System.out.println("║              所有示例执行完成!                           ║");
            System.out.println("╚══════════════════════════════════════════════════════════╝");

        } catch (Exception e) {
            System.err.println("执行失败: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }

    // ==================== 单条加密/解密示例 ====================

    /**
     * 单条加密 + 解密
     *
     * 流程:
     *   明文 "Hello OpenBao!"
     *     → Base64 编码 → "SGVsbG8gT3BlbkJhb8Oh"
     *     → POST /v1/transit/encrypt/msun-devops-knowledge {"plaintext": "SGVsbG8g..."}
     *     → 返回密文 "vault:v1:xxxxx"
     *     → POST /v1/transit/decrypt/msun-devops-knowledge {"ciphertext": "vault:v1:xxxxx"}
     *     → 返回 Base64 编码的明文 → Base64 解码 → "Hello OpenBao!"
     */
    private static void demoSingleEncryptDecrypt(OpenBaoTransitClient client) throws Exception {
        System.out.println(">>> [Step 2] 单条加密 + 解密");
        System.out.println("    ─────────────────────────────────────────");

        String[] testTexts = {
                "Hello OpenBao!",
                "数据库密码: P@ssw0rd#2024",
                "{\"apiKey\":\"sk-xxxxx\",\"endpoint\":\"https://api.example.com\"}"
        };

        for (String original : testTexts) {
            System.out.println("    原文: " + truncate(original, 50));

            // 加密
            String ciphertext = client.encrypt(original);
            System.out.println("    密文: " + truncate(ciphertext, 60));

            // 解密
            String decrypted = client.decrypt(ciphertext);
            System.out.println("    解密: " + truncate(decrypted, 50));

            // 验证
            boolean match = original.equals(decrypted);
            System.out.println("    验证: " + (match ? "PASS" : "FAIL"));
            System.out.println();
        }
    }

    // ==================== 批量加密/解密示例 ====================

    /**
     * 批量加密 + 批量解密
     *
     * 使用 batch_input 参数, 一次 HTTP 请求处理多条数据, 减少网络开销
     *
     * 加密请求体:
     * {
     *   "batch_input": [
     *     {"plaintext": "<base64_1>"},
     *     {"plaintext": "<base64_2>"},
     *     {"plaintext": "<base64_3>"}
     *   ]
     * }
     *
     * 加密响应体:
     * {
     *   "data": {
     *     "batch_results": [
     *       {"ciphertext": "vault:v1:xxx1"},
     *       {"ciphertext": "vault:v1:xxx2"},
     *       {"ciphertext": "vault:v1:xxx3"}
     *     ]
     *   }
     * }
     *
     * 解密请求体:
     * {
     *   "batch_input": [
     *     {"ciphertext": "vault:v1:xxx1"},
     *     {"ciphertext": "vault:v1:xxx2"},
     *     {"ciphertext": "vault:v1:xxx3"}
     *   ]
     * }
     */
    private static void demoBatchEncryptDecrypt(OpenBaoTransitClient client) throws Exception {
        System.out.println(">>> [Step 3] 批量加密 + 批量解密");
        System.out.println("    ─────────────────────────────────────────");

        // 准备 5 条测试数据 (模拟实际业务场景: 批量加密数据库字段)
        List<String> originalTexts = Arrays.asList(
                "user_001:password_abc123",
                "user_002:password_def456",
                "user_003:password_ghi789",
                "api_key_prod_xxxxxxxxxxxx",
                "db_connection_string=jdbc:mysql://host:3306/mydb"
        );

        System.out.println("    准备 " + originalTexts.size() + " 条明文数据:");
        for (int i = 0; i < originalTexts.size(); i++) {
            System.out.println("      [" + i + "] " + originalTexts.get(i));
        }
        System.out.println();

        // === 批量加密 (一次 HTTP 请求) ===
        long start = System.currentTimeMillis();
        List<String> ciphertexts = client.batchEncrypt(originalTexts);
        long encryptTime = System.currentTimeMillis() - start;

        System.out.println("    批量加密完成 (" + encryptTime + "ms), " + ciphertexts.size() + " 条密文:");
        for (int i = 0; i < ciphertexts.size(); i++) {
            System.out.println("      [" + i + "] " + truncate(ciphertexts.get(i), 55));
        }
        System.out.println();

        // === 批量解密 (一次 HTTP 请求) ===
        start = System.currentTimeMillis();
        List<String> decryptedTexts = client.batchDecrypt(ciphertexts);
        long decryptTime = System.currentTimeMillis() - start;

        System.out.println("    批量解密完成 (" + decryptTime + "ms), " + decryptedTexts.size() + " 条明文:");
        for (int i = 0; i < decryptedTexts.size(); i++) {
            System.out.println("      [" + i + "] " + decryptedTexts.get(i));
        }
        System.out.println();

        // === 验证所有数据一致性 ===
        System.out.println("    验证一致性:");
        boolean allMatch = true;
        for (int i = 0; i < originalTexts.size(); i++) {
            boolean match = originalTexts.get(i).equals(decryptedTexts.get(i));
            System.out.println("      [" + i + "] " + (match ? "PASS" : "FAIL"));
            if (!match) allMatch = false;
        }
        System.out.println("    总结: " + (allMatch ? "ALL PASS" : "SOME FAILED"));
        System.out.println();
    }

    // ==================== 工具方法 ====================

    /**
     * 从环境变量获取配置, 缺失则打印提示并退出
     */
    private static String requireEnv(String key) {
        String value = System.getenv(key);
        if (value == null || value.isEmpty()) {
            System.err.println("错误: 环境变量 " + key + " 未设置");
            System.err.println("请执行: export " + key + "=<value>");
            System.exit(1);
        }
        return value;
    }

    private static String truncate(String s, int maxLen) {
        if (s == null) return "null";
        return s.length() > maxLen ? s.substring(0, maxLen) + "..." : s;
    }
}
