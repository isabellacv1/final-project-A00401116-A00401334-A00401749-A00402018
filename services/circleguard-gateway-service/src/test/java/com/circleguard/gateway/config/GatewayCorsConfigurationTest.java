package com.circleguard.gateway.config;

import com.circleguard.gateway.controller.GateController;
import com.circleguard.gateway.service.QrValidationService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpHeaders;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.options;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(GateController.class)
@Import(GatewayCorsConfiguration.class)
class GatewayCorsConfigurationTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private QrValidationService validationService;

    @Test
    void preflightFromAllowedOriginReturnsCorsHeaders() throws Exception {
        mockMvc.perform(options("/api/v1/gate/validate")
                        .header(HttpHeaders.ORIGIN, "http://localhost:8081")
                        .header(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "POST")
                        .header(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "content-type"))
                .andExpect(status().isOk())
                .andExpect(header().string(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN, "http://localhost:8081"));
    }

    @Test
    void preflightFromDisallowedOriginIsForbidden() throws Exception {
        mockMvc.perform(options("/api/v1/gate/validate")
                        .header(HttpHeaders.ORIGIN, "https://untrusted.example")
                        .header(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "POST")
                        .header(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS, "content-type"))
                .andExpect(status().isForbidden());
    }
}
