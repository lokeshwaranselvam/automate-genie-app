package ai.automategenie.app; // change this to your package


import android.Manifest;
import android.app.Service;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.IBinder;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;

import java.io.File;

public class RecordingService extends Service {

    private static final String TAG = "RecordingService";
    private MediaRecorder recorder;
    private boolean isRecording = false;
    private static final String CHANNEL_ID = "RecordChannel";

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        // Started via startForegroundService: enter the foreground before any
        // stopSelf(), otherwise Android crashes the app for not doing so.
        try {
            startForeground(1, buildNotification());
        } catch (Exception e) {
            // Android 14+ throws for a microphone service without RECORD_AUDIO,
            // and Android 12+ when started from the background.
            Log.e(TAG, "Unable to start recording foreground service", e);
            stopSelf();
            return;
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "RECORD_AUDIO permission not granted; stopping service");
            stopSelf();
            return;
        }

        if (!startRecording()) {
            stopSelf();
        }
    }

    private boolean startRecording() {
        try {
            File dir = getExternalFilesDir(null);
            if (dir == null) dir = getFilesDir();
            recorder = new MediaRecorder();
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC);
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            recorder.setOutputFile(dir.getAbsolutePath() + "/recorded_audio.mp4");
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            recorder.prepare();
            recorder.start();
            isRecording = true;
            return true;
        } catch (Exception e) {
            // IOException from prepare(), RuntimeException/IllegalStateException
            // from setAudioSource()/start() (e.g. mic busy or permission revoked).
            Log.e(TAG, "Unable to start audio recording", e);
            releaseRecorder();
            return false;
        }
    }

    private void releaseRecorder() {
        if (recorder == null) return;
        if (isRecording) {
            try {
                recorder.stop();
            } catch (RuntimeException e) {
                // stop() throws if no valid audio was captured; the file is unusable
                // but the recorder must still be released.
                Log.w(TAG, "MediaRecorder stop failed", e);
            }
        }
        try {
            recorder.release();
        } catch (RuntimeException e) {
            Log.w(TAG, "MediaRecorder release failed", e);
        }
        recorder = null;
        isRecording = false;
    }

    private Notification buildNotification() {
        Notification.Builder builder =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);

        return builder.setContentTitle("Recording")
                      .setContentText("Audio recording in progress")
                      .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                      .build();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel serviceChannel =
                new NotificationChannel(CHANNEL_ID, "Audio Recording Channel",
                    NotificationManager.IMPORTANCE_LOW);
            NotificationManager manager = getSystemService(NotificationManager.class);
            manager.createNotificationChannel(serviceChannel);
        }
    }

    @Override
    public void onDestroy() {
        releaseRecorder();
        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
