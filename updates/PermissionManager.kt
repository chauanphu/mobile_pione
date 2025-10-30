package com.chenyeju

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.PermissionChecker

/**
 * Manages camera permissions
 */
class PermissionManager {
    companion object {
        private const val PERMISSION_REQUEST_CODE = 1230
        private val isScopedStorage = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        
        /**
         * Check if camera and storage permissions are granted
         */
        fun hasRequiredPermissions(context: Context): Boolean {
            val hasCameraPermission = PermissionChecker.checkSelfPermission(
                context,
                Manifest.permission.CAMERA
            )
            // On Android 10+ (Q), WRITE_EXTERNAL_STORAGE is deprecated/ignored.
            // Only require legacy storage permission on pre-Q devices.
            if (isScopedStorage) {
                return hasCameraPermission == PermissionChecker.PERMISSION_GRANTED
            }
            val hasStoragePermission = PermissionChecker.checkSelfPermission(
                context,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            )
            return hasCameraPermission == PermissionChecker.PERMISSION_GRANTED &&
                    hasStoragePermission == PermissionChecker.PERMISSION_GRANTED
        }
        
        /**
         * Request camera and storage permissions
         * @return true if permissions already granted, false if request was made
         */
        fun requestPermissionsIfNeeded(activity: Activity?): Boolean {
            if (activity == null) {
                return false
            }
            
            if (hasRequiredPermissions(activity)) {
                return true
            }
            
            // Build permission list dynamically based on SDK level
            val permissions = mutableListOf(Manifest.permission.CAMERA)
            if (!isScopedStorage) {
                permissions.add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            }
            ActivityCompat.requestPermissions(
                activity,
                permissions.toTypedArray(),
                PERMISSION_REQUEST_CODE
            )
            return false
        }
        
        /**
         * Check if permission result is successful
         */
        fun isPermissionGranted(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
            if (requestCode != PERMISSION_REQUEST_CODE) {
                return false
            }

            if (grantResults.isEmpty()) return false

            // On Android 10+ (Q), WRITE_EXTERNAL_STORAGE is not a runtime permission
            // Treat denials for it as non-fatal by only requiring CAMERA to be granted
            if (isScopedStorage) {
                // Find CAMERA result; default to denied if not present
                var cameraGranted = false
                for (i in permissions.indices) {
                    if (permissions[i] == Manifest.permission.CAMERA) {
                        cameraGranted = grantResults[i] == PackageManager.PERMISSION_GRANTED
                        break
                    }
                }
                return cameraGranted
            }

            return grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        }
        
        /**
         * Get permission request code
         */
        fun getPermissionRequestCode() = PERMISSION_REQUEST_CODE
    }
} 