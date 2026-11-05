package com.sorryread.sorryread_mobile

import java.io.File
import java.nio.file.Files
import org.junit.Test
import org.junit.Assert.*

class StorageFilesTest {
    @Test fun clearingOnlyRebuildableDataPreservesIndexPreferencesFontsAndUserRecords() {
        val root = Files.createTempDirectory("storage-policy").toFile()
        try {
            fun seed(name: String) = File(root, name).also { it.parentFile?.mkdirs(); it.writeText("retained data") }
            val reading = File(root, "files/reading")
            val cache = File(root, "cache")
            val external = File(root, "external/cache")
            val hash = "a".repeat(64)
            val removable = listOf(
                seed("files/reading/chapter-$hash.json"),
                seed("files/reading/catalog-$hash.json.tmp"),
                seed("cache/images/cover"), seed("external/cache/temp")
            )
            val retained = listOf(
                seed("files/reading/preferences.json"), seed("files/reading/preferences.json.tmp"),
                seed("files/reading/imported-font.otf"), seed("files/reading/chapter-not-a-cache.json"),
                seed("files/reader.db"), seed("databases/yeshe_index.db"),
                seed("databases/yeshe_index.db-wal"), seed("shared_prefs/secure.xml"),
                seed("files/downloads/chapter-$hash.json"), seed("app_webview/Cookies")
            )
            val policy = StorageFiles(reading, listOf(cache, external))
            assertEquals(removable.toSet(), policy.files(listOf(root, cache)).filter(policy::isCache).toSet())
            assertEquals(removable.size + retained.size, policy.files(listOf(root, cache)).size)
            assertEquals(0, policy.clear())
            removable.forEach { assertFalse(it.exists()) }
            retained.forEach { assertEquals("retained data", it.readText()) }
            assertEquals(0, policy.clear())
        } finally { root.deleteRecursively() }
    }
}
