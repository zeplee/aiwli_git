package com.aiwli.git

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/// Foreground service that keeps the process alive while the MCP server runs,
/// so AI tools can connect even when the app is backgrounded or the screen is
/// locked (otherwise MIUI freezes idle apps and the Dart event loop stops).
class McpService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.getBooleanExtra("stop", false) == true) {
            try {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } catch (_: Exception) {}
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            startForeground(1, buildNotification())
        } catch (e: Exception) {
            // FGS promotion failed (e.g. type rejected) — degrade to a plain
            // service instead of crashing the app with
            // ForegroundServiceDidNotStartInTimeException.
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                "gitdeck_mcp",
                "MCP 服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "AiwliGit MCP 服务运行中" }
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(ch)
        }
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, "gitdeck_mcp")
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return b.setContentTitle("AiwliGit MCP 服务")
            .setContentText("AI 工具可通过 MCP 调用 Git 能力")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .build()
    }
}
