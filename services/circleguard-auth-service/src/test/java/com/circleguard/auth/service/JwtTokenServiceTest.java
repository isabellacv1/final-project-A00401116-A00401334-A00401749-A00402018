package com.circleguard.auth.service;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.junit.jupiter.api.Test;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.authority.SimpleGrantedAuthority;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.mock;

class JwtTokenServiceTest {

    private static final String SECRET = "my-super-secret-test-key-32-chars-long";
    private static final long EXPIRATION = 3600000L;

    private final JwtTokenService service = new JwtTokenService(SECRET, EXPIRATION);

    @Test
    void shouldGenerateTokenWithSubjectAndPermissions() {
        UUID anonymousId = UUID.randomUUID();
        Authentication auth = mock(Authentication.class);
        doReturn(List.of(
                new SimpleGrantedAuthority("ROLE_USER"),
                new SimpleGrantedAuthority("ALERT_READ")
        )).when(auth).getAuthorities();

        String token = service.generateToken(anonymousId, auth);
        Claims claims = parse(token);

        assertNotNull(token);
        assertEquals(anonymousId.toString(), claims.getSubject());
        assertEquals(List.of("ROLE_USER", "ALERT_READ"), claims.get("permissions", List.class));
        assertNotNull(claims.getIssuedAt());
        assertTrue(claims.getExpiration().getTime() > System.currentTimeMillis());
    }

    private Claims parse(String token) {
        return Jwts.parserBuilder()
                .setSigningKey(Keys.hmacShaKeyFor(SECRET.getBytes()))
                .build()
                .parseClaimsJws(token)
                .getBody();
    }
}
