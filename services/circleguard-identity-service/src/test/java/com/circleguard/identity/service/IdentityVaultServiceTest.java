package com.circleguard.identity.service;

import com.circleguard.identity.model.IdentityMapping;
import com.circleguard.identity.repository.IdentityMappingRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.http.HttpStatus;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.web.server.ResponseStatusException;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class IdentityVaultServiceTest {

    private static final String HASH_SALT = "test-hash-salt";

    @Mock
    private IdentityMappingRepository repository;

    private IdentityVaultService service;

    @BeforeEach
    void setUp() {
        service = new IdentityVaultService(repository);
        ReflectionTestUtils.setField(service, "hashSalt", HASH_SALT);
    }

    @Test
    void shouldCreateMappingWhenIdentityDoesNotExist() throws Exception {
        UUID anonymousId = UUID.randomUUID();
        when(repository.findByIdentityHash(anyString())).thenReturn(Optional.empty());
        when(repository.save(any(IdentityMapping.class))).thenAnswer(invocation -> {
            IdentityMapping mapping = invocation.getArgument(0);
            mapping.setAnonymousId(anonymousId);
            return mapping;
        });

        UUID result = service.getOrCreateAnonymousId("user@example.com");

        assertEquals(anonymousId, result);
        ArgumentCaptor<IdentityMapping> captor = ArgumentCaptor.forClass(IdentityMapping.class);
        verify(repository).save(captor.capture());
        IdentityMapping saved = captor.getValue();
        assertEquals("user@example.com", saved.getRealIdentity());
        assertEquals(expectedHash("user@example.com"), saved.getIdentityHash());
        assertNotNull(saved.getSalt());
        assertFalse(saved.getSalt().isBlank());
    }

    @Test
    void shouldReturnExistingMappingWithoutCreatingAnotherOne() {
        UUID existingId = UUID.randomUUID();
        IdentityMapping existing = IdentityMapping.builder()
                .anonymousId(existingId)
                .realIdentity("user@example.com")
                .identityHash("stored-hash")
                .salt("stored-salt")
                .build();
        when(repository.findByIdentityHash(anyString())).thenReturn(Optional.of(existing));

        UUID result = service.getOrCreateAnonymousId("user@example.com");

        assertEquals(existingId, result);
        verify(repository, never()).save(any(IdentityMapping.class));
    }

    @Test
    void shouldResolveRealIdentityWhenMappingExists() {
        UUID anonymousId = UUID.randomUUID();
        IdentityMapping mapping = IdentityMapping.builder()
                .anonymousId(anonymousId)
                .realIdentity("user@example.com")
                .identityHash("stored-hash")
                .salt("stored-salt")
                .build();
        when(repository.findById(anonymousId)).thenReturn(Optional.of(mapping));

        String result = service.resolveRealIdentity(anonymousId);

        assertEquals("user@example.com", result);
    }

    @Test
    void shouldThrowNotFoundWhenMappingDoesNotExist() {
        UUID anonymousId = UUID.randomUUID();
        when(repository.findById(anonymousId)).thenReturn(Optional.empty());

        ResponseStatusException exception = assertThrows(ResponseStatusException.class,
                () -> service.resolveRealIdentity(anonymousId));

        assertEquals(HttpStatus.NOT_FOUND, exception.getStatusCode());
        assertEquals("Identity not found", exception.getReason());
    }

    private String expectedHash(String identity) throws Exception {
        byte[] hash = MessageDigest.getInstance("SHA-256")
                .digest((identity + HASH_SALT).getBytes(StandardCharsets.UTF_8));
        return HexFormat.of().formatHex(hash);
    }
}
