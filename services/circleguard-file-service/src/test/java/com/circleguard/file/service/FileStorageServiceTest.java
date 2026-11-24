package com.circleguard.file.service;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.mock.web.MockMultipartFile;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/**
 * The storage directory comes from configuration (FILE_STORAGE_PATH), so the same
 * image can write to a mounted volume in every environment.
 */
class FileStorageServiceTest {

    @TempDir
    Path tempDir;

    @Test
    void createsTheConfiguredDirectory() {
        Path storage = tempDir.resolve("uploads");

        new FileStorageService(storage.toString());

        assertTrue(Files.isDirectory(storage));
    }

    @Test
    void storesTheFileInTheConfiguredDirectory() throws IOException {
        Path storage = tempDir.resolve("uploads");
        FileStorageService service = new FileStorageService(storage.toString());
        MockMultipartFile file = new MockMultipartFile(
                "file", "evidence.txt", "text/plain", "contenido".getBytes(StandardCharsets.UTF_8));

        String filename = service.saveFile(file);

        assertTrue(filename.endsWith("_evidence.txt"));
        assertEquals("contenido", Files.readString(storage.resolve(filename)));
    }

    @Test
    void failsWhenTheDirectoryCannotBeCreated() throws IOException {
        Path regularFile = Files.createFile(tempDir.resolve("not-a-directory"));
        String storagePath = regularFile.resolve("uploads").toString();

        RuntimeException error = assertThrows(RuntimeException.class,
                () -> new FileStorageService(storagePath));

        assertEquals("Could not initialize storage", error.getMessage());
    }
}
