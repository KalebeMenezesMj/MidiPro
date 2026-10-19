package com.melihhakanpektas.flutter_midi_pro

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.EventChannel
import android.media.AudioManager
import android.media.AudioTrack
import android.media.AudioFormat
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.midi.MidiManager
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** FlutterMidiProPlugin */
class FlutterMidiProPlugin: FlutterPlugin, MethodCallHandler {
  companion object {
    private const val TAG = "FlutterMidiProPlugin"
    private var nativeLibLoaded = false
    private var nativeLibLoadError: String? = null

    init {
      try {
        System.loadLibrary("c++_shared")
        System.loadLibrary("native-lib")
        nativeLibLoaded = true
      } catch (err: UnsatisfiedLinkError) {
        nativeLibLoadError = err.message ?: "Unable to load native-lib"
        Log.e(TAG, "Failed to load native-lib", err)
      } catch (err: Throwable) {
        nativeLibLoadError = err.message ?: "Unexpected error while loading native-lib"
        Log.e(TAG, "Unexpected native-lib load failure", err)
      }
    }
    @JvmStatic
    private external fun loadSoundfont(path: String, bank: Int, program: Int): Int

    @JvmStatic
    private external fun selectInstrument(sfId: Int, channel:Int, bank: Int, program: Int)

    @JvmStatic
    private external fun playNote(channel: Int, key: Int, velocity: Int, sfId: Int)

    @JvmStatic
    private external fun stopNote(channel: Int, key: Int, sfId: Int)

    @JvmStatic
    private external fun stopAllNotes(sfId: Int)

    @JvmStatic
    private external fun pitchBend(channel: Int, value: Int, sfId: Int)

    @JvmStatic
    private external fun controlChange(channel: Int, controller: Int, value: Int, sfId: Int)

    @JvmStatic
    private external fun setAudioEffects(
        sfId: Int,
        reverb: Double,
        delay: Double,
        delayTime: Double,
        feedback: Double,
        bass: Double,
        mid: Double,
        treble: Double,
    )

    @JvmStatic
    private external fun setMuted(muted: Int)

    @JvmStatic
    private external fun unloadSoundfont(sfId: Int)
    @JvmStatic
    private external fun dispose()
  }

  private lateinit var channel : MethodChannel
  private lateinit var flutterPluginBinding: FlutterPlugin.FlutterPluginBinding

  private var midiManager: MidiManager? = null
  private var midiDevice: MidiDevice? = null
  private var midiOutputPort: MidiOutputPort? = null
  private var midiEventSink: EventChannel.EventSink? = null
  private val mainHandler = Handler(Looper.getMainLooper())

  private var clickTrack: AudioTrack? = null
  private var clickBytes: ByteArray? = null
  private var clickAccentTrack: AudioTrack? = null
  private var clickAccentBytes: ByteArray? = null

  private var audioFocusRequest: AudioFocusRequest? = null
  private var audioFocusRequested = false

  private val audioFocusChangeListener =
    AudioManager.OnAudioFocusChangeListener { change ->
      when (change) {
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
        AudioManager.AUDIOFOCUS_LOSS -> setMuted(1)
        AudioManager.AUDIOFOCUS_GAIN -> setMuted(0)
      }
    }

  private fun ensureAudioFocus() {
    if (audioFocusRequested) return
    try {
      val am = flutterPluginBinding.applicationContext
        .getSystemService(Context.AUDIO_SERVICE) as AudioManager
      val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(
          AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build(),
        )
        .setOnAudioFocusChangeListener(audioFocusChangeListener)
        .build()
      val result = am.requestAudioFocus(request)
      if (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
        audioFocusRequest = request
        audioFocusRequested = true
      }
    } catch (_: Throwable) {
      // Sem foco de áudio disponível; segue tocando.
    }
  }

  private fun abandonAudioFocus() {
    if (!audioFocusRequested) return
    try {
      val am = flutterPluginBinding.applicationContext
        .getSystemService(Context.AUDIO_SERVICE) as AudioManager
      audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
    } catch (_: Throwable) {}
    audioFocusRequested = false
    audioFocusRequest = null
  }

  private fun generateClick(frequency: Double, amplitude: Double): ByteArray {
    val sampleRate = 44100
    val durationMs = 40
    val n = sampleRate * durationMs / 1000
    val buffer = ByteArray(n * 2) // PCM 16 bits mono
    for (i in 0 until n) {
      val t = i.toDouble() / sampleRate
      val env = Math.exp(-t * 110.0)
      val sample = (Math.sin(2.0 * Math.PI * frequency * t) * env * amplitude
        * Short.MAX_VALUE).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
      buffer[i * 2] = (sample and 0xFF).toByte()
      buffer[i * 2 + 1] = ((sample shr 8) and 0xFF).toByte()
    }
    return buffer
  }

