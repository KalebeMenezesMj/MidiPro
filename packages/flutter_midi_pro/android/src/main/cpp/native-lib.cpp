#include <jni.h>
#include <fluidsynth.h>
#include <unistd.h>
#include <map>
#include <vector>
#include <mutex>
#include <cmath>
#include <atomic>
#include <cstring>
#include <android/log.h>
#include <android/api-level.h>
#include <aaudio/AAudio.h>

std::map<int, fluid_synth_t*> synths = {};
std::map<int, fluid_settings_t*> settings = {};
std::map<int, int> soundfonts = {};
int nextSfId = 1;
std::atomic<int> g_muted{0};

// ---------------------------------------------------------------------------
// DSP por instância: EQ de 3 bandas + delay, com reverb nativo do FluidSynth.
// A saída usa AAudio (callback), render manual via fluid_synth_write_float.
// ---------------------------------------------------------------------------

struct EffectsParams {
    double reverb = 0.0;      // 0..1
    double delay = 0.0;       // 0..1 (nível do eco)
    double delayTime = 0.28;  // segundos
    double feedback = 0.0;    // 0..0.78
    double bass = 0;          // dB
    double mid = 0;
    double treble = 0;
};

struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float x1 = 0, x2 = 0, y1 = 0, y2 = 0;

    void setLowshelf(float freq, float gainDb, float sr) {
        float A = powf(10.0f, gainDb / 40.0f);
        float w0 = 2.0f * (float) M_PI * freq / sr;
        float cw = cosf(w0), sw = sinf(w0);
        float alpha = sw / 2.0f * sqrtf(2.0f);
        float twoSqrtAalpha = 2.0f * sqrtf(A) * alpha;
        float a0 = (A + 1) + (A - 1) * cw + twoSqrtAalpha;
        b0 = A * ((A + 1) - (A - 1) * cw + twoSqrtAalpha) / a0;
        b1 = 2 * A * ((A - 1) - (A + 1) * cw) / a0;
        b2 = A * ((A + 1) - (A - 1) * cw - twoSqrtAalpha) / a0;
        a1 = -2 * ((A - 1) + (A + 1) * cw) / a0;
        a2 = ((A + 1) + (A - 1) * cw - twoSqrtAalpha) / a0;
    }

    void setHighshelf(float freq, float gainDb, float sr) {
        float A = powf(10.0f, gainDb / 40.0f);
        float w0 = 2.0f * (float) M_PI * freq / sr;
        float cw = cosf(w0), sw = sinf(w0);
        float alpha = sw / 2.0f * sqrtf(2.0f);
        float twoSqrtAalpha = 2.0f * sqrtf(A) * alpha;
        float a0 = (A + 1) - (A - 1) * cw + twoSqrtAalpha;
        b0 = A * ((A + 1) + (A - 1) * cw + twoSqrtAalpha) / a0;
        b1 = -2 * A * ((A - 1) + (A + 1) * cw) / a0;
        b2 = A * ((A + 1) + (A - 1) * cw - twoSqrtAalpha) / a0;
        a1 = 2 * ((A - 1) - (A + 1) * cw) / a0;
        a2 = ((A + 1) - (A - 1) * cw - twoSqrtAalpha) / a0;
    }

    void setPeaking(float freq, float q, float gainDb, float sr) {
        float A = powf(10.0f, gainDb / 40.0f);
        float w0 = 2.0f * (float) M_PI * freq / sr;
        float cw = cosf(w0), sw = sinf(w0);
        float alpha = sw / (2.0f * q);
        float a0 = 1 + alpha / A;
        b0 = (1 + alpha * A) / a0;
        b1 = (-2 * cw) / a0;
        b2 = (1 - alpha * A) / a0;
        a1 = (-2 * cw) / a0;
        a2 = (1 - alpha / A) / a0;
    }

    inline float process(float x) {
        float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1; x1 = x;
        y2 = y1; y1 = y;
        return y;
    }
};

struct DelayLine {
    std::vector<float> buffer;
    size_t pos = 0;
    float feedback = 0;

    void configure(size_t samples, float fb) {
        buffer.assign(samples, 0.0f);
        pos = 0;
        feedback = fb;
    }

    inline float process(float x) {
        if (buffer.empty()) return 0.0f;
        float out = buffer[pos];
        buffer[pos] = x + out * feedback;
        pos = (pos + 1) % buffer.size();
        return out;
    }
};

