package fr.maisonzen.android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.Data
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.time.Duration
import java.time.Instant
import java.time.temporal.ChronoUnit

class MaisonNotificationWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val id = inputData.getString("recordId") ?: return Result.failure()
        val title = inputData.getString("title") ?: "Maison Zen"
        val detail = inputData.getString("detail") ?: "Rappel Maison Zen"
        val channel = "maisonzen-reminders"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = applicationContext.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(channel, "Rappels Maison Zen", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val notification = NotificationCompat.Builder(applicationContext, channel)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(detail)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setSilent(inputData.getBoolean("silent", false))
            .build()
        runCatching { NotificationManagerCompat.from(applicationContext).notify(id.hashCode(), notification) }
        scheduleNextIfRepeating(id)
        return Result.success()
    }

    private fun scheduleNextIfRepeating(id: String) {
        val recurrence = inputData.getString("recurrence") ?: return
        val amount = when (recurrence) {
            "Chaque jour" -> 1L to ChronoUnit.DAYS
            "Chaque semaine" -> 1L to ChronoUnit.WEEKS
            "Chaque mois" -> 1L to ChronoUnit.MONTHS
            "Chaque année" -> 1L to ChronoUnit.YEARS
            else -> return
        }
        val next = Instant.now().plus(amount.first, amount.second)
        val data = Data.Builder().putString("recordId", id)
            .putString("title", inputData.getString("title"))
            .putString("detail", inputData.getString("detail"))
            .putString("recurrence", recurrence)
            .putBoolean("silent", inputData.getBoolean("silent", false)).build()
        val delay = Duration.between(Instant.now(), next).toMillis().coerceAtLeast(1)
        val request = OneTimeWorkRequestBuilder<MaisonNotificationWorker>().setInputData(data)
            .setInitialDelay(delay, java.util.concurrent.TimeUnit.MILLISECONDS).build()
        WorkManager.getInstance(applicationContext).enqueueUniqueWork("maisonzen-$id", androidx.work.ExistingWorkPolicy.REPLACE, request)
    }
}
