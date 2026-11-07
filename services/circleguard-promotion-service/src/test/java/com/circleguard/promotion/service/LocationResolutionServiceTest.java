package com.circleguard.promotion.service;

import com.circleguard.promotion.model.AccessPoint;
import com.circleguard.promotion.model.Building;
import com.circleguard.promotion.model.Floor;
import com.circleguard.promotion.repository.jpa.AccessPointRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.redis.core.SetOperations;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.kafka.core.KafkaTemplate;

import java.time.Duration;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class LocationResolutionServiceTest {

    @Mock
    private AccessPointRepository accessPointRepository;

    @Mock
    private MacSessionRegistry sessionRegistry;

    @Mock
    private GraphService graphService;

    @Mock
    private KafkaTemplate<String, Object> kafkaTemplate;

    @Mock
    private StringRedisTemplate redisTemplate;

    @Mock
    private SetOperations<String, String> setOperations;

    private LocationResolutionService locationResolutionService;

    @BeforeEach
    void setUp() {
        locationResolutionService = new LocationResolutionService(
                accessPointRepository, sessionRegistry, graphService, kafkaTemplate, redisTemplate);
    }

    @Test
    void processSignal_UnknownAccessPoint_DoesNothing() {
        when(accessPointRepository.findByMacAddress("UNKNOWN")).thenReturn(Optional.empty());

        locationResolutionService.processSignal("UNKNOWN", "device-1", -70.0);

        verifyNoInteractions(sessionRegistry, kafkaTemplate, redisTemplate, graphService);
    }

    @Test
    void processSignal_UnmappedDevice_DoesNothing() {
        AccessPoint accessPoint = buildAccessPoint();
        when(accessPointRepository.findByMacAddress("AP-1")).thenReturn(Optional.of(accessPoint));
        when(sessionRegistry.getAnonymousId("device-1")).thenReturn(null);

        locationResolutionService.processSignal("AP-1", "device-1", -70.0);

        verifyNoInteractions(kafkaTemplate, redisTemplate, graphService);
    }

    @Test
    void processSignal_KnownDevice_EmitsEventAndRecordsEncounterWithOtherUsers() {
        AccessPoint accessPoint = buildAccessPoint();
        when(accessPointRepository.findByMacAddress("AP-1")).thenReturn(Optional.of(accessPoint));
        when(sessionRegistry.getAnonymousId("device-1")).thenReturn("anon-1");
        when(redisTemplate.opsForSet()).thenReturn(setOperations);
        when(setOperations.members("spatial:location:" + accessPoint.getId()))
                .thenReturn(Set.of("anon-1", "anon-2"));

        locationResolutionService.processSignal("AP-1", "device-1", -55.5);

        ArgumentCaptor<Map<String, Object>> eventCaptor = ArgumentCaptor.forClass(Map.class);
        verify(kafkaTemplate).send(eq("proximity.detected"), eq("anon-1"), eventCaptor.capture());
        Map<String, Object> event = eventCaptor.getValue();
        assertEquals("anon-1", event.get("anonymousId"));
        assertEquals(accessPoint.getFloor().getBuilding().getId(), event.get("buildingId"));
        assertEquals(accessPoint.getFloor().getId(), event.get("floorId"));
        assertEquals(-55.5, event.get("rssi"));
        assertNotNull(event.get("timestamp"));

        verify(graphService).recordEncounter("anon-1", "anon-2", accessPoint.getId().toString());
        verify(graphService, never()).recordEncounter("anon-1", "anon-1", accessPoint.getId().toString());
        verify(setOperations).add("spatial:location:" + accessPoint.getId(), "anon-1");
        verify(redisTemplate).expire("spatial:location:" + accessPoint.getId(), Duration.ofMinutes(10));
        verify(graphService).detectAndFormCircles(accessPoint.getId().toString());
    }

    @Test
    void processSignal_WhenLocationHasNoMembers_StillRegistersAndDetectsCircles() {
        AccessPoint accessPoint = buildAccessPoint();
        when(accessPointRepository.findByMacAddress("AP-1")).thenReturn(Optional.of(accessPoint));
        when(sessionRegistry.getAnonymousId("device-1")).thenReturn("anon-1");
        when(redisTemplate.opsForSet()).thenReturn(setOperations);
        when(setOperations.members(anyString())).thenReturn(null);

        locationResolutionService.processSignal("AP-1", "device-1", -60.0);

        verify(graphService, never()).recordEncounter(anyString(), anyString(), anyString());
        verify(setOperations).add("spatial:location:" + accessPoint.getId(), "anon-1");
        verify(redisTemplate).expire(eq("spatial:location:" + accessPoint.getId()), any(Duration.class));
        verify(graphService).detectAndFormCircles(accessPoint.getId().toString());
    }

    private AccessPoint buildAccessPoint() {
        UUID buildingId = UUID.randomUUID();
        UUID floorId = UUID.randomUUID();
        UUID accessPointId = UUID.randomUUID();
        Building building = Building.builder().id(buildingId).name("Building").build();
        Floor floor = Floor.builder().id(floorId).building(building).floorNumber(2).build();
        return AccessPoint.builder()
                .id(accessPointId)
                .floor(floor)
                .macAddress("AP-1")
                .coordinateX(1.5)
                .coordinateY(2.5)
                .name("AP One")
                .build();
    }
}
