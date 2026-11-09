package com.circleguard.promotion.service;

import com.circleguard.promotion.model.AccessPoint;
import com.circleguard.promotion.model.Floor;
import com.circleguard.promotion.repository.jpa.AccessPointRepository;
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
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AccessPointServiceTest {

    @Mock
    private AccessPointRepository accessPointRepository;

    @Mock
    private FloorRepository floorRepository;

    private AccessPointService accessPointService;

    @BeforeEach
    void setUp() {
        accessPointService = new AccessPointService(accessPointRepository, floorRepository);
    }

    @Test
    void registerAccessPoint_SavesAccessPointOnExistingFloor() {
        UUID floorId = UUID.randomUUID();
        Floor floor = Floor.builder().id(floorId).floorNumber(2).build();
        when(floorRepository.findById(floorId)).thenReturn(Optional.of(floor));
        when(accessPointRepository.save(any(AccessPoint.class))).thenAnswer(invocation -> invocation.getArgument(0));

        AccessPoint result = accessPointService.registerAccessPoint(
                floorId, "AA:BB:CC", 10.0, 20.0, "Hall AP");

        assertEquals(floor, result.getFloor());
        assertEquals("AA:BB:CC", result.getMacAddress());
        assertEquals(10.0, result.getCoordinateX());
        assertEquals(20.0, result.getCoordinateY());
        assertEquals("Hall AP", result.getName());
        verify(accessPointRepository).save(result);
    }

    @Test
    void registerAccessPoint_ThrowsWhenFloorDoesNotExist() {
        UUID floorId = UUID.randomUUID();
        when(floorRepository.findById(floorId)).thenReturn(Optional.empty());

        RuntimeException exception = assertThrows(RuntimeException.class,
                () -> accessPointService.registerAccessPoint(floorId, "AA", 1.0, 2.0, "AP"));

        assertEquals("Floor not found", exception.getMessage());
        verify(accessPointRepository, never()).save(any(AccessPoint.class));
    }

    @Test
    void getAccessPoint_ReturnsRepositoryResult() {
        UUID id = UUID.randomUUID();
        AccessPoint accessPoint = AccessPoint.builder().id(id).macAddress("AA").build();
        when(accessPointRepository.findById(id)).thenReturn(Optional.of(accessPoint));

        Optional<AccessPoint> result = accessPointService.getAccessPoint(id);

        assertTrue(result.isPresent());
        assertSame(accessPoint, result.get());
    }

    @Test
    void getAccessPointsByFloor_ReturnsRepositoryResult() {
        UUID floorId = UUID.randomUUID();
        List<AccessPoint> accessPoints = List.of(AccessPoint.builder().macAddress("AA").build());
        when(accessPointRepository.findByFloorId(floorId)).thenReturn(accessPoints);

        assertSame(accessPoints, accessPointService.getAccessPointsByFloor(floorId));
    }

    @Test
    void updateAccessPoint_UpdatesExistingAccessPoint() {
        UUID id = UUID.randomUUID();
        AccessPoint accessPoint = AccessPoint.builder().id(id).macAddress("OLD").build();
        when(accessPointRepository.findById(id)).thenReturn(Optional.of(accessPoint));
        when(accessPointRepository.save(accessPoint)).thenReturn(accessPoint);

        AccessPoint result = accessPointService.updateAccessPoint(id, "NEW", 3.0, 4.0, "New AP");

        assertEquals("NEW", result.getMacAddress());
        assertEquals(3.0, result.getCoordinateX());
        assertEquals(4.0, result.getCoordinateY());
        assertEquals("New AP", result.getName());
    }

    @Test
    void updateAccessPoint_ThrowsWhenAccessPointDoesNotExist() {
        UUID id = UUID.randomUUID();
        when(accessPointRepository.findById(id)).thenReturn(Optional.empty());

        RuntimeException exception = assertThrows(RuntimeException.class,
                () -> accessPointService.updateAccessPoint(id, "AA", 1.0, 2.0, "AP"));

        assertEquals("Access Point not found", exception.getMessage());
        verify(accessPointRepository, never()).save(any(AccessPoint.class));
    }

    @Test
    void deleteAccessPoint_DelegatesToRepository() {
        UUID id = UUID.randomUUID();

        accessPointService.deleteAccessPoint(id);

        verify(accessPointRepository).deleteById(id);
    }
}