  private fun ensureClickTrack(accent: Boolean): AudioTrack {
    if (accent) {
      if (clickAccentTrack == null) {
        clickAccentBytes = generateClick(1320.0, 0.9)
        val minBuf = AudioTrack.getMinBufferSize(
          44100, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        clickAccentTrack = AudioTrack(
          AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build(),
          AudioFormat.Builder()
            .setSampleRate(44100)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build(),
          maxOf(minBuf, clickAccentBytes!!.size),
          AudioTrack.MODE_STATIC,
          AudioManager.AUDIO_SESSION_ID_GENERATE,
        )
        clickAccentTrack!!.write(clickAccentBytes!!, 0, clickAccentBytes!!.size)
      }
      return clickAccentTrack!!
    }
    if (clickTrack == null) {
      clickBytes = generateClick(880.0, 0.7)
      val minBuf = AudioTrack.getMinBufferSize(
        44100, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
      clickTrack = AudioTrack(
        AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_MEDIA)
          .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
          .build(),
        AudioFormat.Builder()
          .setSampleRate(44100)
          .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
          .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
          .build(),
        maxOf(minBuf, clickBytes!!.size),
        AudioTrack.MODE_STATIC,
        AudioManager.AUDIO_SESSION_ID_GENERATE,
      )
      clickTrack!!.write(clickBytes!!, 0, clickBytes!!.size)
    }
    return clickTrack!!
  }

  private fun playClick(accent: Boolean) {
    try {
      val track = ensureClickTrack(accent)
      track.stop()
      track.setPlaybackHeadPosition(0)
      track.play()
    } catch (_: Throwable) {
      // Sem áudio para o clique; ignora.
    }
  }

  private fun getMidiManager(): MidiManager {
    if (midiManager == null) {
      midiManager = flutterPluginBinding.applicationContext
        .getSystemService(Context.MIDI_SERVICE) as MidiManager
    }
    return midiManager!!
  }

  private val midiReceiver = object : MidiReceiver() {
    override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
      val bytes = ArrayList<Int>(count)
      for (i in offset until offset + count) {
        bytes.add(msg[i].toInt() and 0xFF)
      }
      mainHandler.post { midiEventSink?.success(bytes) }
    }
  }

  private fun closeMidiInputQuietly() {
    try { midiOutputPort?.close() } catch (_: Throwable) {}
    try { midiDevice?.close() } catch (_: Throwable) {}
    midiOutputPort = null
    midiDevice = null
  }

  private fun listMidiDevices(result: MethodChannel.Result) {
    try {
      // Para RECEBER MIDI usamos as portas de saída do dispositivo.
      val list = getMidiManager().devices
        .filter { it.outputPortCount > 0 }
        .map {
          mapOf(
            "id" to it.id,
            "name" to (it.properties.getString(MidiDeviceInfo.PROPERTY_NAME)
              ?: "MIDI ${it.id}"),
          )
        }
      result.success(list)
    } catch (_: Throwable) {
      result.success(emptyList<Any>())
    }
  }

  private fun openMidiInput(call: MethodCall, result: MethodChannel.Result) {
    try {
      closeMidiInputQuietly()
      val deviceId = call.argument<Int>("deviceId") ?: -1
      val info = getMidiManager().devices.firstOrNull { it.id == deviceId }
      if (info == null) { result.success(false); return }
      getMidiManager().openDevice(info, { device ->
        if (device == null) { result.success(false); return@openDevice }
        midiDevice = device
        val port = device.openOutputPort(0)
        if (port == null) { result.success(false); return@openDevice }
        midiOutputPort = port
        port.connect(midiReceiver)
        result.success(true)
      }, mainHandler)
    } catch (_: Throwable) {
      result.success(false)
    }
  }

  private fun closeMidiInput(result: MethodChannel.Result) {
    closeMidiInputQuietly()
    result.success(null)
  }

  private fun ensureNativeLibLoaded(result: MethodChannel.Result): Boolean {
    if (nativeLibLoaded) return true
    result.error(
      "NATIVE_LIB_LOAD_FAILED",
      nativeLibLoadError ?: "native-lib was not loaded",
      null
    )
    return false
  }

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    this.flutterPluginBinding = flutterPluginBinding
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_midi_pro")
    channel.setMethodCallHandler(this)

