package com.enterprise

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException

class CloudStorageDocumentsProvider : DocumentsProvider() {

    private val DEFAULT_ROOT_ID = "cloud_storage_root"

    override fun onCreate(): Boolean {
        // Initialize shared preferences, fetch JWT, load Master Vault
        return true
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val result = MatrixCursor(projection ?: arrayOf(
            DocumentsContract.Root.COLUMN_ROOT_ID,
            DocumentsContract.Root.COLUMN_ICON,
            DocumentsContract.Root.COLUMN_TITLE,
            DocumentsContract.Root.COLUMN_FLAGS,
            DocumentsContract.Root.COLUMN_DOCUMENT_ID
        ))

        result.newRow().apply {
            add(DocumentsContract.Root.COLUMN_ROOT_ID, DEFAULT_ROOT_ID)
            add(DocumentsContract.Root.COLUMN_TITLE, "Enterprise Cloud Storage")
            add(DocumentsContract.Root.COLUMN_FLAGS, DocumentsContract.Root.FLAG_SUPPORTS_CREATE or DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD)
            add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, getDocIdForFile(File("/")))
        }
        return result
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val result = MatrixCursor(projection ?: arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
            DocumentsContract.Document.COLUMN_SIZE
        ))
        
        // Fetch metadata from local Drift DB / Worker API
        return result
    }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val result = MatrixCursor(projection ?: arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME
        ))
        // Query backend worker for children
        return result
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        // 1. Download chunks from R2 presigned URLs
        // 2. Decrypt stream using AES-256-GCM via Master Vault
        // 3. Write into a Pipe and return the read end
        throw FileNotFoundException("Streaming read not implemented yet")
    }

    private fun getDocIdForFile(file: File): String {
        return file.absolutePath
    }
}
