package com.circleguard.auth.service;

import com.circleguard.auth.model.LocalUser;
import com.circleguard.auth.model.Permission;
import com.circleguard.auth.model.Role;
import com.circleguard.auth.repository.LocalUserRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.authentication.DisabledException;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UsernameNotFoundException;

import java.util.Optional;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class CustomUserDetailsServiceTest {

    @Mock
    private LocalUserRepository userRepository;

    @InjectMocks
    private CustomUserDetailsService service;

    @Test
    void shouldLoadUserWithRolesAndPermissions() {
        Permission readAlerts = Permission.builder().name("ALERT_READ").build();
        Role admin = Role.builder().name("ADMIN").permissions(Set.of(readAlerts)).build();
        LocalUser user = LocalUser.builder()
                .username("admin")
                .password("encoded-password")
                .isActive(true)
                .roles(Set.of(admin))
                .build();

        when(userRepository.findByUsername("admin")).thenReturn(Optional.of(user));

        UserDetails details = service.loadUserByUsername("admin");

        assertEquals("admin", details.getUsername());
        assertEquals("encoded-password", details.getPassword());
        assertTrue(details.getAuthorities().stream()
                .anyMatch(authority -> authority.getAuthority().equals("ROLE_ADMIN")));
        assertTrue(details.getAuthorities().stream()
                .anyMatch(authority -> authority.getAuthority().equals("ALERT_READ")));
    }

    @Test
    void shouldThrowWhenUserDoesNotExist() {
        when(userRepository.findByUsername("missing")).thenReturn(Optional.empty());

        UsernameNotFoundException exception = assertThrows(UsernameNotFoundException.class,
                () -> service.loadUserByUsername("missing"));

        assertTrue(exception.getMessage().contains("missing"));
    }

    @Test
    void shouldThrowWhenUserIsDisabled() {
        LocalUser user = LocalUser.builder()
                .username("disabled")
                .password("encoded-password")
                .isActive(false)
                .roles(Set.of())
                .build();

        when(userRepository.findByUsername("disabled")).thenReturn(Optional.of(user));

        DisabledException exception = assertThrows(DisabledException.class,
                () -> service.loadUserByUsername("disabled"));

        assertEquals("User account is disabled", exception.getMessage());
    }
}