    EventChannel(flutterPluginBinding.binaryMessenger, "flutter_midi_pro/midi_input")
      .setStreamHandler(object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
          midiEventSink = events
        }
        override fun onCancel(arguments: Any?) {
          midiEventSink = null
          closeMidiInputQuietly()
        }
      })
  }
 override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    // Entrada MIDI não depende da lib nativa (FluidSynth).
    if (call.method == "midiDevices") { listMidiDevices(result); return }
    if (call.method == "openMidiInput") { openMidiInput(call, result); return }
    if (call.method == "closeMidiInput") { closeMidiInput(result); return }
    if (call.method == "playClick") {
      playClick(call.argument<Boolean>("accent") ?: false)
      result.success(null)
      return
    }

    if (!ensureNativeLibLoaded(result)) {
      return
    }
    when (call.method) {
      "loadSoundfont" -> {
        CoroutineScope(Dispatchers.IO).launch {
          val path = call.argument<String>("path") as String
          val bank = call.argument<Int>("bank")?:0
          val program = call.argument<Int>("program")?:0
          val audioManager = flutterPluginBinding.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

          // Sesi mute yapma
          audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)

          // Soundfont yükleme işlemi (senkron, bloke eden çağrı)
          val sfId = loadSoundfont(path, bank, program)
          delay(250)

          // Sesi tekrar açma
          audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)

          // Sonucu ana thread'de Flutter'a iletme
          withContext(Dispatchers.Main) {
            if (sfId == -1) {
              result.error("INVALID_ARGUMENT", "Something went wrong. Check the path of the template soundfont", null)
            } else {
              result.success(sfId)
            }
          }
        }
      }
      "selectInstrument" -> {
        val sfId = call.argument<Int>("sfId")?:1
        val channel = call.argument<Int>("channel")?:0
        val bank = call.argument<Int>("bank")?:0
        val program = call.argument<Int>("program")?:0
          selectInstrument(sfId, channel, bank, program)
          result.success(null)
        }
      "playNote" -> {
        val channel = call.argument<Int>("channel")
        val key = call.argument<Int>("key")
        val velocity = call.argument<Int>("velocity")
        val sfId = call.argument<Int>("sfId")
        if (channel != null && key != null && velocity != null && sfId != null) {
          ensureAudioFocus()
          playNote(channel, key, velocity, sfId)
          result.success(null)
        } else {
          result.error("INVALID_ARGUMENT", "channel, key, and velocity are required", null)
        }
      }
      "stopNote" -> {
        val channel = call.argument<Int>("channel")
        val key = call.argument<Int>("key")
        val sfId = call.argument<Int>("sfId")
        if (channel != null && key != null && sfId != null) {
          stopNote(channel, key, sfId)
          result.success(null)
        } else {
          result.error("INVALID_ARGUMENT", "channel and key are required", null)
        }
      }
      "stopAllNotes" -> {
        val sfId = call.argument<Int>("sfId") as Int
        stopAllNotes(sfId)
        result.success(null)
      }
      "pitchBend" -> {
        val channel = call.argument<Int>("channel") ?: 0
        val value = call.argument<Int>("value") ?: 8192
        val sfId = call.argument<Int>("sfId") ?: 1
        pitchBend(channel, value, sfId)
        result.success(null)
      }
      "controlChange" -> {
        val channel = call.argument<Int>("channel") ?: 0
        val controller = call.argument<Int>("controller") ?: 0
        val value = call.argument<Int>("value") ?: 0
        val sfId = call.argument<Int>("sfId") ?: 1
        controlChange(channel, controller, value, sfId)
        result.success(null)
      }
      "setAudioEffects" -> {
        val sfId = call.argument<Int>("sfId") ?: 1
        val effects = call.argument<Map<*, *>>("effects") as Map<*, *>?
        if (effects == null) { result.success(null); return }
        fun num(key: String, default: Double): Double =
          (effects[key] as? Number)?.toDouble() ?: default
        setAudioEffects(
          sfId,
          num("reverb", 0.0),
          num("delay", 0.0),
          num("delayTime", 0.28),
          num("feedback", 0.0),
          num("bass", 0.0),
          num("mid", 0.0),
          num("treble", 0.0),
        )
        result.success(null)
      }
      "unloadSoundfont" -> {
        val sfId = call.argument<Int>("sfId")
        if (sfId != null) {
          unloadSoundfont(sfId)
          result.success(null)
        } else {
          result.error("INVALID_ARGUMENT", "sfId is required", null)
        }
      }
      "dispose" -> {
        dispose()
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    midiEventSink = null
    closeMidiInputQuietly()
    abandonAudioFocus()
    channel.setMethodCallHandler(null)
  }
}