package ai.automategenie.eventalarm;

import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.ResultReceiver;
import android.os.SystemClock;
import android.util.Log;
import java.util.HashSet;
import java.util.Set;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** A plugin, rather than an Activity channel, also works in Firebase's engine. */
public final class EventAssignmentAlarmPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private Context context;
    private MethodChannel channel;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Set<PlaybackRequest> pending = new HashSet<>();

    private final class PlaybackRequest extends ResultReceiver {
        private MethodChannel.Result result;
        private final Runnable timeout = () -> {
            Log.w("EventAssignmentAlarm", "Alarm playback confirmation timed out");
            complete(false);
        };

        PlaybackRequest(MethodChannel.Result result) {
            super(handler);
            this.result = result;
        }

        @Override protected void onReceiveResult(int resultCode, Bundle data) {
            complete(resultCode == EventAlarmService.PLAYBACK_STARTED);
        }

        void complete(boolean started) {
            if (result == null) return;
            handler.removeCallbacks(timeout);
            pending.remove(this);
            MethodChannel.Result reply = result;
            result = null;
            reply.success(started);
        }
    }

    @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "ai.automategenie/event_assignment_alarm");
        channel.setMethodCallHandler(this);
    }

    @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
        for (PlaybackRequest request : new HashSet<>(pending)) request.complete(false);
        channel.setMethodCallHandler(null);
        channel = null;
        context = null;
        // Playback belongs to the service; background engine teardown must not stop it.
    }

    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (!"play".equals(call.method)) {
            result.notImplemented();
            return;
        }
        PlaybackRequest request = null;
        try {
            NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
            if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) {
                result.success(false);
                return;
            }
            request = new PlaybackRequest(result);
            pending.add(request);
            // The service bounds preparation to ten seconds. Leave time for its
            // failure callback, but never leave the Dart background handler hung.
            handler.postDelayed(request.timeout, 12000);
            Intent intent = new Intent(context, EventAlarmService.class);
            intent.putExtra(EventAlarmService.EXTRA_RESULT_RECEIVER, request);
            intent.putExtra(EventAlarmService.EXTRA_PLAYBACK_DEADLINE,
                    SystemClock.elapsedRealtime() + 10000);
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent);
            else context.startService(intent);
            // Only EventAlarmService can confirm that MediaPlayer started.
        } catch (RuntimeException error) {
            // For example, Android may downgrade an FCM push and reject a background start.
            Log.w("EventAssignmentAlarm", "Cannot start alarm: " + error.getClass().getSimpleName());
            if (request != null) request.complete(false);
            else result.success(false);
        }
    }
}
