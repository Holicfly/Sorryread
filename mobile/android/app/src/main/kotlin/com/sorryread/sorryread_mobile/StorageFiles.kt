package com.sorryread.sorryread_mobile

import java.io.File
import java.nio.file.Files

/** Explicit allowlist: reader preferences, imported fonts and databases are never cache. */
class StorageFiles(private val reading: File, private val cacheRoots: List<File>) {
    private val readerCache = Regex("(?:chapter|catalog)-[0-9a-f]{64}\\.json(?:\\.tmp)?")

    fun isCache(file: File): Boolean {
        val path = file.canonicalFile
        return (path.parentFile == reading.canonicalFile && readerCache.matches(path.name)) ||
            cacheRoots.any { path.toPath().startsWith(it.canonicalFile.toPath()) }
    }

    fun files(roots: List<File>): List<File> {
        val result = linkedMapOf<String, File>()
        fun visit(file: File) {
            if (Files.isSymbolicLink(file.toPath())) return
            if (file.isDirectory) {
                val children = file.listFiles()
                    ?: throw java.io.IOException("无法读取存储目录")
                children.forEach(::visit)
            } else if (file.isFile) result[file.canonicalPath] = file
        }
        roots.forEach(::visit)
        return result.values.toList()
    }

    /** Delete only files selected by the same policy used for statistics. */
    fun clear(): Int {
        var failures = 0
        for (file in files(cacheRoots + reading).filter(::isCache)) {
            if (!file.delete() && file.exists()) failures++
        }
        return failures
    }
}
