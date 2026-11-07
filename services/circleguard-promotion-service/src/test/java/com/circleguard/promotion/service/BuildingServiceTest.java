package com.circleguard.promotion.service;

import com.circleguard.promotion.model.Building;
import com.circleguard.promotion.model.Floor;
import com.circleguard.promotion.repository.jpa.BuildingRepository;
import com.circleguard.promotion.repository.jpa.FloorRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class BuildingServiceTest {

    @Mock
    private BuildingRepository buildingRepository;

    @Mock
    private FloorRepository floorRepository;

    private BuildingService buildingService;

    @BeforeEach
    void setUp() {
        buildingService = new BuildingService(buildingRepository, floorRepository);
    }

    @Test
    void createBuilding_SavesAllAttributes() {
        when(buildingRepository.save(any(Building.class))).thenAnswer(invocation -> invocation.getArgument(0));

        Building result = buildingService.createBuilding(
                "Engineering", "ENG", "Main building", 4.6, -74.1, "Street 1");

        assertEquals("Engineering", result.getName());
        assertEquals("ENG", result.getCode());
        assertEquals("Main building", result.getDescription());
        assertEquals(4.6, result.getLatitude());
        assertEquals(-74.1, result.getLongitude());
        assertEquals("Street 1", result.getAddress());
        verify(buildingRepository).save(result);
    }

    @Test
    void getAllBuildings_ReturnsRepositoryResult() {
        List<Building> buildings = List.of(Building.builder().name("A").build());
        when(buildingRepository.findAll()).thenReturn(buildings);

        assertSame(buildings, buildingService.getAllBuildings());
    }

    @Test
    void updateBuilding_UpdatesExistingBuilding() {
        UUID id = UUID.randomUUID();
        Building building = Building.builder().id(id).name("Old").build();
        when(buildingRepository.findById(id)).thenReturn(Optional.of(building));
        when(buildingRepository.save(building)).thenReturn(building);

        Building result = buildingService.updateBuilding(
                id, "New", "NEW", "Updated", 1.0, 2.0, "New address");

        assertEquals("New", result.getName());
        assertEquals("NEW", result.getCode());
        assertEquals("Updated", result.getDescription());
        assertEquals(1.0, result.getLatitude());
        assertEquals(2.0, result.getLongitude());
        assertEquals("New address", result.getAddress());
    }

    @Test
    void updateBuilding_ThrowsWhenBuildingDoesNotExist() {
        UUID id = UUID.randomUUID();
        when(buildingRepository.findById(id)).thenReturn(Optional.empty());

        RuntimeException exception = assertThrows(RuntimeException.class,
                () -> buildingService.updateBuilding(id, "New", "NEW", "Updated", 1.0, 2.0, "Address"));

        assertEquals("Building not found", exception.getMessage());
        verify(buildingRepository, never()).save(any(Building.class));
    }

    @Test
    void deleteBuilding_ThrowsWhenBuildingHasFloors() {
        UUID id = UUID.randomUUID();
        when(floorRepository.findByBuildingId(id)).thenReturn(List.of(Floor.builder().build()));

        RuntimeException exception = assertThrows(RuntimeException.class,
                () -> buildingService.deleteBuilding(id));

        assertEquals("Cannot delete building with existing floors", exception.getMessage());
        verify(buildingRepository, never()).deleteById(id);
    }

    @Test
    void deleteBuilding_DeletesWhenBuildingHasNoFloors() {
        UUID id = UUID.randomUUID();
        when(floorRepository.findByBuildingId(id)).thenReturn(List.of());

        buildingService.deleteBuilding(id);

        verify(buildingRepository).deleteById(id);
    }
}
