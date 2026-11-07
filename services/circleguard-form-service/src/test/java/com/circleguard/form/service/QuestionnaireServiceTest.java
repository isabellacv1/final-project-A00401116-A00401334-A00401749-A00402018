package com.circleguard.form.service;

import com.circleguard.form.model.Question;
import com.circleguard.form.model.Questionnaire;
import com.circleguard.form.repository.QuestionnaireRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class QuestionnaireServiceTest {

    @Mock
    private QuestionnaireRepository repository;

    @InjectMocks
    private QuestionnaireService service;

    @Test
    void shouldSaveQuestionnaireAndAssignItToItsQuestions() {
        Question first = Question.builder().id(UUID.randomUUID()).build();
        Question second = Question.builder().id(UUID.randomUUID()).build();
        Questionnaire questionnaire = Questionnaire.builder()
                .title("Daily Health Check")
                .questions(List.of(first, second))
                .build();

        when(repository.save(questionnaire)).thenReturn(questionnaire);

        Questionnaire result = service.saveQuestionnaire(questionnaire);

        assertSame(questionnaire, result);
        assertSame(questionnaire, first.getQuestionnaire());
        assertSame(questionnaire, second.getQuestionnaire());
    }

    @Test
    void shouldDeactivateActiveQuestionnairesAndActivateTarget() {
        UUID targetId = UUID.randomUUID();
        Questionnaire active = Questionnaire.builder().id(UUID.randomUUID()).isActive(true).build();
        Questionnaire inactive = Questionnaire.builder().id(UUID.randomUUID()).isActive(false).build();
        Questionnaire target = Questionnaire.builder().id(targetId).isActive(false).build();

        when(repository.findAll()).thenReturn(List.of(active, inactive, target));
        when(repository.findById(targetId)).thenReturn(Optional.of(target));

        service.activateQuestionnaire(targetId);

        assertFalse(active.getIsActive());
        assertFalse(inactive.getIsActive());
        assertTrue(target.getIsActive());
        verify(repository).save(active);
        verify(repository, never()).save(inactive);
        verify(repository).save(target);
    }
}