struct Instance {
    fluid_synth_t* synth = nullptr;
    fluid_settings_t* fluidSettings = nullptr;

    AAudioStream* stream = nullptr;

    std::mutex mutex;
    EffectsParams pending;
    bool paramsDirty = false;

    Biquad eqL[3], eqR[3];
    DelayLine delayL, delayR;
    float delayWet = 0;
    bool delayEnabled = false;
    float sampleRate = 44100.0f;

    std::vector<float> scratchL;
    std::vector<float> scratchR;
};

std::map<int, Instance*> instances = {};

static const int kFrames = 512;

void fluid_log_callback(int level, const char* message, void* data) {
    __android_log_print(ANDROID_LOG_ERROR, "FluidSynth", "%s", message);
}

static fluid_synth_t* get_synth(int sfId) {
    auto it = synths.find(sfId);
    return it == synths.end() ? nullptr : it->second;
}

static int get_loaded_soundfont(int sfId) {
    auto it = soundfonts.find(sfId);
    return it == soundfonts.end() ? -1 : it->second;
}

static inline int16_t clip16(float x) {
    if (x > 32767.0f) x = 32767.0f;
    if (x < -32768.0f) x = -32768.0f;
    return (int16_t) x;
}

static void apply_pending_effects(Instance* inst) {
    std::lock_guard<std::mutex> lock(inst->mutex);
    if (!inst->paramsDirty) return;
    EffectsParams p = inst->pending;
    inst->paramsDirty = false;

    // Reverb nativo do FluidSynth (aplicado dentro do render do synth).
    fluid_synth_set_reverb(inst->synth, 0.1 + 0.8 * p.reverb, 0.35, 100.0,
                           p.reverb * 0.6);

    const float sr = inst->sampleRate;
    inst->eqL[0].setLowshelf(120.0f, (float) p.bass, sr);
    inst->eqL[1].setPeaking(1000.0f, 0.8f, (float) p.mid, sr);
    inst->eqL[2].setHighshelf(6000.0f, (float) p.treble, sr);
    inst->eqR[0].setLowshelf(120.0f, (float) p.bass, sr);
    inst->eqR[1].setPeaking(1000.0f, 0.8f, (float) p.mid, sr);
    inst->eqR[2].setHighshelf(6000.0f, (float) p.treble, sr);

    inst->delayEnabled = p.delay > 0;
    inst->delayWet = (float) (p.delay * 0.45);
    size_t samples = (size_t) (p.delayTime * sr);
    if (samples < 1) samples = 1;
    float fb = inst->delayEnabled ? (float) p.feedback : 0.0f;
    inst->delayL.configure(samples, fb);
    inst->delayR.configure(samples, fb);
}

static void render(Instance* inst, int16_t* out, int frames) {
    if (g_muted.load()) {
        memset(out, 0, (size_t) frames * 2 * sizeof(int16_t));
        return;
    }
    apply_pending_effects(inst);
    if ((int) inst->scratchL.size() < frames) {
        inst->scratchL.resize((size_t) frames);
        inst->scratchR.resize((size_t) frames);
    }
    std::vector<float>& l = inst->scratchL;
    std::vector<float>& r = inst->scratchR;
    fluid_synth_write_float(inst->synth, frames, l.data(), 0, 1, r.data(), 0, 1);

    for (int i = 0; i < frames; i++) {
        float xl = inst->eqL[0].process(inst->eqL[1].process(inst->eqL[2].process(l[i])));
        float xr = inst->eqR[0].process(inst->eqR[1].process(inst->eqR[2].process(r[i])));
        if (inst->delayEnabled) {
            float dl = inst->delayL.process(xl);
            float dr = inst->delayR.process(xr);
            xl = xl * (1.0f - inst->delayWet) + dl * inst->delayWet;
            xr = xr * (1.0f - inst->delayWet) + dr * inst->delayWet;
        }
        out[i * 2] = clip16(xl);
        out[i * 2 + 1] = clip16(xr);
    }
}

