package com.circleguard.promotion.controller;

import com.circleguard.promotion.model.Building;
import com.circleguard.promotion.model.Floor;
import com.circleguard.promotion.security.SecurityConfig;
import com.circleguard.promotion.service.AccessPointService;
import com.circleguard.promotion.service.FloorService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.web.servlet.MockMvc;

import java.util.UUID;

import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(FloorController.class)
@Import(SecurityConfig.class)
class FloorControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private FloorService floorService;

    @MockBean
    private AccessPointService accessPointService;

    @Test
    @WithMockUser(authorities = "ADMIN")
    void updateFloor_WithAdmin_ReturnsMappedFloor() throws Exception {
        UUID buildingId = UUID.randomUUID();
        UUID floorId = UUID.randomUUID();
        Building building = Building.builder().id(buildingId).name("Engineering").build();
        Floor floor = Floor.builder()
                .id(floorId)
                .building(building)
                .floorNumber(4)
                .name("Level 4")
                .floorPlanUrl("http://floor.plan/4")
                .build();
        when(floorService.updateFloor(floorId, 4, "Level 4", "http://floor.plan/4"))
                .thenReturn(floor);

        mockMvc.perform(put("/api/v1/floors/{id}", floorId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"floorNumber\":4,\"name\":\"Level 4\","
                                + "\"floorPlanUrl\":\"http://floor.plan/4\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(floorId.toString()))
                .andExpect(jsonPath("$.buildingId").value(buildingId.toString()))
                .andExpect(jsonPath("$.floorNumber").value(4))
                .andExpect(jsonPath("$.name").value("Level 4"))
                .andExpect(jsonPath("$.floorPlanUrl").value("http://floor.plan/4"));

        verify(floorService).updateFloor(floorId, 4, "Level 4", "http://floor.plan/4");
    }
}
