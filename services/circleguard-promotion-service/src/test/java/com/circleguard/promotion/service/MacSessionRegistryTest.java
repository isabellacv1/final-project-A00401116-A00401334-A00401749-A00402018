package com.circleguard.promotion.service;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

import java.time.Duration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class MacSessionRegistryTest {

    @Mock
    private StringRedisTemplate redisTemplate;

    @Mock
    private ValueOperations<String, String> valueOperations;

    private MacSessionRegistry registry;

    @BeforeEach
    void setUp() {
        registry = new MacSessionRegistry(redisTemplate);
    }

    @Test
    void registerSession_StoresAnonymousIdWithLowercaseKeyAndTtl() {
        when(redisTemplate.opsForValue()).thenReturn(valueOperations);

        registry.registerSession("AA:BB:CC:DD:EE:FF", "anon-123");

        verify(valueOperations).set("session:mac:aa:bb:cc:dd:ee:ff", "anon-123", Duration.ofHours(8));
    }

    @Test
    void getAnonymousId_UsesLowercaseKey() {
        when(redisTemplate.opsForValue()).thenReturn(valueOperations);
        when(valueOperations.get("session:mac:aa:bb:cc:dd:ee:ff")).thenReturn("anon-123");

        String result = registry.getAnonymousId("AA:BB:CC:DD:EE:FF");

        assertEquals("anon-123", result);
    }

    @Test
    void closeSession_DeletesLowercaseKey() {
        registry.closeSession("AA:BB:CC:DD:EE:FF");

        verify(redisTemplate).delete("session:mac:aa:bb:cc:dd:ee:ff");
    }
}
