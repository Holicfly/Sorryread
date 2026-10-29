package com.sorryread.sorryread_mobile

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File

/** Separate local catalog. Does not access the reader's sync database. */
class YesheIndexStore private constructor(private val app: Context) : SQLiteOpenHelper(app, "yeshe_index.db", null, 1) {
    companion object {
        @Volatile private var instance: YesheIndexStore? = null
        fun get(context: Context): YesheIndexStore = instance ?: synchronized(this) {
            instance ?: YesheIndexStore(context.applicationContext).also { instance = it; it.setWriteAheadLoggingEnabled(true) }
        }
    }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE books(url TEXT PRIMARY KEY, title TEXT NOT NULL, normalized TEXT NOT NULL, ordinal INTEGER NOT NULL)")
        db.execSQL("CREATE INDEX books_order ON books(ordinal,url)")
        db.execSQL("CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}
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
        require(expectedPage == null || expectedPage == pageNumber + 1) { "书目断点不连续，已停止写入" }
        db.beginTransaction()
        try {
            db.compileStatement("INSERT OR REPLACE INTO books(url,title,normalized,ordinal) VALUES(?,?,?,?)").use { insert ->
                page.books.forEachIndexed { i, b ->
                    insert.clearBindings()
                    insert.bindString(1,b.url); insert.bindString(2,b.title); insert.bindString(3,YesheCatalog.normalize(b.title)); insert.bindLong(4,(pageNumber * 30 + i).toLong())
                    insert.executeInsert()
                }
            }
            put(db, "next" to (page.next ?: ""), "pages" to (pageNumber + 1).toString(), "total" to page.total.toString(), "elapsed" to (state("elapsed","0").toLong() + elapsed).toString(), "bytes" to (state("bytes","0").toLong() + bytes).toString(), "status" to (if (page.next == null) "complete" else "running"), "updated" to System.currentTimeMillis().toString(), "error" to "", "sessionPages" to sessionPages.toString(), "sessionElapsed" to sessionElapsed.toString(), "parallelism" to parallelism.toString())
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }
    @Synchronized fun refresh() { set("next" to YesheCatalog.FIRST, "pages" to "0", "elapsed" to "0", "bytes" to "0", "sessionPages" to "0", "sessionElapsed" to "0", "status" to "paused", "error" to "") }
    @Synchronized fun snapshot(): Map<String, Any> {
        val count = readableDatabase.rawQuery("SELECT count(*) FROM books", null).use { it.moveToFirst(); it.getInt(0) }
        val dbFile = app.getDatabasePath("yeshe_index.db")
        val size = listOf(dbFile, File(dbFile.path+"-wal"), File(dbFile.path+"-shm")).sumOf { if (it.exists()) it.length() else 0 }
        val result = mutableMapOf<String, Any>("count" to count, "size" to size)
        for (key in listOf("pages", "total", "elapsed", "bytes", "updated", "sessionPages", "sessionElapsed", "parallelism", "cooldownUntil")) result[key] = state(key, "0").toLong()
        result["status"] = state("status", "idle")
        result["error"] = state("error")
        return result
    }
    @Synchronized fun search(query: String, offset: Int): Map<String, Any> {
        val words = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.take(12)
        val args = words.map { "%" + YesheCatalog.normalize(it).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%" }.toTypedArray()
        val where = if (words.isEmpty()) "1" else words.joinToString(" AND ") { "normalized LIKE ? ESCAPE '\\'" }
        val db = readableDatabase
        val total = db.rawQuery("SELECT count(*) FROM books WHERE $where", args).use { it.moveToFirst(); it.getInt(0) }
        val rows = db.rawQuery("SELECT url,title FROM books WHERE $where ORDER BY ordinal,url LIMIT 50 OFFSET ${offset.coerceAtLeast(0)}", args).use { c -> buildList { while (c.moveToNext()) add(mapOf("url" to c.getString(0), "title" to c.getString(1))) } }
        return mapOf("total" to total, "books" to rows)
    }
}
