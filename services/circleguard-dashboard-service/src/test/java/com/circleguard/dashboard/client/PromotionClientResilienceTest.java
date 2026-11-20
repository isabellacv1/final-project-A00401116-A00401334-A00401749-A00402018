package com.circleguard.dashboard.client;

import com.sun.net.httpserver.HttpServer;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.retry.Retry;
import io.github.resilience4j.retry.RetryConfig;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestTemplate;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;

/**
 * HU-28: behaviour of the dashboard when promotion-service fails. The dashboard must
 * degrade to its "Service unavailable" fallback and never hang or return an error.
 */
class PromotionClientResilienceTest {

    private ServerSocket silentServer;
    private HttpServer httpServer;
    private final List<Socket> accepted = new CopyOnWriteArrayList<>();

    @AfterEach
    void stopServers() throws IOException {
        if (silentServer != null) {
            silentServer.close();
        }
        for (Socket socket : accepted) {
            socket.close();
        }
        if (httpServer != null) {
            httpServer.stop(0);
        }
    }

    @Test
    void returnsTheDataWhenPromotionAnswers() throws IOException {
        String url = startHttpServer(200, "{\"total\":42}", new AtomicInteger());
        PromotionClient client = client(url, CircuitBreaker.ofDefaults("promotion"), noRetry());

        assertEquals(42, client.getHealthStats().get("total"));
    }

    @Test
    void returnsTheFallbackQuicklyWhenPromotionHangs() throws IOException {
        String url = startSilentServer();
        PromotionClient client = client(url, CircuitBreaker.ofDefaults("promotion"), noRetry());

        Map<String, Object> stats = assertTimeoutPreemptively(Duration.ofSeconds(3), client::getHealthStats);

        assertEquals("Service unavailable", stats.get("error"));
    }

    @Test
    void openCircuitStopsCallingPromotionAndKeepsAnsweringWithTheFallback() throws IOException {
        AtomicInteger hits = new AtomicInteger();
        String url = startHttpServer(500, "{}", hits);
        CircuitBreaker breaker = CircuitBreaker.of("promotion", CircuitBreakerConfig.custom()
                .slidingWindowSize(4)
                .minimumNumberOfCalls(4)
                .failureRateThreshold(50)
                .waitDurationInOpenState(Duration.ofMinutes(1))
                .build());
        PromotionClient client = client(url, breaker, noRetry());

        for (int i = 0; i < 4; i++) {
            assertEquals("Service unavailable", client.getHealthStats().get("error"));
        }
        assertEquals(CircuitBreaker.State.OPEN, breaker.getState());
        assertEquals(4, hits.get());

        // While open, the dashboard still answers, but promotion is not called again.
        assertEquals("Service unavailable", client.getHealthStatsByDepartment("Engineering").get("error"));
        assertEquals(4, hits.get(), "an open circuit must not reach promotion-service");
    }

    @Test
    void retriesBeforeFallingBack() throws IOException {
        Retry retry = Retry.of("promotion", RetryConfig.custom()
                .maxAttempts(3)
                .waitDuration(Duration.ofMillis(10))
                .retryExceptions(org.springframework.web.client.ResourceAccessException.class)
                .build());
        PromotionClient client = client(closedPortUrl(), CircuitBreaker.ofDefaults("promotion"), retry);

        assertEquals("Service unavailable", client.getHealthStats().get("error"));
        assertEquals(1, retry.getMetrics().getNumberOfFailedCallsWithRetryAttempt());
    }

    private static PromotionClient client(String url, CircuitBreaker breaker, Retry retry) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(500);
        factory.setReadTimeout(500);
        return new PromotionClient(url, breaker, retry, new RestTemplate(factory));
    }

    private static Retry noRetry() {
        return Retry.of("promotion", RetryConfig.custom().maxAttempts(1).build());
    }

    private String startHttpServer(int status, String body, AtomicInteger hits) throws IOException {
        httpServer = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
        httpServer.createContext("/", exchange -> {
            hits.incrementAndGet();
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, bytes.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(bytes);
            }
        });
        httpServer.start();
        return "http://127.0.0.1:" + httpServer.getAddress().getPort();
    }

    /** A server that accepts connections and never answers: a frozen process. */
    private String startSilentServer() throws IOException {
        silentServer = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
        Thread acceptor = new Thread(() -> {
            try {
                while (!silentServer.isClosed()) {
                    accepted.add(silentServer.accept());
                }
            } catch (IOException ignored) {
                // closed at the end of the test
            }
        });
        acceptor.setDaemon(true);
        acceptor.start();
        return "http://127.0.0.1:" + silentServer.getLocalPort();
    }

    /** A port nobody listens on: a stopped container (connection refused). */
    private static String closedPortUrl() throws IOException {
        try (ServerSocket socket = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            return "http://127.0.0.1:" + socket.getLocalPort();
        }
    }
}
