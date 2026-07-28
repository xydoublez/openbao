package com.example.openbaodemo.repository;

import com.example.openbaodemo.entity.EncryptedData;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.Optional;

public interface EncryptedDataRepository extends JpaRepository<EncryptedData, Long> {
    Optional<EncryptedData> findByDataKey(String dataKey);
    boolean existsByDataKey(String dataKey);
}
