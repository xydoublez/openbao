package com.example.openbaodemo;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.*;
import java.util.stream.Collectors;

/**
 * OpenBao Transit 加密/解密客户端
 *
 * 功能:
 * - AppRole 认证 (自动登录获取 Token)
 * - 单条加密 / 解密
 * - 批量加密 / 解密 (batch_input)
 * - 支持 Namespace
 *
 * API 参考:
 *   POST /v1/{transit_mount}/encrypt/{key_name}  — 加密
 *   POST /v1/{transit_mount}/decrypt/{key_name}  — 解密
 *   POST /v1/auth/approle/login                  — AppRole 登录
 *
 * 注意: 所有明文数据必须 Base64 编码后再发送
 */
public class OpenBaoTransitClient {

    private static final Logger log = LoggerFactory.getLogger(OpenBaoTransitClient.class);

    private final String baseUrl;          // OpenBao 地址, 如 https://kms.msuncloud-internal.com
    private final String namespace;        // 命名空间, 如 "devops"
    private final String roleId;           // AppRole Role ID
    private final String secretId;         // AppRole Secret ID
    private final String transitMount;     // Transit 引擎挂载路径, 如 "transit"
    private final String keyName;          // Transit 密钥名称, 如 "msun-devops-knowledge"

    private final HttpClient httpClient;
    private final ObjectMapper mapper;
    private String clientToken;            // 登录后获取的 Token (自动管理)

    // ==================== 构造方法 ====================

    public OpenBaoTransitClient(String baseUrl, String namespace,
                                String roleId, String secretId,
                                String transitMount, String keyName) {
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
        this.namespace = namespace;
        this.roleId = roleId;
        this.secretId = secretId;
        this.transitMount = transitMount;
        this.keyName = keyName;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();
        this.mapper = new ObjectMapper();
    }

    // ==================== 认证 ====================

    /**
     * 使用 AppRole 登录获取 Client Token
     *
     * 请求: POST /v1/auth/approle/login
     * Body: {"role_id": "...", "secret_id": "..."}
     */
    public synchronized void login() throws Exception {
        Map<String, String> body = Map.of(
                "role_id", roleId,
                "secret_id", secretId
        );

        String responseBody = doPost(baseUrl + "/v1/auth/approle/login", body, false);
        JsonNode root = mapper.readTree(responseBody);
        this.clientToken = root.path("auth").path("client_token").asText();

        if (this.clientToken == null || this.clientToken.isEmpty()) {
            throw new RuntimeException("AppRole 登录失败: 未获取到 client_token, 响应: " + responseBody);
        }

        int ttl = root.path("auth").path("lease_duration").asInt(0);
        log.info("AppRole 登录成功, token TTL = {}s", ttl);
    }

    /**
     * 确保已登录, 未登录则自动登录
     */
    private void ensureLoggedIn() throws Exception {
        if (clientToken == null || clientToken.isEmpty()) {
            login();
        }
    }

    // ==================== 单条加密/解密 ====================

    /**
     * 加密单条明文
     *
     * 请求: POST /v1/{transit_mount}/encrypt/{key_name}
     * Body: {"plaintext": "<base64编码的明文>"}
     *
     * 响应: {"data": {"ciphertext": "vault:v1:xxx"}}
     *
     * @param plaintext 明文字符串
     * @return 密文, 格式如 "vault:v1:xxxxx"
     */
    public String encrypt(String plaintext) throws Exception {
        ensureLoggedIn();

        String encoded = Base64.getEncoder().encodeToString(
                plaintext.getBytes(StandardCharsets.UTF_8));

        Map<String, String> body = Map.of("plaintext", encoded);
        String url = baseUrl + "/v1/" + transitMount + "/encrypt/" + keyName;

        String responseBody = doPost(url, body, true);
        JsonNode root = mapper.readTree(responseBody);

        String ciphertext = root.path("data").path("ciphertext").asText(null);
        if (ciphertext == null) {
            throw new RuntimeException("加密失败: " + responseBody);
        }

        log.debug("加密成功: 明文长度={}, 密文={}...", plaintext.length(),
                ciphertext.substring(0, Math.min(40, ciphertext.length())));
        return ciphertext;
    }

    /**
     * 解密单条密文
     *
     * 请求: POST /v1/{transit_mount}/decrypt/{key_name}
     * Body: {"ciphertext": "vault:v1:xxx"}
     *
     * 响应: {"data": {"plaintext": "<base64编码的明文>"}}
     *
     * @param ciphertext 密文, 格式如 "vault:v1:xxxxx"
     * @return 明文字符串
     */
    public String decrypt(String ciphertext) throws Exception {
        ensureLoggedIn();

        Map<String, String> body = Map.of("ciphertext", ciphertext);
        String url = baseUrl + "/v1/" + transitMount + "/decrypt/" + keyName;

        String responseBody = doPost(url, body, true);
        JsonNode root = mapper.readTree(responseBody);

        String encoded = root.path("data").path("plaintext").asText(null);
        if (encoded == null) {
            throw new RuntimeException("解密失败: " + responseBody);
        }

        String plaintext = new String(Base64.getDecoder().decode(encoded), StandardCharsets.UTF_8);
        log.debug("解密成功: 密文={}..., 明文长度={}",
                ciphertext.substring(0, Math.min(40, ciphertext.length())), plaintext.length());
        return plaintext;
    }

