package com.example.openbaodemo.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@ConfigurationProperties(prefix = "openbao")
public class OpenBaoProperties {
    private String uri = "http://127.0.0.1:8200";
    private String transitKey = "app-key";
    private String authMethod = "approle";
    private String token = "";
    private AppRole approle = new AppRole();

    public static class AppRole {
        private String roleId = "";
        private String secretId = "";

        public String getRoleId() { return roleId; }
        public void setRoleId(String roleId) { this.roleId = roleId; }
        public String getSecretId() { return secretId; }
        public void setSecretId(String secretId) { this.secretId = secretId; }
    }

    public String getUri() { return uri; }
    public void setUri(String uri) { this.uri = uri; }
    public String getTransitKey() { return transitKey; }
    public void setTransitKey(String transitKey) { this.transitKey = transitKey; }
    public String getAuthMethod() { return authMethod; }
    public void setAuthMethod(String authMethod) { this.authMethod = authMethod; }
    public String getToken() { return token; }
    public void setToken(String token) { this.token = token; }
    public AppRole getApprole() { return approle; }
    public void setApprole(AppRole approle) { this.approle = approle; }
}
