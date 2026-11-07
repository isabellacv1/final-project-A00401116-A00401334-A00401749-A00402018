package com.circleguard.promotion.integration;

import com.circleguard.promotion.repository.graph.UserNodeRepository;
import com.circleguard.promotion.service.HealthStatusService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.data.neo4j.core.Neo4jClient;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.ActiveProfiles;
import org.testcontainers.containers.Neo4jContainer;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.kafka.KafkaContainer;
import org.testcontainers.utility.DockerImageName;

import java.time.Duration;
import java.util.List;
import java.util.Properties;
import java.util.UUID;

import static org.awaitility.Awaitility.await;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

@Tag("integration")
@Testcontainers
@ActiveProfiles("test")
@SpringBootTest
class PromotionEncounterPropagationIT {

    private static final String STATUS_CHANGED_TOPIC = "promotion.status.changed";

    @Container
    static final PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("circleguard_promotion")
            .withUsername("admin")
            .withPassword("password");

    @Container
    static final Neo4jContainer<?> neo4j = new Neo4jContainer<>("neo4j:5.12")
            .withAdminPassword("password");

    @Container
    static final KafkaContainer kafka = new KafkaContainer(
            DockerImageName.parse("apache/kafka:3.8.1"));

    @Container
    static final GenericContainer<?> redis = new GenericContainer<>(DockerImageName.parse("redis:7.2"))
            .withExposedPorts(6379);

    @DynamicPropertySource
    static void properties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", postgres::getJdbcUrl);
        registry.add("spring.datasource.username", postgres::getUsername);
        registry.add("spring.datasource.password", postgres::getPassword);
        registry.add("spring.flyway.enabled", () -> "true");
        registry.add("spring.jpa.hibernate.ddl-auto", () -> "none");
        registry.add("spring.neo4j.uri", neo4j::getBoltUrl);
        registry.add("spring.neo4j.authentication.username", () -> "neo4j");
        registry.add("spring.neo4j.authentication.password", () -> "password");
        registry.add("spring.kafka.bootstrap-servers", kafka::getBootstrapServers);
        registry.add("spring.data.redis.host", redis::getHost);
        registry.add("spring.data.redis.port", () -> redis.getMappedPort(6379));
    }

    @Autowired
    private HealthStatusService healthStatusService;

    @Autowired
    private UserNodeRepository userNodeRepository;

    @Autowired
    private Neo4jClient neo4jClient;

    @BeforeEach
    void cleanGraph() {
        neo4jClient.query("MATCH (n) DETACH DELETE n").run();
    }

    @Test
    void shouldPropagateConfirmedStatusThroughRegisteredEncounters() {
        createUser("source", "ACTIVE");
        createUser("direct-contact", "ACTIVE");
        createUser("second-hop-contact", "ACTIVE");
        createUser("third-hop-contact", "ACTIVE");
        createUser("stale-contact", "ACTIVE");

        long now = System.currentTimeMillis();
        userNodeRepository.recordEncounter("source", "direct-contact", now, "LAB-101");
        userNodeRepository.recordEncounter("direct-contact", "second-hop-contact", now, "LAB-101");
        userNodeRepository.recordEncounter("second-hop-contact", "third-hop-contact", now, "LAB-101");
        userNodeRepository.recordEncounter("source", "stale-contact",
                now - Duration.ofDays(15).toMillis(), "LAB-101");

        Properties consumerProperties = new Properties();
        consumerProperties.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, kafka.getBootstrapServers());
        consumerProperties.put(ConsumerConfig.GROUP_ID_CONFIG, "promotion-it-" + UUID.randomUUID());
        consumerProperties.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        consumerProperties.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        consumerProperties.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");

        try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(consumerProperties)) {
            consumer.subscribe(List.of(STATUS_CHANGED_TOPIC));
            consumer.poll(Duration.ofMillis(100));
            healthStatusService.updateStatus("source", "CONFIRMED");

            await().atMost(Duration.ofSeconds(15)).untilAsserted(() -> {
                assertEquals("CONFIRMED", statusOf("source"));
                assertEquals("SUSPECT", statusOf("direct-contact"));
                assertEquals("PROBABLE", statusOf("second-hop-contact"));
                assertEquals("ACTIVE", statusOf("third-hop-contact"));
                assertEquals("ACTIVE", statusOf("stale-contact"));
            });

            ConsumerRecord<String, String> event = awaitStatusEvent(consumer, Duration.ofSeconds(15));
            assertNotNull(event);
            assertEquals("source", event.key());
            assertTrue(event.value().contains("\"anonymousId\":\"source\""));
            assertTrue(event.value().contains("\"status\":\"CONFIRMED\""));
        }
    }

    private ConsumerRecord<String, String> awaitStatusEvent(KafkaConsumer<String, String> consumer, Duration timeout) {
        long deadline = System.nanoTime() + timeout.toNanos();
        while (System.nanoTime() < deadline) {
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(300));
            for (ConsumerRecord<String, String> record : records) {
                if (STATUS_CHANGED_TOPIC.equals(record.topic())) return record;
            }
        }
        return null;
    }

    private void createUser(String anonymousId, String status) {
        neo4jClient.query("CREATE (:User {anonymousId: $id, status: $status})")
                .bind(anonymousId).to("id")
                .bind(status).to("status")
                .run();
    }

    private String statusOf(String anonymousId) {
        return neo4jClient.query("MATCH (u:User {anonymousId: $id}) RETURN u.status AS status")
                .bind(anonymousId).to("id")
                .fetchAs(String.class)
                .one()
                .orElse("NOT_FOUND");
    }
}
