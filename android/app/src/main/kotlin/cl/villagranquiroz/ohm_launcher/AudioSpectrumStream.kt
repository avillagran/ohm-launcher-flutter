package cl.villagranquiroz.ohm_launcher

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import kotlin.math.hypot

/**
 * Streams the device output mix spectrum to Flutter.
 *
 * Visualizer session 0 observes the global audio output on Android builds that
 * expose it to launchers. RECORD_AUDIO is required by the platform. When an OEM
 * blocks session 0, the stream stays alive and emits silence so the background
 * keeps animating at its idle pace.
 */
class AudioSpectrumStream(private val context: Context) : EventChannel.StreamHandler {
    private var visualizer: Visualizer? = null
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            events?.success(silence())
            return
        }
        try {
            val v = Visualizer(0)
            val range = Visualizer.getCaptureSizeRange()
            v.captureSize = minOf(1024, range[1]).coerceAtLeast(range[0])
            v.setDataCaptureListener(
                object : Visualizer.OnDataCaptureListener {
                    override fun onWaveFormDataCapture(
                        visualizer: Visualizer?, waveform: ByteArray?, samplingRate: Int,
                    ) = Unit

                    override fun onFftDataCapture(
                        visualizer: Visualizer?, fft: ByteArray?, samplingRate: Int,
                    ) {
                        if (fft == null || fft.size < 4) return
                        val bands = FloatArray(16)
                        val bins = fft.size / 2
                        var total = 0f
                        var peak = 0f
                        for (band in bands.indices) {
                            // Logarithmic-ish bands: retain bass resolution while
                            // spanning the full FFT, matching the desktop renderer's
                            // per-column band mapping.
                            val start = 1 + ((bins - 1) * band * band) /
                                (bands.size * bands.size)
                            val end = maxOf(start + 1, 1 + ((bins - 1) * (band + 1) * (band + 1)) /
                                (bands.size * bands.size))
                            var sum = 0f
                            var count = 0
                            for (bin in start until minOf(end, bins)) {
                                val re = fft[bin * 2].toInt().toFloat()
                                val im = fft[bin * 2 + 1].toInt().toFloat()
                                sum += hypot(re, im) / 181f
                                count++
                            }
                            val energy = if (count == 0) 0f else (sum / count).coerceIn(0f, 1f)
                            bands[band] = energy
                            total += energy
                            peak = maxOf(peak, energy)
                        }
                        val volume = (total / bands.size * 2.4f).coerceIn(0f, 1f)
                        val beat = bands.take(3).average() > 0.42 && peak > 0.55
                        val payload = mapOf(
                            "volume" to volume.toDouble(),
                            "beat" to beat,
                            "bands" to bands.map { it.toDouble() },
                        )
                        main.post { sink?.success(payload) }
                    }
                },
                Visualizer.getMaxCaptureRate() / 2,
                false,
                true,
            )
            v.enabled = true
            visualizer = v
            Log.d("OhmAudioSpectrum", "Visualizer session 0 started (${v.captureSize} FFT bytes)")
        } catch (e: Exception) {
            Log.w("OhmAudioSpectrum", "Output mix capture unavailable: ${e.message}")
            events?.success(silence())
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        try { visualizer?.enabled = false } catch (_: Exception) {}
        try { visualizer?.release() } catch (_: Exception) {}
        visualizer = null
    }

    private fun silence() = mapOf(
        "volume" to 0.0,
        "beat" to false,
        "bands" to List(16) { 0.0 },
    )
}
