package com.circleguard.dashboard.client;

import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.retry.Retry;
import io.github.resilience4j.retry.RetryRegistry;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;

import java.util.*;
import java.util.function.Supplier;

/**
 * Calls promotion-service for the dashboard statistics.
 *
 * HU-28, three layers, from the inside out:
 *   1. Timeouts (connect 2 s, read 5 s): a hung promotion cannot block the dashboard.
 *   2. Circuit breaker "promotion": after repeated failures it opens and answers with the
 *      fallback immediately, without calling promotion, until the wait in open state ends.
 *   3. Retry "promotion": retries transient I/O errors a few times before giving up.
 * When everything fails, the dashboard degrades to the "Service unavailable" fallback
 * instead of returning an error. Settings live under `resilience4j.*` in application.yml.
 */
@Component
@Slf4j
public class PromotionClient {

    static final String INSTANCE = "promotion";

    private final RestTemplate restTemplate;
    private final String promotionServiceUrl;
    private final CircuitBreaker circuitBreaker;
    private final Retry retry;

    @Autowired
    public PromotionClient(
            @Value("${circleguard.promotion-service.url:http://localhost:8088}") String promotionServiceUrl,
            CircuitBreakerRegistry circuitBreakerRegistry,
            RetryRegistry retryRegistry) {
        this(promotionServiceUrl,
                circuitBreakerRegistry.circuitBreaker(INSTANCE),
                retryRegistry.retry(INSTANCE),
                restTemplateWithTimeouts());
    }

    PromotionClient(String promotionServiceUrl, CircuitBreaker circuitBreaker, Retry retry,
                    RestTemplate restTemplate) {
        this.promotionServiceUrl = promotionServiceUrl;
        this.circuitBreaker = circuitBreaker;
        this.retry = retry;
        this.restTemplate = restTemplate;
    }

    @SuppressWarnings("unchecked")
    public Map<String, Object> getHealthStats() {
        return call(
                () -> restTemplate.getForObject(promotionServiceUrl + "/api/v1/health-status/stats", Map.class),
                () -> Map.of("error", "Service unavailable", "timestamp", new Date()),
                "health stats");
    }

    @SuppressWarnings("unchecked")
    public Map<String, Object> getHealthStatsByDepartment(String department) {
        return call(
                () -> restTemplate.getForObject(
                        promotionServiceUrl + "/api/v1/health-status/stats/department/" + department, Map.class),
                () -> Map.of("error", "Service unavailable", "department", department, "timestamp", new Date()),
                "department stats");
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private Map<String, Object> call(Supplier<Map> request, Supplier<Map<String, Object>> fallback, String what) {
        Supplier<Map> guarded = Retry.decorateSupplier(retry,
                CircuitBreaker.decorateSupplier(circuitBreaker, request));
        try {
            return guarded.get();
        } catch (CallNotPermittedException e) {
            log.warn("Circuit breaker '{}' is {}: returning the {} fallback without calling promotion-service",
                    INSTANCE, circuitBreaker.getState(), what);
            return fallback.get();
        } catch (Exception e) {
            log.error("Failed to fetch {} from promotion-service", what, e);
            return fallback.get();
        }
    }

    /** HU-28: a RestTemplate without timeouts waits forever for a hung service. */
    private static RestTemplate restTemplateWithTimeouts() {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(2000);
        factory.setReadTimeout(5000);
        return new RestTemplate(factory);
    }
}
