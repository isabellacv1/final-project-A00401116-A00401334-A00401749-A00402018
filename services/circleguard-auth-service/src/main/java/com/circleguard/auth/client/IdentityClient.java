package com.circleguard.auth.client;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;
import java.util.*;

@Component
public class IdentityClient {
    // In a real microservice, this would use Feign or WebClient
    private final RestTemplate restTemplate = new RestTemplate();
    private final String identityUrl;

    public IdentityClient(
            @Value("${identity.api.url:http://localhost:8083}") String identityApiUrl) {
        this.identityUrl = identityApiUrl + "/api/v1/identities/map";
    }

    public UUID getAnonymousId(String realIdentity) {
        Map<String, String> request = Map.of("realIdentity", realIdentity);
        Map response = restTemplate.postForObject(identityUrl, request, Map.class);
        return UUID.fromString(response.get("anonymousId").toString());
    }
}
