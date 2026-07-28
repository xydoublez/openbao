package com.example.openbaodemo.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.vault.authentication.AppRoleAuthentication;
import org.springframework.vault.authentication.AppRoleAuthenticationOptions;
import org.springframework.vault.authentication.ClientAuthentication;
import org.springframework.vault.authentication.TokenAuthentication;
import org.springframework.vault.client.VaultEndpoint;
import org.springframework.vault.core.VaultTemplate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.URI;

@Configuration
public class OpenBaoConfig {

    private static final Logger log = LoggerFactory.getLogger(OpenBaoConfig.class);

    @Bean
    public VaultTemplate vaultTemplate(OpenBaoProperties properties) {
        VaultEndpoint endpoint = VaultEndpoint.from(URI.create(properties.getUri()));
        ClientAuthentication auth = createAuthentication(properties);
        log.info("OpenBao 连接配置: uri={}, auth={}, transit-key={}",
                properties.getUri(), properties.getAuthMethod(), properties.getTransitKey());
        return new VaultTemplate(endpoint, auth);
    }

    private ClientAuthentication createAuthentication(OpenBaoProperties properties) {
        if ("token".equalsIgnoreCase(properties.getAuthMethod())) {
            log.info("使用 Token 认证模式");
            return new TokenAuthentication(properties.getToken());
        }
        // 默认 AppRole
        log.info("使用 AppRole 认证模式");
        AppRoleAuthenticationOptions options = AppRoleAuthenticationOptions.builder()
                .roleId(properties.getApprole().getRoleId())
                .secretId(properties.getApprole().getSecretId())
                .build();
        return new AppRoleAuthentication(options, restTemplate());
    }

    @Bean
    public org.springframework.web.client.RestTemplate restTemplate() {
        return new org.springframework.web.client.RestTemplate();
    }
}
