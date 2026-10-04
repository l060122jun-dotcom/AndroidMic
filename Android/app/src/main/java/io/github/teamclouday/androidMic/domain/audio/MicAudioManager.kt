package io.github.teamclouday.androidMic.domain.audio

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.util.Log
import androidx.core.content.ContextCompat
import io.github.teamclouday.androidMic.R
import io.github.teamclouday.androidMic.domain.service.AudioPacket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.nio.ByteOrder


private const val TAG: String = "MicAM"

// manage microphone recording
class MicAudioManager(
    ctx: Context,
    val scope: CoroutineScope,
    val sampleRate: Int,
    val audioFormat: Int,
    val channelCount: Int,
    val audioSource: Int,
) {

    companion object {
        const val RECORD_DELAY_MS = 100L

        // Target size of each captured read block, in milliseconds. Smaller blocks
        // forward audio to the transport sooner (lower end-to-end latency) at the
        // cost of more read calls. 10 ms is a good balance for wired (USB/ADB) links.
        const val READ_CHUNK_MS = 10
    }

    private val recorder: AudioRecord
    private val bufferSize: Int
    private val readChunkBytes: Int
    private val buffer: ByteArray
    private val bufferFloat: FloatArray
    private val bufferFloatConvert: ByteBuffer
    private var streamJob: Job? = null

    private var isMuted = false

    init {
        // check microphone
        require(ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_MICROPHONE)) {
            ctx.getString(R.string.error_mic_not_detected)
        }
        require(
            ContextCompat.checkSelfPermission(
                ctx,
                Manifest.permission.RECORD_AUDIO
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            ctx.getString(R.string.error_mic_not_permitted)
        }

        // get minimum buffer size
        val channelConfig =
            if (channelCount == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
        val minBufferSize = AudioRecord.getMinBufferSize(
            sampleRate,
            channelConfig,
            audioFormat,
        )

        require(minBufferSize != AudioRecord.ERROR && minBufferSize != AudioRecord.ERROR_BAD_VALUE) {
            ctx.getString(R.string.error_mic_buffer_invalid, minBufferSize)
        }

        // Low-latency tuning:
        // - keep the AudioRecord internal buffer at least the platform minimum, but
        //   grow it to ~2 read chunks so a single read never starves the hardware.
        // - read in ~10 ms chunks so we forward audio to the transport with minimal
        //   batching latency, independent of the (possibly much larger) internal buffer.
        val bytesPerSample = when (audioFormat) {
            AudioFormat.ENCODING_PCM_8BIT -> 1
            AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_32BIT -> 4
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
            else -> 2 // 16-bit default
        }
        val bytesPerFrame = bytesPerSample * channelCount
        val targetReadBytes = sampleRate * bytesPerFrame * READ_CHUNK_MS / 1000
        readChunkBytes = maxOf(targetReadBytes, bytesPerFrame)
        // Do not aggressively shrink the hardware buffer below the platform minimum,
        // but cap it so it cannot add large batching latency.
        bufferSize = maxOf(minBufferSize, readChunkBytes * 2)

        // init recorder
        recorder = AudioRecord(
            audioSource,
            sampleRate,
            channelConfig,
            audioFormat,
            bufferSize,
        )

        // check if recorder is initialized
        require(recorder.state == AudioRecord.STATE_INITIALIZED) {
            ctx.getString(R.string.error_mic_init_failed)
        }

        buffer = ByteArray(readChunkBytes)
        bufferFloat = FloatArray(readChunkBytes / 4) // float is 4 bytes
        bufferFloatConvert = ByteBuffer.allocate(readChunkBytes).order(ByteOrder.nativeOrder())
    }

    // audio stream publisher
    fun audioStream(): Flow<AudioPacket> = channelFlow {
        // Low-latency capture path (best-effort): ask the platform to use the
        // low-latency fast path. A smaller read chunk only helps if the HAL
        // keeps up, so this is treated as a hint and never shrinks below the
        // platform minimum buffer computed in init.
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                recorder.setPerformanceMode(android.media.AudioRecord.PERFORMANCE_MODE_LOW_LATENCY)
            }
        } catch (_: Throwable) {
            // Not all devices support performance mode; ignore and use defaults.
        }

        // launch in scope so infinite loop will be canceled when scope exits
        streamJob = scope.launch {
            while (true) {

                if (isMuted) {
                    delay(RECORD_DELAY_MS)
                    continue
                }

                if (recorder.state != AudioRecord.STATE_INITIALIZED || recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                    delay(RECORD_DELAY_MS)
                    continue
                }

                val readCount: Int // number of samples read (for float) or number of bytes read (for int)
                val packetBuffer: ByteArray

                if (audioFormat == AudioFormat.ENCODING_PCM_FLOAT) {
                    readCount =
                        recorder.read(bufferFloat, 0, bufferFloat.size, AudioRecord.READ_BLOCKING)

                    if (readCount > 0) {
                        // emit exactly the valid float samples (4 bytes each), no stale tail
                        val validBytes = readCount * 4
                        bufferFloatConvert.clear()
                        bufferFloatConvert.asFloatBuffer().put(bufferFloat, 0, readCount)
                        packetBuffer = bufferFloatConvert.array().copyOf(validBytes)
                    } else {
                        packetBuffer = ByteArray(0)
                    }
                } else {
                    readCount = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)

                    if (readCount > 0) {
                        packetBuffer = ByteArray(readCount)
                        buffer.copyInto(packetBuffer, 0, 0, readCount)
                    } else {
                        packetBuffer = ByteArray(0)
                    }
                }

                if (readCount <= 0) {
                    delay(RECORD_DELAY_MS)
                    continue
                }

                send(
                    AudioPacket(
                        buffer = packetBuffer,
                        sampleRate = sampleRate,
                        audioFormat = audioFormat,
                        channelCount = channelCount
                    )
                )
            }
        }

        awaitClose {
            streamJob?.cancel()
        }
    }

    fun mute() {
        isMuted = true
    }

    fun unmute() {
        isMuted = false
    }

    // start recording
    fun start() {
        recorder.startRecording()
        Log.d(TAG, "start")
    }

    // stop recording
    fun stop() {
        recorder.stop()
        Log.d(TAG, "stop")
    }

    // shutdown manager
    // should not call any methods after calling
    fun shutdown() {
        recorder.stop()
        recorder.release()
        streamJob?.cancel()
        Log.d(TAG, "shutdown")
    }
}