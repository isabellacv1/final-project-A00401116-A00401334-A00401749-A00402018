package com.circleguard.promotion.controller;

import com.circleguard.promotion.model.Building;
import com.circleguard.promotion.model.Floor;
import com.circleguard.promotion.security.SecurityConfig;
import com.circleguard.promotion.service.BuildingService;
import com.circleguard.promotion.service.FloorService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.web.servlet.MockMvc;

import java.util.List;
import java.util.UUID;

import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(BuildingController.class)
@Import(SecurityConfig.class)
class BuildingControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private BuildingService buildingService;

    @MockBean
    private FloorService floorService;

    @Test
    @WithMockUser(authorities = "ADMIN")
    void createBuilding_WithAdmin_ReturnsCreatedBuilding() throws Exception {
        UUID id = UUID.randomUUID();
        Building building = Building.builder()
                .id(id)
                .name("Engineering")
                .code("ENG")
                .description("Main building")
                .latitude(4.6)
                .longitude(-74.1)
                .address("Street 1")
                .build();
        when(buildingService.createBuilding("Engineering", "ENG", "Main building", 4.6, -74.1, "Street 1"))
                .thenReturn(building);

        mockMvc.perform(post("/api/v1/buildings")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"Engineering\",\"code\":\"ENG\",\"description\":\"Main building\","
                                + "\"latitude\":4.6,\"longitude\":-74.1,\"address\":\"Street 1\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(id.toString()))
                .andExpect(jsonPath("$.name").value("Engineering"))
                .andExpect(jsonPath("$.code").value("ENG"))
                .andExpect(jsonPath("$.latitude").value(4.6))
                .andExpect(jsonPath("$.longitude").value(-74.1))
                .andExpect(jsonPath("$.address").value("Street 1"));

        verify(buildingService).createBuilding("Engineering", "ENG", "Main building", 4.6, -74.1, "Street 1");
    }

    @Test
    void listBuildings_ReturnsMappedBuildingsAndFloors() throws Exception {
        UUID buildingId = UUID.randomUUID();
        UUID floorId = UUID.randomUUID();
        Building building = Building.builder().id(buildingId).name("Engineering").code("ENG").build();
        Floor floor = Floor.builder()
                .id(floorId)
                .building(building)
                .floorNumber(2)
                .name("Level 2")
                .floorPlanUrl("http://floor.plan")
                .build();
        building.setFloors(List.of(floor));
        when(buildingService.getAllBuildings()).thenReturn(List.of(building));

        mockMvc.perform(get("/api/v1/buildings"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].id").value(buildingId.toString()))
                .andExpect(jsonPath("$[0].name").value("Engineering"))
                .andExpect(jsonPath("$[0].floors[0].id").value(floorId.toString()))
                .andExpect(jsonPath("$[0].floors[0].buildingId").value(buildingId.toString()))
                .andExpect(jsonPath("$[0].floors[0].floorNumber").value(2))
                .andExpect(jsonPath("$[0].floors[0].floorPlanUrl").value("http://floor.plan"));
    }

    @Test
    void getFloors_ReturnsFloorsAndHandlesFloorsWithoutBuilding() throws Exception {
        UUID buildingId = UUID.randomUUID();
        Building building = Building.builder().id(buildingId).name("Engineering").build();
        Floor floorWithBuilding = Floor.builder()
                .id(UUID.randomUUID())
                .building(building)
                .floorNumber(1)
                .name("Level 1")
                .build();
        Floor floorWithoutBuilding = Floor.builder()
                .id(UUID.randomUUID())
                .floorNumber(2)
                .name("Level 2")
                .build();
        when(floorService.getFloorsByBuilding(buildingId))
                .thenReturn(List.of(floorWithBuilding, floorWithoutBuilding));

        mockMvc.perform(get("/api/v1/buildings/{id}/floors", buildingId))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].buildingId").value(buildingId.toString()))
                .andExpect(jsonPath("$[0].floorNumber").value(1))
                .andExpect(jsonPath("$[1].floorNumber").value(2));
    }

    @Test
    @WithMockUser(authorities = "ADMIN")
    void addFloor_WithAdmin_ReturnsCreatedFloor() throws Exception {
        UUID buildingId = UUID.randomUUID();
        UUID floorId = UUID.randomUUID();
        Building building = Building.builder().id(buildingId).name("Engineering").build();
        Floor floor = Floor.builder()
                .id(floorId)
                .building(building)
                .floorNumber(3)
                .name("Level 3")
                .build();
        when(floorService.addFloor(buildingId, 3, "Level 3")).thenReturn(floor);

        mockMvc.perform(post("/api/v1/buildings/{id}/floors", buildingId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"floorNumber\":3,\"name\":\"Level 3\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(floorId.toString()))
                .andExpect(jsonPath("$.buildingId").value(buildingId.toString()))
                .andExpect(jsonPath("$.floorNumber").value(3))
                .andExpect(jsonPath("$.name").value("Level 3"));

        verify(floorService).addFloor(buildingId, 3, "Level 3");
    }

    @Test
    @WithMockUser(authorities = "ADMIN")
    void updateBuilding_WithAdmin_ReturnsUpdatedBuilding() throws Exception {
        UUID id = UUID.randomUUID();
        Building building = Building.builder()
                .id(id)
                .name("Updated")
                .code("UPD")
                .description("Updated description")
                .latitude(5.0)
                .longitude(-75.0)
                .address("Updated address")
                .build();
        when(buildingService.updateBuilding(id, "Updated", "UPD", "Updated description", 5.0, -75.0, "Updated address"))
                .thenReturn(building);

        mockMvc.perform(put("/api/v1/buildings/{id}", id)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"Updated\",\"code\":\"UPD\",\"description\":\"Updated description\","
                                + "\"latitude\":5.0,\"longitude\":-75.0,\"address\":\"Updated address\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(id.toString()))
                .andExpect(jsonPath("$.name").value("Updated"))
                .andExpect(jsonPath("$.code").value("UPD"));

        verify(buildingService).updateBuilding(
                id, "Updated", "UPD", "Updated description", 5.0, -75.0, "Updated address");
    }

    @Test
    void deleteBuilding_DeletesBuilding() throws Exception {
        UUID id = UUID.randomUUID();

        mockMvc.perform(delete("/api/v1/buildings/{id}", id))
                .andExpect(status().isOk());

        verify(buildingService).deleteBuilding(id);
    }

    @Test
    @WithMockUser(authorities = "STUDENT")
    void createBuilding_WithoutAdmin_ReturnsForbidden() throws Exception {
        mockMvc.perform(post("/api/v1/buildings")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"Engineering\",\"code\":\"ENG\"}"))
                .andExpect(status().isForbidden());

        verifyNoInteractions(buildingService);
    }
}
