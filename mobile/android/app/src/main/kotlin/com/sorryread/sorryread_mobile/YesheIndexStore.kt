package com.sorryread.sorryread_mobile

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File
import java.util.concurrent.Executors

/** Separate local catalog. Does not access the reader's sync database. */
class YesheIndexStore private constructor(private val app: Context) : SQLiteOpenHelper(app, "yeshe_index.db", null, 2) {
    companion object {
        private const val UPDATE_CHECK_INTERVAL = 30 * 60 * 1000L
        private const val UPDATE_CHECK_RETRY = 15 * 60 * 1000L
        private const val STAGING_TABLE = "CREATE TABLE IF NOT EXISTS staged_books(url TEXT PRIMARY KEY, title TEXT NOT NULL, normalized TEXT NOT NULL, ordinal INTEGER NOT NULL)"
        private val updateChecks = Executors.newSingleThreadExecutor()
        @Volatile private var instance: YesheIndexStore? = null
        fun get(context: Context): YesheIndexStore = instance ?: synchronized(this) {
            instance ?: YesheIndexStore(context.applicationContext).also { instance = it; it.setWriteAheadLoggingEnabled(true) }
        }
    }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE books(url TEXT PRIMARY KEY, title TEXT NOT NULL, normalized TEXT NOT NULL, ordinal INTEGER NOT NULL)")
        db.execSQL("CREATE INDEX books_order ON books(ordinal,url)")
        db.execSQL("CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.execSQL(STAGING_TABLE)
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) db.execSQL(STAGING_TABLE)
    }
    @Synchronized fun state(key: String, fallback: String = ""): String = readableDatabase.rawQuery("SELECT value FROM state WHERE key=?", arrayOf(key)).use { if (it.moveToFirst()) it.getString(0) else fallback }
    @Synchronized fun set(vararg values: Pair<String, String>) {
        writableDatabase.beginTransaction()
        try { put(writableDatabase, *values); writableDatabase.setTransactionSuccessful() }
        finally { writableDatabase.endTransaction() }
    }
    private fun put(db: SQLiteDatabase, vararg values: Pair<String, String>) {
        for ((k,v) in values) db.execSQL("INSERT OR REPLACE INTO state(key,value) VALUES(?,?)", arrayOf(k,v))
    }
    @Synchronized fun recordThrottle(until: Long) {
        set("cooldownUntil" to maxOf(until, state("cooldownUntil", "0").toLong()).toString(), "parallelism" to "1")
    }
    @Synchronized fun commit(page: YeshePage, elapsed: Long, bytes: Int, expectedPage: Int? = null, sessionPages: Int = 0, sessionElapsed: Long = 0, parallelism: Int = 1) {
        val db = writableDatabase
        val pageNumber = state("pages", "0").toInt()
        val updating = state("updating") == "1"
        val table = if (updating) "staged_books" else "books"
        require(expectedPage == null || expectedPage == pageNumber + 1) { "书目断点不连续，已停止写入" }
        db.beginTransaction()
        try {
            db.compileStatement("INSERT OR REPLACE INTO $table(url,title,normalized,ordinal) VALUES(?,?,?,?)").use { insert ->
                page.books.forEachIndexed { i, b ->
                    insert.clearBindings()
                    insert.bindString(1,b.url); insert.bindString(2,b.title); insert.bindString(3,YesheCatalog.normalize(b.title)); insert.bindLong(4,(pageNumber * 30 + i).toLong())
                    insert.executeInsert()
                }
            }
            if (page.next == null && updating) {
                // Readers see the previous catalog until the replacement is complete.
                db.execSQL("DELETE FROM books")
                db.execSQL("INSERT INTO books(url,title,normalized,ordinal) SELECT url,title,normalized,ordinal FROM staged_books")
                db.execSQL("DELETE FROM staged_books")
                put(db, "updating" to "0", "updateAvailable" to "0", "nextUpdateCheck" to "0")
            }
            put(db, "next" to (page.next ?: ""), "pages" to (pageNumber + 1).toString(), "total" to page.total.toString(), "elapsed" to (state("elapsed","0").toLong() + elapsed).toString(), "bytes" to (state("bytes","0").toLong() + bytes).toString(), "status" to (if (page.next == null) "complete" else "running"), "updated" to System.currentTimeMillis().toString(), "error" to "", "sessionPages" to sessionPages.toString(), "sessionElapsed" to sessionElapsed.toString(), "parallelism" to parallelism.toString())
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }
    @Synchronized fun refresh() {
        check(!YesheIndexService.deleting && app.getDatabasePath("yeshe_index.db").exists() && state("status") == "complete") { "当前书目尚未缓存完成" }
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.execSQL("DELETE FROM staged_books")
            put(db, "next" to YesheCatalog.FIRST, "pages" to "0", "elapsed" to "0", "bytes" to "0", "sessionPages" to "0", "sessionElapsed" to "0", "status" to "paused", "updating" to "1", "error" to "")
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    @Synchronized fun scheduleUpdateCheck() {
        if (YesheIndexService.running || YesheIndexService.deleting ||
            !app.getDatabasePath("yeshe_index.db").exists() || state("status") != "complete") return
        val now = System.currentTimeMillis()
        if (now < maxOf(state("nextUpdateCheck", "0").toLong(), state("cooldownUntil", "0").toLong())) return
        val revision = state("updated")
        val pages = state("pages", "0").toInt()
        val samplePage = if (pages > 1) state("nextSamplePage", "2").toInt().coerceIn(2, pages) else 1
        set("nextUpdateCheck" to (now + UPDATE_CHECK_RETRY).toString())
        updateChecks.execute {
            val http = YesheHttpTransport()
            try {
                val first = pageDiffers(revision, 1, http.fetch(YesheCatalog.FIRST).page) ?: return@execute
                val changed = if (first || samplePage == 1) first else
                    pageDiffers(revision, samplePage, http.fetch(YesheCatalog.pageUrl(samplePage)).page) ?: return@execute
                // Keep checking a page that differed until it matches or the catalog is replaced.
                val nextSample = if (changed) samplePage else if (samplePage < pages) samplePage + 1 else 2
                finishUpdateCheck(revision, changed, nextSample)
            } catch (e: YesheHttpException) {
                // Respect rate limiting without changing the last known result.
                finishUpdateCheck(revision, retryAt = e.retryAt)
            } catch (_: Exception) {
                // An unavailable source is retried later and cannot invalidate the local catalog.
            } finally { http.cancel() }
        }
    }

    private fun isCurrentCatalog(revision: String) = !YesheIndexService.deleting &&
        app.getDatabasePath("yeshe_index.db").exists() && state("status") == "complete" && state("updated") == revision

    @Synchronized private fun pageDiffers(revision: String, number: Int, remote: YeshePage): Boolean? {
        if (!isCurrentCatalog(revision)) return null
        if (remote.total != state("total", "0").toInt()) return true
        val range = arrayOf(((number - 1) * 30).toString(), (number * 30).toString())
        val cached = readableDatabase.rawQuery("SELECT url,title FROM books WHERE ordinal >= ? AND ordinal < ? ORDER BY ordinal,url", range).use { cursor ->
            buildList { while (cursor.moveToNext()) add(YesheBook(cursor.getString(0), cursor.getString(1))) }
        }
        return remote.books != cached
    }

    @Synchronized private fun finishUpdateCheck(revision: String, changed: Boolean? = null, nextSample: Int = 2, retryAt: Long = 0) {
        if (!isCurrentCatalog(revision)) return
        if (changed == null) {
            val next = maxOf(state("nextUpdateCheck", "0").toLong(), retryAt)
            set("nextUpdateCheck" to next.toString())
            return
        }
        set("updateAvailable" to if (changed) "1" else "0", "nextSamplePage" to nextSample.toString(), "nextUpdateCheck" to (System.currentTimeMillis() + UPDATE_CHECK_INTERVAL).toString())
    }
    @Synchronized fun snapshot(): Map<String, Any> {
        if (!app.getDatabasePath("yeshe_index.db").exists()) {
            return mapOf("count" to 0, "size" to 0L, "status" to "idle", "updated" to 0L)
        }
        val count = readableDatabase.rawQuery("SELECT count(*) FROM books", null).use { it.moveToFirst(); it.getInt(0) }
        val dbFile = app.getDatabasePath("yeshe_index.db")
        val size = listOf(dbFile, File(dbFile.path+"-wal"), File(dbFile.path+"-shm")).sumOf { if (it.exists()) it.length() else 0 }
        val result = mutableMapOf<String, Any>("count" to count, "size" to size)
        for (key in listOf("pages", "total", "elapsed", "bytes", "updated", "sessionPages", "sessionElapsed", "parallelism", "cooldownUntil")) result[key] = state(key, "0").toLong()
        result["status"] = state("status", "idle")
        result["error"] = state("error")
        result["updating"] = state("updating") == "1"
        result["updateAvailable"] = state("updateAvailable") == "1"
        return result
    }
    @Synchronized fun search(query: String, offset: Int): Map<String, Any> {
        if (!app.getDatabasePath("yeshe_index.db").exists()) return mapOf("total" to 0, "books" to emptyList<Any>())
        val words = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.take(12)
        val args = words.map { "%" + YesheCatalog.normalize(it).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%" }.toTypedArray()
        val where = if (words.isEmpty()) "1" else words.joinToString(" AND ") { "normalized LIKE ? ESCAPE '\\'" }
        val db = readableDatabase
        val total = db.rawQuery("SELECT count(*) FROM books WHERE $where", args).use { it.moveToFirst(); it.getInt(0) }
        val rows = db.rawQuery("SELECT url,title FROM books WHERE $where ORDER BY ordinal,url LIMIT 50 OFFSET ${offset.coerceAtLeast(0)}", args).use { c -> buildList { while (c.moveToNext()) add(mapOf("url" to c.getString(0), "title" to c.getString(1))) } }
        return mapOf("total" to total, "books" to rows)
    }
    @Synchronized fun deleteIndex() {
        check(!YesheIndexService.running) { "请等待后台书目任务停止" }
        close()
        val file = app.getDatabasePath("yeshe_index.db")
        if (file.exists()) check(app.deleteDatabase("yeshe_index.db")) { "书目删除失败，请重试" }
    }
}
