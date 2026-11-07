package com.circleguard.promotion.integration;

import com.circleguard.form.model.HealthSurvey;
import com.circleguard.form.model.Question;
import com.circleguard.form.model.QuestionType;
import com.circleguard.form.model.Questionnaire;
import com.circleguard.form.repository.HealthSurveyRepository;
import com.circleguard.form.service.HealthSurveyService;
import com.circleguard.form.service.QuestionnaireService;
import com.circleguard.form.service.SymptomMapper;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.circleguard.promotion.repository.graph.UserNodeRepository;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.data.neo4j.core.Neo4jClient;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.Neo4jContainer;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.kafka.KafkaContainer;
import org.testcontainers.utility.DockerImageName;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Properties;
import java.util.UUID;

import static org.awaitility.Awaitility.await;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

@Tag("integration")
@Testcontainers
@ActiveProfiles("test")
@SpringBootTest
class FormToPromotionKafkaIT {

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
        registry.add("spring.kafka.listener.missing-topics-fatal", () -> "false");
    }

    @Autowired
    private UserNodeRepository userNodeRepository;

    @Autowired
    private Neo4jClient neo4jClient;

    @Autowired
    private KafkaTemplate<String, Object> kafkaTemplate;

    @Autowired
    private ObjectMapper objectMapper;

    @MockBean
    private StringRedisTemplate redisTemplate;

    @MockBean
    private ValueOperations<String, String> valueOperations;

    @BeforeEach
    void clearPromotionGraph() {
        neo4jClient.query("MATCH (n) DETACH DELETE n").run();
        when(redisTemplate.opsForValue()).thenReturn(valueOperations);
    }

    @Test
    void shouldPromoteSurveySubmitterAndContactThroughRealKafkaFlow() throws Exception {
        UUID anonymousId = UUID.randomUUID();
        UUID directContactId = UUID.randomUUID();
        UUID questionId = UUID.randomUUID();
        createUser(anonymousId.toString(), "ACTIVE");
        createUser(directContactId.toString(), "ACTIVE");
        userNodeRepository.recordEncounter(
                anonymousId.toString(),
                directContactId.toString(),
                System.currentTimeMillis(),
                "LAB-101");

        Question feverQuestion = Question.builder()
                .id(questionId)
                .text("Do you have fever?")
                .type(QuestionType.YES_NO)
                .orderIndex(0)
                .build();
        Questionnaire activeQuestionnaire = Questionnaire.builder()
                .id(UUID.randomUUID())
                .title("Daily health check")
                .version(1)
                .isActive(true)
                .questions(List.of(feverQuestion))
                .build();

        HealthSurveyRepository surveyRepository = mock(HealthSurveyRepository.class);
        QuestionnaireService questionnaireService = mock(QuestionnaireService.class);
        when(questionnaireService.getActiveQuestionnaire()).thenReturn(Optional.of(activeQuestionnaire));
        when(surveyRepository.save(any(HealthSurvey.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));

        HealthSurveyService formService = new HealthSurveyService(
                surveyRepository,
                questionnaireService,
                new SymptomMapper(),
                kafkaTemplate);
        HealthSurvey survey = HealthSurvey.builder()
                .anonymousId(anonymousId)
                .responses(Map.of(questionId.toString(), "YES"))
                .build();

        Properties consumerProperties = new Properties();
        consumerProperties.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, kafka.getBootstrapServers());
        consumerProperties.put(ConsumerConfig.GROUP_ID_CONFIG, "status-it-" + UUID.randomUUID());
        consumerProperties.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        consumerProperties.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        consumerProperties.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");

        try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(consumerProperties)) {
            consumer.subscribe(List.of(STATUS_CHANGED_TOPIC));
            consumer.poll(Duration.ofMillis(100));

            HealthSurvey submittedSurvey = formService.submitSurvey(survey);
            assertTrue(submittedSurvey.getHasFever());

            await().atMost(Duration.ofSeconds(15)).untilAsserted(() -> {
                assertEquals("SUSPECT", statusOf(anonymousId.toString()));
                assertEquals("PROBABLE", statusOf(directContactId.toString()));
            });

            ConsumerRecord<String, String> event = awaitStatusEvent(consumer, Duration.ofSeconds(15));
            assertNotNull(event);
            assertEquals(anonymousId.toString(), event.key());
            JsonNode payload = objectMapper.readTree(event.value());
            assertEquals(anonymousId.toString(), payload.get("anonymousId").asText());
            assertEquals("SUSPECT", payload.get("status").asText());
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
