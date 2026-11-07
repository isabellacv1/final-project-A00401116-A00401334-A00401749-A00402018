package com.circleguard.form.service;

import com.circleguard.form.model.HealthSurvey;
import com.circleguard.form.model.Questionnaire;
import com.circleguard.form.model.ValidationStatus;
import com.circleguard.form.repository.HealthSurveyRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.kafka.core.KafkaTemplate;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class HealthSurveyServiceTest {

    @Mock
    private HealthSurveyRepository repository;

    @Mock
    private QuestionnaireService questionnaireService;

    @Mock
    private SymptomMapper symptomMapper;

    @Mock
    private KafkaTemplate<String, Object> kafkaTemplate;

    @InjectMocks
    private HealthSurveyService service;

    @Test
    void shouldSubmitSurveyAndEmitEventWhenSymptomsDetected() {
        UUID anonymousId = UUID.randomUUID();
        HealthSurvey survey = HealthSurvey.builder().anonymousId(anonymousId).build();
        Questionnaire questionnaire = Questionnaire.builder().build();

        when(questionnaireService.getActiveQuestionnaire()).thenReturn(Optional.of(questionnaire));
        when(symptomMapper.hasSymptoms(survey, questionnaire)).thenReturn(true);
        when(repository.save(survey)).thenReturn(survey);

        HealthSurvey result = service.submitSurvey(survey);

        assertSame(survey, result);
        assertTrue(survey.getHasFever());
        assertTrue(survey.getHasCough());
        assertNull(survey.getValidationStatus());
        verify(repository).save(survey);
        verify(kafkaTemplate).send(eq("survey.submitted"), eq(anonymousId.toString()), any(Map.class));
    }

    @Test
    void shouldSubmitSurveyWithoutActiveQuestionnaire() {
        UUID anonymousId = UUID.randomUUID();
        HealthSurvey survey = HealthSurvey.builder().anonymousId(anonymousId).build();

        when(questionnaireService.getActiveQuestionnaire()).thenReturn(Optional.empty());
        when(repository.save(survey)).thenReturn(survey);

        HealthSurvey result = service.submitSurvey(survey);

        assertSame(survey, result);
        assertFalse(survey.getHasFever());
        assertFalse(survey.getHasCough());
        verifyNoInteractions(symptomMapper);
        verify(kafkaTemplate).send(eq("survey.submitted"), eq(anonymousId.toString()), any(Map.class));
    }

    @Test
    void shouldMarkSurveyAsPendingWhenAttachmentIsPresent() {
        HealthSurvey survey = HealthSurvey.builder()
                .anonymousId(UUID.randomUUID())
                .attachmentPath("certificate.pdf")
                .build();

        when(questionnaireService.getActiveQuestionnaire()).thenReturn(Optional.empty());
        when(repository.save(survey)).thenReturn(survey);

        service.submitSurvey(survey);

        assertEquals(ValidationStatus.PENDING, survey.getValidationStatus());
    }

    @Test
    void shouldReturnPendingSurveys() {
        List<HealthSurvey> surveys = List.of(HealthSurvey.builder().build());
        when(repository.findByAttachmentPathIsNotNullAndValidationStatus(ValidationStatus.PENDING))
                .thenReturn(surveys);

        List<HealthSurvey> result = service.getPendingSurveys();

        assertSame(surveys, result);
        verify(repository).findByAttachmentPathIsNotNullAndValidationStatus(ValidationStatus.PENDING);
    }

    @Test
    void shouldApproveSurveyAndEmitValidatedEvent() {
        UUID surveyId = UUID.randomUUID();
        UUID anonymousId = UUID.randomUUID();
        UUID adminId = UUID.randomUUID();
        HealthSurvey survey = HealthSurvey.builder()
                .id(surveyId)
                .anonymousId(anonymousId)
                .build();

        when(repository.findById(surveyId)).thenReturn(Optional.of(survey));
        when(repository.save(survey)).thenReturn(survey);

        service.validateSurvey(surveyId, ValidationStatus.APPROVED, adminId);

        assertEquals(ValidationStatus.APPROVED, survey.getValidationStatus());
        assertEquals(adminId, survey.getValidatedBy());
        verify(repository).save(survey);
        verify(kafkaTemplate).send(eq("certificate.validated"), eq(anonymousId.toString()), any(Map.class));
    }

    @Test
    void shouldThrowWhenValidatingMissingSurvey() {
        UUID surveyId = UUID.randomUUID();
        when(repository.findById(surveyId)).thenReturn(Optional.empty());

        RuntimeException exception = assertThrows(RuntimeException.class,
                () -> service.validateSurvey(surveyId, ValidationStatus.APPROVED, UUID.randomUUID()));

        assertTrue(exception.getMessage().contains(surveyId.toString()));
        verify(repository, never()).save(any(HealthSurvey.class));
        verifyNoInteractions(kafkaTemplate);
    }
}
