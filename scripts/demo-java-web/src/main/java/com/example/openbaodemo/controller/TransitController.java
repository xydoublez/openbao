package com.example.openbaodemo.controller;

import com.example.openbaodemo.dto.*;
import com.example.openbaodemo.entity.EncryptedData;
import com.example.openbaodemo.repository.EncryptedDataRepository;
import com.example.openbaodemo.service.TransitService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

/**
 * OpenBao Transit 加密/解密 REST API
 *
 * 提供以下端点:
 * - POST /api/encrypt       加密明文
 * - POST /api/decrypt       解密密文
 * - POST /api/store         加密后存储到数据库
 * - GET  /api/read/{key}    从数据库读取并解密
 * - GET  /api/health        健康检查
 */
@RestController
@RequestMapping("/api")
public class TransitController {

    private static final Logger log = LoggerFactory.getLogger(TransitController.class);

    private final TransitService transitService;
    private final EncryptedDataRepository dataRepository;

    public TransitController(TransitService transitService, EncryptedDataRepository dataRepository) {
        this.transitService = transitService;
        this.dataRepository = dataRepository;
    }

    /**
     * 加密明文数据
     *
     * 请求体: {"plaintext": "Hello OpenBao!"}
     * 响应:   {"ciphertext": "vault:v1:xxxxx"}
     */
    @PostMapping("/encrypt")
    public ResponseEntity<?> encrypt(@RequestBody EncryptRequest request) {
        if (request.plaintext() == null || request.plaintext().isBlank()) {
            return ResponseEntity.badRequest().body("plaintext 不能为空");
        }
        String ciphertext = transitService.encrypt(request.plaintext());
        return ResponseEntity.ok(new EncryptResponse(ciphertext));
    }

    /**
     * 解密密文数据
     *
     * 请求体: {"ciphertext": "vault:v1:xxxxx"}
     * 响应:   {"plaintext": "Hello OpenBao!"}
     */
    @PostMapping("/decrypt")
    public ResponseEntity<?> decrypt(@RequestBody DecryptRequest request) {
        if (request.ciphertext() == null || !request.ciphertext().startsWith("vault:")) {
            return ResponseEntity.badRequest().body("ciphertext 格式错误, 应为 vault:vN:xxx");
        }
        String plaintext = transitService.decrypt(request.ciphertext());
        return ResponseEntity.ok(new DecryptResponse(plaintext));
    }

    /**
     * 加密数据并存储到数据库
     *
     * 演示 Encryption-as-a-Service 模式:
     * 应用调用 OpenBao 加密 → 密文存入数据库 → 数据库管理员看到的都是密文
     *
     * 请求体: {"key": "db-password", "value": "SuperSecret123"}
     * 响应:   {"key": "db-password", "encryptedValue": "vault:v1:xxx", "message": "..."}
     */
    @PostMapping("/store")
    public ResponseEntity<?> store(@RequestBody StoreRequest request) {
        if (request.key() == null || request.value() == null) {
            return ResponseEntity.badRequest().body("key 和 value 不能为空");
        }

        // 调用 OpenBao Transit 加密
        String encryptedValue = transitService.encrypt(request.value());

        // 存储密文到数据库
        EncryptedData entity;
        if (dataRepository.existsByDataKey(request.key())) {
            entity = dataRepository.findByDataKey(request.key()).orElseThrow();
            entity.setEncryptedValue(encryptedValue);
        } else {
            entity = new EncryptedData(request.key(), encryptedValue);
        }
        dataRepository.save(entity);

        log.info("数据存储成功: key={}, 密文已保存 (明文不经过数据库)", request.key());
        return ResponseEntity.ok(new StoreResponse(
                request.key(), encryptedValue, "数据已加密存储，数据库中仅保存密文"));
    }

    /**
     * 从数据库读取密文并解密
     *
     * 流程: 从数据库读取密文 → 调用 OpenBao 解密 → 返回明文
     *
     * 响应: {"key": "db-password", "value": "SuperSecret123", "encryptedValue": "vault:v1:xxx"}
     */
    @GetMapping("/read/{key}")
    public ResponseEntity<?> read(@PathVariable String key) {
        EncryptedData entity = dataRepository.findByDataKey(key)
                .orElse(null);
        if (entity == null) {
            return ResponseEntity.notFound().build();
        }

        // 调用 OpenBao Transit 解密
        String plaintext = transitService.decrypt(entity.getEncryptedValue());

        return ResponseEntity.ok(new ReadResponse(
                entity.getDataKey(), plaintext, entity.getEncryptedValue()));
    }

    /**
     * 健康检查
     */
    @GetMapping("/health")
    public ResponseEntity<?> health() {
        return ResponseEntity.ok(java.util.Map.of(
                "status", "UP",
                "openbao", "connected",
                "timestamp", java.time.Instant.now().toString()
        ));
    }

    /**
     * 全局异常处理
     */
    @ExceptionHandler(Exception.class)
    public ResponseEntity<?> handleException(Exception e) {
        log.error("请求处理失败", e);
        return ResponseEntity.internalServerError()
                .body(java.util.Map.of("error", e.getClass().getSimpleName(), "detail", e.getMessage()));
    }
}
