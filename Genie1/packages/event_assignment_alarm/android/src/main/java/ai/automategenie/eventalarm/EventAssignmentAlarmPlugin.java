package ai.automategenie.eventalarm;

import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** A plugin, rather than an Activity channel, also works in Firebase's engine. */
public final class EventAssignmentAlarmPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private Context context;
    private MethodChannel channel;

    @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "ai.automategenie/event_assignment_alarm");
        channel.setMethodCallHandler(this);
    }

    @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
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
        try {
            NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
            if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) {
                result.success(false);
                return;
            }
            Intent intent = new Intent(context, EventAlarmService.class);
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent);
            else context.startService(intent);
            result.success(true);
        } catch (RuntimeException error) {
            // For example, Android may downgrade an FCM push and reject a background start.
            Log.w("EventAssignmentAlarm", "Cannot start alarm: " + error.getClass().getSimpleName());
            result.success(false);
        }
    }
}
