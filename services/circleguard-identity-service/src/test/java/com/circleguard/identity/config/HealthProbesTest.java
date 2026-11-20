package com.circleguard.identity.config;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * HU-28: the container healthcheck calls the readiness probe without a token, so
 * identity (which protects every other route with a JWT) must let it through, and
 * only the health endpoint may be exposed.
 *
 * The test application.yml replaces the main one, so the management settings of
 * src/main/resources/application.yml are repeated here.
 */
@SpringBootTest(properties = {
        "management.endpoints.web.exposure.include=health",
        "management.endpoint.health.show-details=never",
        "management.endpoint.health.probes.enabled=true",
        "management.endpoint.health.group.readiness.include=readinessState,db"
})
@AutoConfigureMockMvc
class HealthProbesTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private KafkaTemplate<String, Object> kafkaTemplate;

    @Test
    void livenessIsPublicAndUp() throws Exception {
        mockMvc.perform(get("/actuator/health/liveness"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    void readinessIsPublicAndChecksTheDatabase() throws Exception {
        mockMvc.perform(get("/actuator/health/readiness"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"))
                // show-details=never: the probe never reveals the components
                .andExpect(jsonPath("$.components").doesNotExist());
    }

    @Test
    @WithMockUser
    void otherActuatorEndpointsAreNotExposed() throws Exception {
        mockMvc.perform(get("/actuator/env")).andExpect(status().isNotFound());
    }

    @Test
    void businessRoutesStillRequireAToken() throws Exception {
        mockMvc.perform(get("/api/v1/identities/lookup/00000000-0000-0000-0000-000000000000"))
                .andExpect(status().isUnauthorized());
    }
}
