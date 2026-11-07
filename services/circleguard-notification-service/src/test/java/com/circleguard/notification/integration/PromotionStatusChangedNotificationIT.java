package com.circleguard.notification.integration;

import com.circleguard.notification.service.EmailService;
import com.circleguard.notification.service.LmsService;
import com.circleguard.notification.service.PushService;
import com.circleguard.notification.service.SmsService;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.kafka.KafkaContainer;
import org.testcontainers.utility.DockerImageName;

import java.time.Duration;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;

import static org.awaitility.Awaitility.await;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@Tag("integration")
@Testcontainers
@SpringBootTest
class PromotionStatusChangedNotificationIT {

    private static final String TOPIC = "promotion.status.changed";

    @Container
    static final KafkaContainer kafka = new KafkaContainer(
            DockerImageName.parse("apache/kafka:3.8.1"));

    @DynamicPropertySource
    static void properties(DynamicPropertyRegistry registry) {
        registry.add("spring.kafka.bootstrap-servers", kafka::getBootstrapServers);
        registry.add("spring.kafka.consumer.auto-offset-reset", () -> "earliest");
        registry.add("spring.kafka.producer.value-serializer",
                () -> "org.apache.kafka.common.serialization.StringSerializer");
        registry.add("spring.kafka.listener.missing-topics-fatal", () -> "false");
    }

    @Autowired
    private KafkaTemplate<String, String> kafkaTemplate;

    @Autowired
    private ObjectMapper objectMapper;

    @MockBean
    private EmailService emailService;

    @MockBean
    private SmsService smsService;

    @MockBean
    private PushService pushService;

    @MockBean
    private LmsService lmsService;

    @BeforeEach
    void stubOutputChannels() {
        when(emailService.sendAsync(any(), any())).thenReturn(CompletableFuture.completedFuture(null));
        when(smsService.sendAsync(any(), any())).thenReturn(CompletableFuture.completedFuture(null));
        when(pushService.sendAsync(any(), any(), anyMap())).thenReturn(CompletableFuture.completedFuture(null));
        when(lmsService.syncRemoteAttendance(any(), any())).thenReturn(CompletableFuture.completedFuture(null));
    }

    @Test
    void shouldDispatchNotificationWhenPromotionStatusChanges() throws JsonProcessingException {
        String anonymousId = UUID.randomUUID().toString();
        String event = statusChangedEvent(anonymousId, "SUSPECT");

        kafkaTemplate.send(TOPIC, anonymousId, event);
        kafkaTemplate.flush();

        await().atMost(Duration.ofSeconds(15)).untilAsserted(() -> {
            verify(emailService).sendAsync(eq(anonymousId), contains("SUSPECT"));
            verify(smsService).sendAsync(eq(anonymousId), contains("SUSPECT"));
            verify(pushService).sendAsync(eq(anonymousId), contains("SUSPECT"), anyMap());
            verify(lmsService).syncRemoteAttendance(anonymousId, "SUSPECT");
        });
    }

    @Test
    void shouldContinueProcessingValidEventAfterInvalidMessage() throws JsonProcessingException {
        String validAnonymousId = UUID.randomUUID().toString();
        kafkaTemplate.send(TOPIC, validAnonymousId, "{invalid-json");
        kafkaTemplate.send(TOPIC, validAnonymousId, statusChangedEvent(validAnonymousId, "SUSPECT"));
        kafkaTemplate.flush();

        await().atMost(Duration.ofSeconds(15)).untilAsserted(() -> {
            verify(emailService).sendAsync(eq(validAnonymousId), contains("SUSPECT"));
            verify(smsService).sendAsync(eq(validAnonymousId), contains("SUSPECT"));
            verify(pushService).sendAsync(eq(validAnonymousId), contains("SUSPECT"), anyMap());
            verify(lmsService).syncRemoteAttendance(validAnonymousId, "SUSPECT");
        });
    }

    private String statusChangedEvent(String anonymousId, String status) throws JsonProcessingException {
        Map<String, Object> event = Map.of(
                "anonymousId", anonymousId,
                "status", status,
                "timestamp", System.currentTimeMillis());
        return objectMapper.writeValueAsString(event);
    }
}
