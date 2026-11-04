package ai.automategenie.eventalarm;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.content.res.AssetFileDescriptor;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.os.ResultReceiver;
import android.os.SystemClock;
import android.util.Log;

/** Five-second alarm-stream playback, independent of notification/ringer volume. */
public final class EventAlarmService extends Service {
    static final String EXTRA_RESULT_RECEIVER = "ai.automategenie.eventalarm.PLAYBACK_RESULT";
    static final String EXTRA_PLAYBACK_DEADLINE = "ai.automategenie.eventalarm.PLAYBACK_DEADLINE";
    static final int PLAYBACK_STARTED = 1;
    private static final String CHANNEL = "event_assignment_playback_v1";
    private static final String STOP = "ai.automategenie.eventalarm.STOP";
    private static final int NOTIFICATION_ID = 174039;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable finish = this::stopPlayback;
    private ResultReceiver playbackResult;
    private long playbackDeadline;
    private MediaPlayer player;
    private AudioManager audio;
    private AudioFocusRequest focus;
    private boolean legacyFocusHeld;
    private final AudioManager.OnAudioFocusChangeListener focusListener = change -> {
        if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) stopPlayback();
    };

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || STOP.equals(intent.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        releasePlayback();
        playbackResult = Build.VERSION.SDK_INT >= 33
                ? intent.getParcelableExtra(EXTRA_RESULT_RECEIVER, ResultReceiver.class)
                : intent.getParcelableExtra(EXTRA_RESULT_RECEIVER);
        playbackDeadline = intent.getLongExtra(EXTRA_PLAYBACK_DEADLINE,
                SystemClock.elapsedRealtime() + 10000);
        try {
            if (SystemClock.elapsedRealtime() >= playbackDeadline) {
                stopPlayback();
                return START_NOT_STICKY;
            }
            NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            if (Build.VERSION.SDK_INT >= 26) {
                NotificationChannel channel = new NotificationChannel(CHANNEL, "Event alarm playback", NotificationManager.IMPORTANCE_LOW);
                channel.setDescription("Shown briefly while a visit assignment alarm is ringing");
                channel.setSound(null, null);
                channel.enableVibration(false);
                manager.createNotificationChannel(channel);
            }
            Intent stopIntent = new Intent(this, EventAlarmService.class).setAction(STOP);
            PendingIntent stop = PendingIntent.getService(this, 0, stopIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            int icon = getResources().getIdentifier("ic_notification", "drawable", getPackageName());
            if (icon == 0) icon = android.R.drawable.ic_lock_idle_alarm;
            Notification.Builder builder = Build.VERSION.SDK_INT >= 26
                    ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
            builder.setSmallIcon(icon).setContentTitle("Visit assignment alarm")
                    .setContentText("A new visit has been assigned to you")
                    .setCategory(Notification.CATEGORY_ALARM).setVisibility(Notification.VISIBILITY_PRIVATE)
                    .setOngoing(true).setOnlyAlertOnce(true)
                    .addAction(new Notification.Action.Builder(null, "Stop", stop).build());
            Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
            if (launch != null) builder.setContentIntent(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, builder.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            else startForeground(NOTIFICATION_ID, builder.build());

            audio = (AudioManager) getSystemService(AUDIO_SERVICE);
            // Respect the user's alarm volume and DND configuration. Never change
            // ring mode, global volume, DND policy, or route all audio to speaker.
            AudioAttributes attributes = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build();
            int granted;
            if (Build.VERSION.SDK_INT >= 26) {
                focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                        .setAudioAttributes(attributes).setAcceptsDelayedFocusGain(false)
                        .setOnAudioFocusChangeListener(focusListener, handler).build();
                granted = audio.requestAudioFocus(focus);
            } else {
                granted = audio.requestAudioFocus(focusListener, AudioManager.STREAM_ALARM, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT);
                legacyFocusHeld = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
            }
            if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                Log.w("EventAssignmentAlarm", "Alarm audio focus was denied");
                stopPlayback();
                return START_NOT_STICKY;
            }
            int sound = getResources().getIdentifier("work_assigned", "raw", getPackageName());
            if (sound == 0) throw new IllegalStateException("Bundled alarm sound missing");
            MediaPlayer next = new MediaPlayer();
            player = next;
            next.setAudioAttributes(attributes);
            next.setWakeMode(getApplicationContext(), PowerManager.PARTIAL_WAKE_LOCK);
            next.setLooping(true);
            next.setVolume(1f, 1f);
            try (AssetFileDescriptor file = getResources().openRawResourceFd(sound)) {
                next.setDataSource(file.getFileDescriptor(), file.getStartOffset(), file.getLength());
            }
            next.setOnPreparedListener(prepared -> {
                if (player != prepared) return;
                if (SystemClock.elapsedRealtime() >= playbackDeadline) {
                    stopPlayback();
                    return;
                }
                try {
                    prepared.start();
                    handler.removeCallbacks(finish);
                    handler.postDelayed(finish, 5000);
                    Log.i("EventAssignmentAlarm", "Event alarm started on alarm stream");
                    reportPlayback(true);
                } catch (RuntimeException error) {
                    Log.w("EventAssignmentAlarm", "Alarm could not start playback");
                    stopPlayback();
                }
            });
            next.setOnErrorListener((failed, what, extra) -> {
                if (player != failed) return true;
                Log.w("EventAssignmentAlarm", "Alarm playback error: " + what);
                stopPlayback();
                return true;
            });
            handler.postDelayed(finish, Math.max(0,
                    playbackDeadline - SystemClock.elapsedRealtime()));
            next.prepareAsync();
        } catch (Exception error) {
            Log.w("EventAssignmentAlarm", "Alarm failed: " + error.getClass().getSimpleName());
            stopPlayback();
        }
        return START_NOT_STICKY;
    }

    private void reportPlayback(boolean started) {
        ResultReceiver receiver = playbackResult;
        playbackResult = null;
        if (receiver != null) receiver.send(started ? PLAYBACK_STARTED : 0, null);
    }

    private void stopPlayback() {
        releasePlayback();
        stopSelf();
    }

    private void releasePlayback() {
        handler.removeCallbacks(finish);
        if (player != null) {
            player.setOnPreparedListener(null);
            player.setOnErrorListener(null);
            player.release();
            player = null;
        }
        if (audio != null) {
            if (Build.VERSION.SDK_INT >= 26 && focus != null) audio.abandonAudioFocusRequest(focus);
            else if (legacyFocusHeld) audio.abandonAudioFocus(focusListener);
        }
        focus = null;
        legacyFocusHeld = false;
        // Once start was confirmed, the receiver is already cleared. Otherwise
        // report failure only after releasing audio so the fallback can play.
        reportPlayback(false);
    }

    @Override public void onDestroy() {
        releasePlayback();
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE);
        else stopForeground(true);
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