static aaudio_data_callback_result_t aaudioCallback(
    AAudioStream* stream, void* userData, void* audioData, int32_t numFrames) {
    Instance* inst = (Instance*) userData;
    if (inst->synth == nullptr) {
        memset(audioData, 0, (size_t) numFrames * 2 * sizeof(int16_t));
        return AAUDIO_CALLBACK_RESULT_CONTINUE;
    }
    render(inst, (int16_t*) audioData, (int) numFrames);
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

static bool open_stream(Instance* inst) {
    if (android_get_device_api_level() < 26) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth",
                            "AAudio requer Android 8+");
        return false;
    }

    AAudioStreamBuilder* builder = nullptr;
    aaudio_result_t result = AAudio_createStreamBuilder(&builder);
    if (result != AAUDIO_OK || builder == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth",
                            "AAudio_createStreamBuilder failed: %d", (int) result);
        return false;
    }

    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setChannelCount(builder, 2);
    AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    AAudioStreamBuilder_setDataCallback(builder, aaudioCallback, inst);
    AAudioStreamBuilder_setFramesPerDataCallback(builder, kFrames);

    result = AAudioStreamBuilder_openStream(builder, &inst->stream);
    AAudioStreamBuilder_delete(builder);
    if (result != AAUDIO_OK || inst->stream == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth",
                            "openStream failed: %d", (int) result);
        return false;
    }
    return true;
}

static void start_stream(Instance* inst) {
    aaudio_result_t result = AAudioStream_requestStart(inst->stream);
    if (result != AAUDIO_OK) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth",
                            "requestStart failed: %d", (int) result);
    }
}

static void cleanup_instance(int sfId) {
    auto instIt = instances.find(sfId);
    if (instIt != instances.end()) {
        Instance* inst = instIt->second;
        fluid_synth_t* synthToDelete = inst->synth;
        inst->synth = nullptr;
        if (inst->stream != nullptr) {
            AAudioStream_requestStop(inst->stream);
            AAudioStream_close(inst->stream);
        }
        delete inst;
        instances.erase(instIt);
        if (synthToDelete != nullptr) {
            delete_fluid_synth(synthToDelete);
        }
        synths.erase(sfId);
    }

    auto settingsIt = settings.find(sfId);
    if (settingsIt != settings.end() && settingsIt->second != nullptr) {
        delete_fluid_settings(settingsIt->second);
        settings.erase(settingsIt);
    }

    soundfonts.erase(sfId);
}

