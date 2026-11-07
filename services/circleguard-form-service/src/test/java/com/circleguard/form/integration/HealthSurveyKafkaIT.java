package com.circleguard.form.integration;

import com.circleguard.form.model.HealthSurvey;
import com.circleguard.form.model.Question;
import com.circleguard.form.model.QuestionType;
import com.circleguard.form.model.Questionnaire;
import com.circleguard.form.repository.HealthSurveyRepository;
import com.circleguard.form.service.HealthSurveyService;
import com.circleguard.form.service.QuestionnaireService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.kafka.KafkaContainer;
import org.testcontainers.utility.DockerImageName;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

@Tag("integration")
@Testcontainers
@SpringBootTest
class HealthSurveyKafkaIT {

    private static final String TOPIC = "survey.submitted";

    @Container
    static final PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("circleguard_form")
            .withUsername("admin")
            .withPassword("password");

    @Container
    static final KafkaContainer kafka = new KafkaContainer(
            DockerImageName.parse("apache/kafka:3.8.1"));

    @DynamicPropertySource
    static void properties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", postgres::getJdbcUrl);
        registry.add("spring.datasource.username", postgres::getUsername);
        registry.add("spring.datasource.password", postgres::getPassword);
        registry.add("spring.jpa.hibernate.ddl-auto", () -> "none");
        registry.add("spring.kafka.bootstrap-servers", kafka::getBootstrapServers);
    }

    @Autowired
    private HealthSurveyService healthSurveyService;

    @Autowired
    private QuestionnaireService questionnaireService;

    @Autowired
    private HealthSurveyRepository surveyRepository;

    @Autowired
    private ObjectMapper objectMapper;

    @Test
    void shouldPublishRealSurveySubmittedPayloadToKafka() throws Exception {
        Questionnaire questionnaire = questionnaireService.saveQuestionnaire(
                Questionnaire.builder()
                        .title("Daily health check")
                        .version(1)
                        .isActive(true)
                        .questions(new ArrayList<>(List.of(
                                Question.builder()
                                        .text("Do you have fever?")
                                        .type(QuestionType.YES_NO)
                                        .orderIndex(0)
                                        .build()
                        )))
                        .build());
        UUID questionId = questionnaire.getQuestions().get(0).getId();
        UUID anonymousId = UUID.randomUUID();

        HealthSurvey survey = HealthSurvey.builder()
                .anonymousId(anonymousId)
                .responses(Map.of(questionId.toString(), "YES"))
                .build();

        Properties consumerProperties = new Properties();
        consumerProperties.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, kafka.getBootstrapServers());
        consumerProperties.put(ConsumerConfig.GROUP_ID_CONFIG, "form-it-" + UUID.randomUUID());
        consumerProperties.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        consumerProperties.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        consumerProperties.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");

        try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(consumerProperties)) {
            consumer.subscribe(List.of(TOPIC));

            HealthSurvey saved = healthSurveyService.submitSurvey(survey);

            ConsumerRecord<String, String> record = awaitRecord(consumer, Duration.ofSeconds(15));

            assertNotNull(record);
            assertEquals(anonymousId.toString(), record.key());

            JsonNode payload = objectMapper.readTree(record.value());
            assertEquals(3, payload.size());
            assertEquals(anonymousId.toString(), payload.get("anonymousId").asText());
            assertTrue(payload.get("hasSymptoms").asBoolean());
            assertTrue(payload.get("timestamp").isNumber());

            assertTrue(saved.getHasFever());
            assertTrue(saved.getHasCough());
            assertTrue(surveyRepository.findById(saved.getId()).orElseThrow().getHasFever());
        }
    }

    private ConsumerRecord<String, String> awaitRecord(KafkaConsumer<String, String> consumer, Duration timeout) {
        long deadline = System.nanoTime() + timeout.toNanos();
        while (System.nanoTime() < deadline) {
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(500));
            for (ConsumerRecord<String, String> record : records) {
                if (TOPIC.equals(record.topic())) {
                    return record;
                }
            }
        }
        fail("No Kafka record received on topic " + TOPIC + " within " + timeout);
        return null;
    }
}
