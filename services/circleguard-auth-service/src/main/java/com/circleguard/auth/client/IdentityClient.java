package com.circleguard.auth.client;

import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.retry.Retry;
import io.github.resilience4j.retry.RetryRegistry;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpMethod;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;
import java.util.*;
import java.util.function.Supplier;

/**
 * Maps a real identity to its anonymous id in identity-service.
 *
 * HU-28, three layers, from the inside out:
 *   1. Timeouts: a hung identity service cannot block the auth request threads.
 *   2. Circuit breaker "identity": when identity keeps failing, auth stops calling it and
 *      fails immediately (CallNotPermittedException) until the wait in open state ends.
 *   3. Retry "identity": retries transient I/O errors before giving up.
 * There is no fallback value: a login without an anonymous id is not valid, so the
 * error reaches the caller, but quickly. Settings live under `resilience4j.*`.
 */
@Component
public class IdentityClient {

    static final String INSTANCE = "identity";
    private static final ParameterizedTypeReference<Map<String, Object>> JSON_OBJECT =
            new ParameterizedTypeReference<>() {};

    private final RestTemplate restTemplate;
    private final String identityUrl;
    private final CircuitBreaker circuitBreaker;
    private final Retry retry;

    @Autowired
    public IdentityClient(
            @Value("${identity.api.url:http://localhost:8083}") String identityApiUrl,
            @Value("${identity.api.connect-timeout:2000}") int connectTimeoutMs,
            @Value("${identity.api.read-timeout:5000}") int readTimeoutMs,
            CircuitBreakerRegistry circuitBreakerRegistry,
            RetryRegistry retryRegistry) {
        this(identityApiUrl, connectTimeoutMs, readTimeoutMs,
                circuitBreakerRegistry.circuitBreaker(INSTANCE), retryRegistry.retry(INSTANCE));
    }

    IdentityClient(String identityApiUrl, int connectTimeoutMs, int readTimeoutMs,
                   CircuitBreaker circuitBreaker, Retry retry) {
        this.identityUrl = identityApiUrl + "/api/v1/identities/map";
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(connectTimeoutMs);
        factory.setReadTimeout(readTimeoutMs);
        this.restTemplate = new RestTemplate(factory);
        this.circuitBreaker = circuitBreaker;
        this.retry = retry;
    }

    public UUID getAnonymousId(String realIdentity) {
        Map<String, String> request = Map.of("realIdentity", realIdentity);
        Supplier<Map<String, Object>> call = () -> restTemplate.exchange(
                identityUrl, HttpMethod.POST, new HttpEntity<>(request), JSON_OBJECT).getBody();
        Map<String, Object> response = Retry.decorateSupplier(retry,
                CircuitBreaker.decorateSupplier(circuitBreaker, call)).get();
        return UUID.fromString(response.get("anonymousId").toString());
    }
}
