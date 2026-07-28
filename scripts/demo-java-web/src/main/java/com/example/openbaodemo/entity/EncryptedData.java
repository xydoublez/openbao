package com.example.openbaodemo.entity;

import jakarta.persistence.*;
import java.time.LocalDateTime;

/**
 * 加密数据存储实体
 * 数据库中的 value 字段存储的是 OpenBao Transit 加密后的密文
 */
@Entity
@Table(name = "encrypted_data")
public class EncryptedData {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, unique = true)
    private String dataKey;

    /**
     * 存储 OpenBao Transit 加密后的密文
     * 格式: vault:v1:xxxxx
     * 应用本身无法解密，必须通过 OpenBao API 解密
     */
    @Column(nullable = false, length = 4096)
    private String encryptedValue;

    @Column(nullable = false)
    private LocalDateTime createdAt;

    @Column(nullable = false)
    private LocalDateTime updatedAt;

    public EncryptedData() {}

    public EncryptedData(String dataKey, String encryptedValue) {
        this.dataKey = dataKey;
        this.encryptedValue = encryptedValue;
        this.createdAt = LocalDateTime.now();
        this.updatedAt = LocalDateTime.now();
    }

    @PreUpdate
    public void preUpdate() {
        this.updatedAt = LocalDateTime.now();
    }

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }
    public String getDataKey() { return dataKey; }
    public void setDataKey(String dataKey) { this.dataKey = dataKey; }
    public String getEncryptedValue() { return encryptedValue; }
    public void setEncryptedValue(String encryptedValue) { this.encryptedValue = encryptedValue; }
    public LocalDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(LocalDateTime createdAt) { this.createdAt = createdAt; }
    public LocalDateTime getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(LocalDateTime updatedAt) { this.updatedAt = updatedAt; }
}