extern "C" JNIEXPORT int JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_loadSoundfont(JNIEnv* env, jclass clazz, jstring path, jint bank, jint program) {
    const int instanceId = nextSfId;
    settings[instanceId] = new_fluid_settings();
    if (settings[instanceId] == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth", "Failed to create settings");
        return -1;
    }

    fluid_settings_setstr(settings[instanceId], "audio.driver", "oboe");
    fluid_settings_setnum(settings[instanceId], "synth.gain", 1.0);
    fluid_settings_setint(settings[instanceId], "audio.period-size", 64);
    fluid_settings_setint(settings[instanceId], "audio.periods", 4);
    fluid_settings_setint(settings[instanceId], "synth.polyphony", 32);

    const char *nativePath = env->GetStringUTFChars(path, nullptr);
    if (nativePath == nullptr) {
        cleanup_instance(instanceId);
        return -1;
    }

    fluid_set_log_function(FLUID_PANIC, fluid_log_callback, nullptr);
    fluid_set_log_function(FLUID_ERR, fluid_log_callback, nullptr);
    fluid_set_log_function(FLUID_WARN, fluid_log_callback, nullptr);
    fluid_set_log_function(FLUID_INFO, fluid_log_callback, nullptr);
    fluid_set_log_function(FLUID_DBG, fluid_log_callback, nullptr);

    // Abre o stream AAudio antes do synth para casar a taxa de amostragem.
    Instance* inst = new Instance();
    inst->fluidSettings = settings[instanceId];
    if (!open_stream(inst)) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth", "Failed to open audio stream");
        delete inst;
        env->ReleaseStringUTFChars(path, nativePath);
        cleanup_instance(instanceId);
        return -1;
    }
    int32_t rate = AAudioStream_getSampleRate(inst->stream);
    if (rate <= 0) rate = 44100;
    inst->sampleRate = (float) rate;
    fluid_settings_setnum(settings[instanceId], "synth.sample-rate", (double) rate);

    synths[instanceId] = new_fluid_synth(settings[instanceId]);
    if (synths[instanceId] == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth", "Failed to create new_fluid_synth instance!");
        AAudioStream_close(inst->stream);
        delete inst;
        env->ReleaseStringUTFChars(path, nativePath);
        cleanup_instance(instanceId);
        return -1;
    }
    inst->synth = synths[instanceId];

    int sfId = fluid_synth_sfload(synths[instanceId], nativePath, 0);
    env->ReleaseStringUTFChars(path, nativePath);

    if (sfId == -1) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth", "Failed to load soundfont");
        cleanup_instance(instanceId);
        return -1;
    }

    for (int i = 0; i < 16; i++) {
        fluid_synth_program_select(synths[instanceId], i, sfId, bank, program);
    }

    inst->scratchL.assign((size_t) kFrames, 0.0f);
    inst->scratchR.assign((size_t) kFrames, 0.0f);
    instances[instanceId] = inst;
    start_stream(inst);

    soundfonts[instanceId] = sfId;
    nextSfId++;
    return instanceId;
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_setAudioEffects(JNIEnv* env, jclass clazz, jint sfId, jdouble reverb, jdouble delay, jdouble delayTime, jdouble feedback, jdouble bass, jdouble mid, jdouble treble) {
    auto it = instances.find(sfId);
    if (it == instances.end()) return;
    Instance* inst = it->second;
    std::lock_guard<std::mutex> lock(inst->mutex);
    inst->pending.reverb = reverb;
    inst->pending.delay = delay;
    inst->pending.delayTime = delayTime;
    inst->pending.feedback = feedback;
    inst->pending.bass = bass;
    inst->pending.mid = mid;
    inst->pending.treble = treble;
    inst->paramsDirty = true;
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_selectInstrument(JNIEnv* env, jclass clazz, jint sfId, jint channel, jint bank, jint program) {
    fluid_synth_t* synth = get_synth(sfId);
    int loadedSoundfontId = get_loaded_soundfont(sfId);
    if (synth == nullptr || loadedSoundfontId == -1) {
        return;
    }
    fluid_synth_program_select(synth, channel, loadedSoundfontId, bank, program);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_playNote(JNIEnv* env, jclass clazz, jint channel, jint key, jint velocity, jint sfId) {
    fluid_synth_t* synth = get_synth(sfId);
    if (synth == nullptr) {
        return;
    }
    fluid_synth_noteon(synth, channel, key, velocity);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_stopNote(JNIEnv* env, jclass clazz, jint channel, jint key, jint sfId) {
    fluid_synth_t* synth = get_synth(sfId);
    if (synth == nullptr) {
        return;
    }
    fluid_synth_noteoff(synth, channel, key);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_stopAllNotes(JNIEnv* env, jclass clazz, jint sfId) {
    fluid_synth_t* synth = get_synth(sfId);
    if (synth == nullptr) {
        return;
    }
    fluid_synth_all_notes_off(synth, -1);
    fluid_synth_system_reset(synth);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_pitchBend(JNIEnv* env, jclass clazz, jint channel, jint value, jint sfId) {
    fluid_synth_t* synth = get_synth(sfId);
    if (synth == nullptr) {
        return;
    }
    // fluid_synth_pitch_bend espera -8192..8191; o valor recebido é 14 bits (0..16383).
    fluid_synth_pitch_bend(synth, channel, value - 8192);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_controlChange(JNIEnv* env, jclass clazz, jint channel, jint controller, jint value, jint sfId) {
    fluid_synth_t* synth = get_synth(sfId);
    if (synth == nullptr) {
        return;
    }
    fluid_synth_cc(synth, channel, controller, value);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_pitchWheelSensitivity(JNIEnv* env, jclass clazz, jint sfId, jint channel, jdouble semitones) {
    fluid_synth_t* synth = get_synth(sfId);
    if (synth == nullptr) {
        return;
    }
    for (int c = 0; c < 16; c++) {
        fluid_synth_pitch_wheel_sens(synth, c, (int) semitones);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_setMuted(JNIEnv* env, jclass clazz, jint muted) {
    g_muted.store(muted != 0 ? 1 : 0);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_unloadSoundfont(JNIEnv* env, jclass clazz, jint sfId) {
    cleanup_instance(sfId);
}

extern "C" JNIEXPORT void JNICALL
Java_com_melihhakanpektas_flutter_1midi_1pro_FlutterMidiProPlugin_dispose(JNIEnv* env, jclass clazz) {
    std::vector<int> keys;
    keys.reserve(synths.size());
    for (const auto& item : synths) {
        keys.push_back(item.first);
    }
    for (int sfId : keys) {
        cleanup_instance(sfId);
    }
    nextSfId = 1;
}