    // ==================== 批量加密/解密 ====================

    /**
     * 批量加密 (使用 batch_input, 一次请求加密多条数据)
     *
     * 请求: POST /v1/{transit_mount}/encrypt/{key_name}
     * Body: {"batch_input": [{"plaintext": "<base64>"}, {"plaintext": "<base64>"}, ...]}
     *
     * 响应: {"data": {"batch_results": [{"ciphertext": "vault:v1:xxx"}, ...]}}
     *
     * @param plaintexts 明文列表
     * @return 密文列表, 顺序与输入一致
     */
    public List<String> batchEncrypt(List<String> plaintexts) throws Exception {
        ensureLoggedIn();

        // 构建 batch_input: 每条明文需 Base64 编码
        List<Map<String, String>> batchInput = plaintexts.stream()
                .map(pt -> Map.of("plaintext",
                        Base64.getEncoder().encodeToString(pt.getBytes(StandardCharsets.UTF_8))))
                .collect(Collectors.toList());

        Map<String, Object> body = Map.of("batch_input", batchInput);
        String url = baseUrl + "/v1/" + transitMount + "/encrypt/" + keyName;

        String responseBody = doPost(url, body, true);
        JsonNode root = mapper.readTree(responseBody);

        JsonNode batchResults = root.path("data").path("batch_results");
        if (batchResults.isMissingNode() || !batchResults.isArray()) {
            throw new RuntimeException("批量加密失败: " + responseBody);
        }

        List<String> ciphertexts = new ArrayList<>();
        for (int i = 0; i < batchResults.size(); i++) {
            JsonNode item = batchResults.get(i);
            if (item.has("error")) {
                throw new RuntimeException("批量加密第 " + i + " 项失败: " + item.path("error").asText());
            }
            ciphertexts.add(item.path("ciphertext").asText());
        }

        log.info("批量加密成功: {} 条", ciphertexts.size());
        return ciphertexts;
    }

    /**
     * 批量解密 (使用 batch_input, 一次请求解密多条数据)
     *
     * 请求: POST /v1/{transit_mount}/decrypt/{key_name}
     * Body: {"batch_input": [{"ciphertext": "vault:v1:xxx"}, ...]}
     *
     * 响应: {"data": {"batch_results": [{"plaintext": "<base64>"}, ...]}}
     *
     * @param ciphertexts 密文列表
     * @return 明文列表, 顺序与输入一致
     */
    public List<String> batchDecrypt(List<String> ciphertexts) throws Exception {
        ensureLoggedIn();

        // 构建 batch_input
        List<Map<String, String>> batchInput = ciphertexts.stream()
                .map(ct -> Map.of("ciphertext", ct))
                .collect(Collectors.toList());

        Map<String, Object> body = Map.of("batch_input", batchInput);
        String url = baseUrl + "/v1/" + transitMount + "/decrypt/" + keyName;

        String responseBody = doPost(url, body, true);
        JsonNode root = mapper.readTree(responseBody);

        JsonNode batchResults = root.path("data").path("batch_results");
        if (batchResults.isMissingNode() || !batchResults.isArray()) {
            throw new RuntimeException("批量解密失败: " + responseBody);
        }

        List<String> plaintexts = new ArrayList<>();
        for (int i = 0; i < batchResults.size(); i++) {
            JsonNode item = batchResults.get(i);
            if (item.has("error")) {
                throw new RuntimeException("批量解密第 " + i + " 项失败: " + item.path("error").asText());
            }
            String encoded = item.path("plaintext").asText();
            plaintexts.add(new String(Base64.getDecoder().decode(encoded), StandardCharsets.UTF_8));
        }

        log.info("批量解密成功: {} 条", plaintexts.size());
        return plaintexts;
    }

    // ==================== 内部 HTTP 方法 ====================

    /**
     * 发送 POST 请求
     *
     * @param url        请求 URL
     * @param body       请求体 (会被序列化为 JSON)
     * @param withAuth   是否携带 Token 和 Namespace 头
     * @return 响应体字符串
     */
    private String doPost(String url, Object body, boolean withAuth) throws Exception {
        String jsonBody = mapper.writeValueAsString(body);

        HttpRequest.Builder requestBuilder = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(jsonBody));

        if (withAuth) {
            requestBuilder.header("X-Vault-Token", clientToken);
        }
        // Namespace 头对所有请求都需要 (包括登录)
        if (namespace != null && !namespace.isEmpty()) {
            requestBuilder.header("X-Vault-Namespace", namespace);
        }

        HttpResponse<String> response = httpClient.send(
                requestBuilder.build(),
                HttpResponse.BodyHandlers.ofString()
        );

        if (response.statusCode() >= 400) {
            String msg = String.format("OpenBao 请求失败: status=%d, url=%s, response=%s",
                    response.statusCode(), url, response.body());
            log.error(msg);

            // 如果是 403, 可能 Token 过期, 清空 Token 以便下次自动重新登录
            if (response.statusCode() == 403) {
                log.warn("Token 可能已过期, 将在下次请求时重新登录");
                this.clientToken = null;
            }

            throw new RuntimeException(msg);
        }

        return response.body();
    }
}
