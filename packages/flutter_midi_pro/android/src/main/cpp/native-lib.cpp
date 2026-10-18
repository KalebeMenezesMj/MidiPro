#include <jni.h>
#include <fluidsynth.h>
#include <unistd.h>
#include <map>
#include <vector>
#include <android/log.h>

std::map<int, fluid_synth_t*> synths = {};
std::map<int, fluid_audio_driver_t*> drivers = {};
std::map<int, fluid_settings_t*> settings = {};
std::map<int, int> soundfonts = {};
int nextSfId = 1;

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

static void cleanup_instance(int sfId) {
    auto driverIt = drivers.find(sfId);
    if (driverIt != drivers.end() && driverIt->second != nullptr) {
        delete_fluid_audio_driver(driverIt->second);
        drivers.erase(driverIt);
    }

    auto synthIt = synths.find(sfId);
    if (synthIt != synths.end() && synthIt->second != nullptr) {
        delete_fluid_synth(synthIt->second);
        synths.erase(synthIt);
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

    char *driver = nullptr;
    if (fluid_settings_getstr_default(settings[instanceId], "audio.driver", &driver)) {
        __android_log_print(ANDROID_LOG_INFO, "FluidSynth", "Audio driver in use: %s", driver);
    } else {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth", "Failed to get audio.driver");
    }

    // On Android, "oboe" is expected to be the primary output driver.
    fluid_settings_setstr(settings[instanceId], "audio.driver", "oboe");
    fluid_settings_setnum(settings[instanceId], "synth.gain", 1.0);
    fluid_settings_setint(settings[instanceId], "audio.period-size", 64);
    fluid_settings_setint(settings[instanceId], "audio.periods", 4);
//    fluid_settings_setint(settings[nextSfId], "audio.realtime-prio", 99);
    fluid_settings_setnum(settings[instanceId], "synth.sample-rate", 44100.0);
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

    synths[instanceId] = new_fluid_synth(settings[instanceId]);
    if (synths[instanceId] == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth", "Failed to create new_fluid_synth instance!");
        env->ReleaseStringUTFChars(path, nativePath);
        cleanup_instance(instanceId);
        return -1;
    }

    __android_log_print(ANDROID_LOG_DEBUG, "FluidSynth", "Trying to load soundfont at: %s", nativePath);

    FILE* file = fopen(nativePath, "rb");
    if (!file) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth", "Soundfont file not found or cannot be opened: %s", nativePath);
    } else {
        __android_log_print(ANDROID_LOG_DEBUG, "FluidSynth", "Soundfont file found and readable: %s", nativePath);
        fclose(file);
    }

    __android_log_print(ANDROID_LOG_DEBUG, "FluidSynth", "Calling fluid_synth_sfload with synth: %p, path: %s", synths[instanceId], nativePath);
    int sfId = fluid_synth_sfload(synths[instanceId], nativePath, 0);
    __android_log_print(ANDROID_LOG_DEBUG, "FluidSynth", "sfload() returned: %d", sfId);

    if (sfId == -1) {
        __android_log_print(ANDROID_LOG_DEBUG, "FluidSynth", "Failed to load soundfont at path: %s", nativePath);
        env->ReleaseStringUTFChars(path, nativePath);
        cleanup_instance(instanceId);
        return -1;
    } else {
        __android_log_print(ANDROID_LOG_DEBUG, "FluidSynth", "loaded soundfont with id: %d", sfId);
    }

    drivers[instanceId] = new_fluid_audio_driver(settings[instanceId], synths[instanceId]);
    if (drivers[instanceId] == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, "FluidSynth", "Failed to create audio driver");
        env->ReleaseStringUTFChars(path, nativePath);
        cleanup_instance(instanceId);
        return -1;
    }

    for (int i = 0; i < 16; i++) {
        fluid_synth_program_select(synths[instanceId], i, sfId, bank, program);
    }

    __android_log_print(ANDROID_LOG_DEBUG, "FluidSynth", "selected programs for soundfontId: %d", sfId);

    env->ReleaseStringUTFChars(path, nativePath);
    soundfonts[instanceId] = sfId;
    nextSfId++;
    return instanceId;
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