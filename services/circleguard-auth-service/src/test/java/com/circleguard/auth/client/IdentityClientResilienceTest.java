package com.circleguard.auth.client;

import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.retry.Retry;
import io.github.resilience4j.retry.RetryConfig;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.web.client.ResourceAccessException;

import java.io.IOException;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

import static org.junit.jupiter.api.Assertions.*;

/**
 * HU-28: behaviour of auth when identity-service fails.
 *  - hung identity  -> the timeout ends the call quickly
 *  - identity down  -> the call is retried, then fails
 *  - repeated faults -> the circuit opens and auth stops calling identity
 */
class IdentityClientResilienceTest {

    private ServerSocket silentServer;
    private final List<Socket> accepted = new CopyOnWriteArrayList<>();

    @AfterEach
    void stopSilentServer() throws IOException {
        if (silentServer != null) {
            silentServer.close();
        }
        for (Socket socket : accepted) {
            socket.close();
        }
    }

    @Test
    void timeoutEndsTheCallWhenIdentityHangs() throws IOException {
        String url = startSilentServer();
        IdentityClient client = new IdentityClient(url, 500, 500,
                CircuitBreaker.ofDefaults("identity"), noRetry());

        assertTimeoutPreemptively(Duration.ofSeconds(3), () ->
                assertThrows(ResourceAccessException.class,
                        () -> client.getAnonymousId("student@circleguard.edu")));
    }

    @Test
    void retriesWhenIdentityIsDown() throws IOException {
        Retry retry = Retry.of("identity", RetryConfig.custom()
                .maxAttempts(3)
                .waitDuration(Duration.ofMillis(10))
                .retryExceptions(ResourceAccessException.class)
                .build());
        IdentityClient client = new IdentityClient(closedPortUrl(), 500, 500,
                CircuitBreaker.ofDefaults("identity"), retry);

        assertThrows(ResourceAccessException.class, () -> client.getAnonymousId("student@circleguard.edu"));

        assertEquals(1, retry.getMetrics().getNumberOfFailedCallsWithRetryAttempt(),
                "the call must have been retried before failing");
    }

    @Test
    void circuitOpensAfterRepeatedFailuresAndFailsImmediately() throws IOException {
        CircuitBreaker breaker = CircuitBreaker.of("identity", CircuitBreakerConfig.custom()
                .slidingWindowSize(4)
                .minimumNumberOfCalls(4)
                .failureRateThreshold(50)
                .waitDurationInOpenState(Duration.ofMinutes(1))
                .build());
        IdentityClient client = new IdentityClient(closedPortUrl(), 500, 500, breaker, noRetry());

        for (int i = 0; i < 4; i++) {
            assertThrows(ResourceAccessException.class, () -> client.getAnonymousId("student@circleguard.edu"));
        }
        assertEquals(CircuitBreaker.State.OPEN, breaker.getState());

        // Open circuit: no network call, the rejection is immediate.
        assertTimeoutPreemptively(Duration.ofMillis(200), () ->
                assertThrows(CallNotPermittedException.class,
                        () -> client.getAnonymousId("student@circleguard.edu")));
    }

    private static Retry noRetry() {
        return Retry.of("identity", RetryConfig.custom().maxAttempts(1).build());
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
