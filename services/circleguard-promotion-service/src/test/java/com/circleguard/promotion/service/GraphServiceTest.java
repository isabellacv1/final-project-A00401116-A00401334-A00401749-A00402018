package com.circleguard.promotion.service;

import com.circleguard.promotion.repository.graph.UserNodeRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.neo4j.core.Neo4jClient;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.longThat;
import static org.mockito.Mockito.RETURNS_DEEP_STUBS;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class GraphServiceTest {

    @Mock
    private UserNodeRepository userNodeRepository;

    @Mock
    private Neo4jClient neo4jClient;

    private GraphService graphService;

    @BeforeEach
    void setUp() {
        graphService = new GraphService(userNodeRepository, neo4jClient);
    }

    @Test
    void recordEncounter_DelegatesToRepositoryWithCurrentTimestamp() {
        graphService.recordEncounter("user-a", "user-b", "location-1");

        verify(userNodeRepository).recordEncounter(
                eq("user-a"),
                eq("user-b"),
                longThat(timestamp -> timestamp != null && timestamp > 0),
                eq("location-1"));
    }

    @Test
    void detectAndFormCircles_RunsClusterQueryForLocation() {
        Neo4jClient.UnboundRunnableSpec runnableSpec = mock(Neo4jClient.UnboundRunnableSpec.class, RETURNS_DEEP_STUBS);
        when(neo4jClient.query(anyString())).thenReturn(runnableSpec);

        graphService.detectAndFormCircles("location-1");

        verify(neo4jClient).query(contains("MERGE (c:Circle"));
        verify(runnableSpec).bind("location-1");
    }
}
