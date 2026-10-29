package com.sorryread.sorryread_mobile

import org.junit.Test
import org.junit.Assert.*
import java.net.HttpURLConnection
import java.net.URL
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream

class YesheHttpTransportTest {
    private val html=("<div class='listwap'>"+(1..30).joinToString("") {"<a class='info' href='/artdetail-$it.html' title='山间来信 $it'></a>"}+"</div><div class='page_tip'>共 30 条</div>").toByteArray()
    private class Response(private val code:Int,private val bytes:ByteArray,private val gzip:Boolean=false):HttpURLConnection(URL(YesheCatalog.FIRST)) {
        var closed=false
        override fun connect() {}
        override fun disconnect() {closed=true}
        override fun usingProxy()=false
        override fun getResponseCode()=code
        override fun getHeaderField(name:String?)=if(name=="Retry-After") "0" else null
        override fun getContentEncoding()=if(gzip) "gzip" else null
        override fun getInputStream()=bytes.inputStream()
    }
    @Test fun compressedResponsePreservesWireSizeAndParsesAllNames() {
        val bytes=ByteArrayOutputStream().also {out->GZIPOutputStream(out).use {it.write(html)}}.toByteArray()
        val response=Response(200,bytes,true)
        val transport=YesheHttpTransport(connect={response})
        try {
            val page=transport.fetch(YesheCatalog.FIRST)
            assertEquals(30,page.page.books.size)
            assertEquals(bytes.size,page.bytes)
            assertTrue(response.closed)
        } finally {transport.cancel()}
    }
    @Test fun forbiddenResponseIsNotRetried() {
        var calls=0
        val transport=YesheHttpTransport(connect={calls++;Response(403,byteArrayOf())})
        try {
            val error=assertThrows(YesheHttpException::class.java) {transport.fetch(YesheCatalog.FIRST)}
            assertEquals(403,error.code); assertEquals(1,calls)
        } finally {transport.cancel()}
    }
    @Test fun rateLimitReducesConcurrencyAndWaitsBeforeRetry() {
        val starts=mutableListOf<Long>(); val cooldowns=mutableListOf<Long>()
        val transport=YesheHttpTransport(onThrottle={cooldowns.add(it)},connect={
            starts.add(System.nanoTime()/1_000_000)
            Response(if(starts.size==1) 429 else 200,html)
        })
        try {
            assertEquals(30,transport.fetch(YesheCatalog.FIRST).page.books.size)
            assertEquals(2,starts.size); assertEquals(1,transport.parallelism)
            assertTrue(starts[1]-starts[0]>=1900); assertEquals(1,cooldowns.size)
        } finally {transport.cancel()}
    }
    @Test fun transientServerErrorRetriesInsteadOfStoppingAtFirst500() {
        var calls=0
        val transport=YesheHttpTransport(connect={Response(if(++calls==1) 500 else 200,html)})
        try {
            assertEquals(30,transport.fetch(YesheCatalog.FIRST).page.books.size)
            assertEquals(2,calls)
            assertEquals(1,transport.parallelism)
        } finally {transport.cancel()}
    }
}
