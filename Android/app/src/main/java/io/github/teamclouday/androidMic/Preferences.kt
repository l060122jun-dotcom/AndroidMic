package io.github.teamclouday.androidMic

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import io.github.teamclouday.androidMic.ChannelCount.Mono
import io.github.teamclouday.androidMic.ui.utils.UiHelper
import io.github.teamclouday.androidMic.utils.PreferencesManager

object DefaultStates {
    const val IP = "192.168."
    const val PORT = "54345"
}

/**
 * Rules: key should be upper case snake case
 * Ex: SAMPLE_RATE
 * The key should match the name in the app state
 */
class AppPreferences(
    context: Context
) : PreferencesManager(context, "settings") {
    // Prefer the wired USB path by default: it is the lowest-latency transport
    // (no Wi-Fi jitter / no Nagle). Users can switch back to WIFI/UDP/ADB anytime.
    val mode = enumPreference("mode", Mode.USB)

    val ip = stringPreference("ip", "192.168.")
    val port = stringPreference("port", "")


    val theme = enumPreference("theme", Themes.System)
    val dynamicColor = booleanPreference("dynamicColor", true)

    val sampleRate = enumPreference("sampleRate", SampleRates.S44100)
    val channelCount = enumPreference("channelCount", Mono)
    val audioFormat = enumPreference("audioFormat", AudioFormat.I16)
    val audioSource = enumPreference("audioSource", AudioSource.Mic)

}

enum class AudioSource {
    Mic,
    Recognition,
    Communication,
    Performance;

    fun getSource(): Int {

        return when (this) {
            Mic -> MediaRecorder.AudioSource.MIC
            Recognition -> MediaRecorder.AudioSource.VOICE_RECOGNITION
            Communication -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
            Performance -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaRecorder.AudioSource.VOICE_PERFORMANCE
            } else {
                MediaRecorder.AudioSource.MIC
            }
        }
    }

    @Composable
    fun getString(): String {
        return when (this) {
            Mic -> stringResource(R.string.audio_source_mic)
            Recognition -> stringResource(R.string.audio_source_recognition)
            Communication -> stringResource(R.string.audio_source_communication)
            Performance -> stringResource(R.string.audio_source_performance)
        }
    }

    fun getString(uiHelper: UiHelper): String {
        return when (this) {
            Mic -> uiHelper.getString(R.string.audio_source_mic)
            Recognition -> uiHelper.getString(R.string.audio_source_recognition)
            Communication -> uiHelper.getString(R.string.audio_source_communication)
            Performance -> uiHelper.getString(R.string.audio_source_performance)
        }
    }
}

enum class Mode {
    WIFI, UDP, USB, ADB;

    @Composable
    fun getString(): String {
        return when (this) {
            WIFI -> stringResource(R.string.mode_wifi)
            UDP -> stringResource(R.string.mode_udp)
            USB -> stringResource(R.string.mode_usb)
            ADB -> stringResource(R.string.mode_adb)
        }
    }
}

enum class Themes {
    System,
    Dark,
    Light;

    @Composable
    fun getString(): String {
        return when (this) {
            System -> stringResource(R.string.theme_system)
            Dark -> stringResource(R.string.theme_dark)
            Light -> stringResource(R.string.theme_light)
        }
    }
}

enum class Dialogs {
    IpPort,
    Port,
}

// well, this can go crazy: https://github.com/audiojs/sample-rate
enum class SampleRates(val value: Int) {
    S8000(8000),
    S11025(11025),
    S16000(16000),
    S22050(22050),
    S44100(44100),
    S48000(48000),
    S88200(88200),
    S96600(96600),
    S176400(176400),
    S192000(192000),
    S352800(352800),
    S384000(384000),
}

enum class AudioFormat(val value: Int, val description: String) {
    I8(android.media.AudioFormat.ENCODING_PCM_8BIT, "u8"),
    I16(android.media.AudioFormat.ENCODING_PCM_16BIT, "i16"),

    @RequiresApi(Build.VERSION_CODES.S)
    I24(android.media.AudioFormat.ENCODING_PCM_24BIT_PACKED, "i24"),

    @RequiresApi(Build.VERSION_CODES.S)
    I32(android.media.AudioFormat.ENCODING_PCM_32BIT, "i32"),
    F32(android.media.AudioFormat.ENCODING_PCM_FLOAT, "f32");

    override fun toString(): String = description
}


enum class ChannelCount(val value: Int) {
    Mono(1),
    Stereo(2);

    @Composable
    fun getString(): String {

        return when (this) {
            Mono -> stringResource(R.string.mono)
            Stereo -> stringResource(R.string.stereo)
        }
    }

    fun getString(uiHelper: UiHelper): String {
        return when (this) {
            Mono -> uiHelper.getString(R.string.mono)
            Stereo -> uiHelper.getString(R.string.stereo)
        }
    }
}
