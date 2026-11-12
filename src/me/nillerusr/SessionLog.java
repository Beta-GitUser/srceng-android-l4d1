package me.nillerusr;

import java.io.File;
import java.io.IOException;
import java.util.Arrays;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.util.Log;

/**
 * Tee logcat into a file the user can open with any file manager.
 *
 * The engine already logs. tier0/dbg.cpp sends every Msg()/Warning() to
 * __android_log_print under the tag "SRCENG", and the launcher uses "SRCAPK".
 * That output goes to logcat, which is the one place this project cannot read:
 * the phone has no adb. So there is nothing to build here -- run logcat and
 * point it at a file.
 *
 * A crash survives: logd keeps its buffer across process death, so the next
 * launch dumps whatever the previous run left behind -- including the fatal
 * signal -- into session.prev.log before clearing it.
 *
 * Nothing here needs a storage permission beyond what the launcher already
 * asks for, and if the shared directory turns out not to be writable the log
 * falls back to the app's own external files directory, which never needs one.
 */
public class SessionLog {
	private static final String TAG = "SRCAPK";
	private static final String LIVE = "session.log";
	private static final String PREVIOUS = "session.prev.log";

	// Keep the log from eating the device if someone leaves the app running.
	private static final int ROTATE_KB = 8192;
	private static final int ROTATE_COUNT = 3;

	/**
	 * Where the log should go, best effort. The game directory is preferred
	 * because it is readable by every file manager; app-private storage is the
	 * fallback, at the cost of being awkward to reach on Android 11+.
	 */
	public static File directory(Context ctx) {
		SharedPreferences prefs = ctx.getSharedPreferences("mod", 0);
		String gamepath = prefs.getString("gamepath",
			LauncherActivity.getDefaultDir() + "/srceng");
		String gamedir = prefs.getString("gamedir", LauncherActivity.DEFAULT_GAMEDIR);

		File[] candidates = {
			new File(gamepath, gamedir),      // /storage/emulated/0/srceng/left4dead
			new File(gamepath),               // /storage/emulated/0/srceng
			ctx.getExternalFilesDir(null),    // app-private, no permission needed
			ctx.getFilesDir(),
		};

		for (File dir : candidates) {
			if (dir == null) {
				continue;
			}
			if (!dir.exists() && !dir.mkdirs()) {
				continue;
			}
			if (dir.isDirectory() && dir.canWrite()) {
				return dir;
			}
		}
		return null;
	}

	/** Start capturing. Call as early as possible; returns the live log file. */
	public static File start(Context ctx) {
		File dir = directory(ctx);
		if (dir == null) {
			Log.w(TAG, "SessionLog: no writable directory for the session log");
			return null;
		}

		File live = new File(dir, LIVE);
		File previous = new File(dir, PREVIOUS);

		// Whatever the last run left in logd, before we throw it away. This is
		// where a crash is found, because the log file of a run that died is
		// otherwise the file of a run that never got to say anything.
		if (previous.exists()) {
			previous.delete();
		}
		exec("logcat", "-d", "-v", "time", "-f", previous.getAbsolutePath());
		exec("logcat", "-c");

		try {
			ProcessBuilder pb = new ProcessBuilder(
				"logcat", "-v", "time",
				"-f", live.getAbsolutePath(),
				"-r", String.valueOf(ROTATE_KB),
				"-n", String.valueOf(ROTATE_COUNT));
			pb.redirectErrorStream(true);
			pb.start();
		} catch (IOException e) {
			Log.w(TAG, "SessionLog: could not start logcat: " + e.getMessage());
			return null;
		}

		header(ctx, live);
		return live;
	}

	/**
	 * Identify the run inside its own log, so a report pasted back says what
	 * it was running rather than just what went wrong.
	 */
	private static void header(Context ctx, File live) {
		SharedPreferences prefs = ctx.getSharedPreferences("mod", 0);
		Log.i(TAG, "--- session start ---");
		Log.i(TAG, "device: " + Build.MANUFACTURER + " " + Build.MODEL
			+ " (" + Build.DEVICE + "), " + Build.VERSION.RELEASE
			+ " (sdk " + Build.VERSION.SDK_INT + ")");
		// Build.SUPPORTED_ABIS is API 21 and minSdk here is 17; it is an array
		// field, so it is fetched at runtime rather than inlined by the
		// compiler, and touching it below 21 would throw.
		if (Build.VERSION.SDK_INT >= 21) {
			Log.i(TAG, "abis: " + Arrays.toString(Build.SUPPORTED_ABIS));
		} else {
			Log.i(TAG, "abi: " + Build.CPU_ABI + " " + Build.CPU_ABI2);
		}
		Log.i(TAG, "engine commit: "
			+ ctx.getResources().getString(com.valvesoftware.source.R.string.last_commit));
		Log.i(TAG, "gamepath: " + prefs.getString("gamepath",
			LauncherActivity.getDefaultDir() + "/srceng"));
		Log.i(TAG, "gamedir: " + prefs.getString("gamedir", LauncherActivity.DEFAULT_GAMEDIR));
		Log.i(TAG, "argv: " + prefs.getString("argv", "-console"));
		Log.i(TAG, "log: " + live.getAbsolutePath());
	}

	private static void exec(String... argv) {
		try {
			Process p = Runtime.getRuntime().exec(argv);
			p.getInputStream().close();
			p.getErrorStream().close();
			p.waitFor();
		} catch (Exception e) {
			Log.w(TAG, "SessionLog: " + argv[0] + " failed: " + e.getMessage());
		}
	}
}
