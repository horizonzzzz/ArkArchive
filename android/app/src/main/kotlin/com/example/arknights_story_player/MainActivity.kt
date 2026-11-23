package com.example.arknights_story_player

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var installChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app_update/install",
        ).also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "installApk") {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("invalid_arguments", "缺少安装包路径", null)
                    } else {
                        try {
                            installApk(File(path))
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("install_failed", error.message, null)
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
        }
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "story_export/share",
        ).also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "shareZip") {
                    val path = call.argument<String>("path")
                    val displayName = call.argument<String>("displayName")
                    if (path.isNullOrEmpty()) {
                        result.error("invalid_arguments", "缺少导出文件路径", null)
                    } else {
                        try {
                            shareZip(File(path), displayName ?: "素材.zip")
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("share_failed", error.message, null)
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onDestroy() {
        installChannel?.setMethodCallHandler(null)
        installChannel = null
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        super.onDestroy()
    }

    // 通过系统安装器安装下载完成的 APK；首次需要「未知来源」授权，
    // 由系统弹窗引导，授权失败时界面保留手动「安装」按钮兜底。
    private fun installApk(file: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    // 素材导出的 zip 交给系统分享面板，由用户保存到文件、网盘或发给其他应用；
    // zip 位于应用缓存目录，FileProvider 需暴露 cache-path。
    private fun shareZip(file: File, displayName: String) {
        if (!file.exists()) {
            throw IllegalArgumentException("导出文件不存在")
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "application/zip"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, displayName))
    }
}
