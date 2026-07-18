#import "ZipVoiceTTSBridge.h"
#include <sherpa-onnx/c-api/c-api.h>
#include <atomic>

static NSString *const ISZipVoiceErrorDomain = @"InkShelf.ZipVoice";

@implementation ISZipVoiceSynthesisCancellation {
    std::atomic_bool _cancelled;
}

- (instancetype)init {
    self = [super init];
    if (self) _cancelled.store(false);
    return self;
}

- (BOOL)isCancelled {
    return _cancelled.load();
}

- (void)cancel {
    _cancelled.store(true);
}

@end

static int32_t ISZipVoiceProgressCallback(const float *, int32_t, float, void *arg) {
    if (!arg) return 1;
    ISZipVoiceSynthesisCancellation *cancellation = (__bridge ISZipVoiceSynthesisCancellation *)arg;
    return cancellation.isCancelled ? 0 : 1;
}

@implementation ISZipVoiceTTSBridge {
    const SherpaOnnxOfflineTts *_tts;
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *_referenceAudioCache;
}

- (nullable instancetype)initWithEncoderPath:(NSString *)encoderPath
                                  decoderPath:(NSString *)decoderPath
                                  vocoderPath:(NSString *)vocoderPath
                                   tokensPath:(NSString *)tokensPath
                                  lexiconPath:(NSString *)lexiconPath
                                dataDirectory:(NSString *)dataDirectory
                                        error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    SherpaOnnxOfflineTtsConfig config = {};
    config.model.num_threads = 4;
    config.model.debug = 0;
    config.model.provider = "cpu";
    config.model.zipvoice.encoder = encoderPath.UTF8String;
    config.model.zipvoice.decoder = decoderPath.UTF8String;
    config.model.zipvoice.vocoder = vocoderPath.UTF8String;
    config.model.zipvoice.tokens = tokensPath.UTF8String;
    config.model.zipvoice.lexicon = lexiconPath.UTF8String;
    config.model.zipvoice.data_dir = dataDirectory.UTF8String;
    config.model.zipvoice.feat_scale = 0.1f;
    config.model.zipvoice.t_shift = 0.5f;
    config.model.zipvoice.target_rms = 0.1f;
    config.model.zipvoice.guidance_scale = 1.0f;
    config.max_num_sentences = 8;
    config.silence_scale = 0.04f;

    _tts = SherpaOnnxCreateOfflineTts(&config);
    if (!_tts) {
        if (error) *error = [NSError errorWithDomain:ISZipVoiceErrorDomain code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"ZipVoice 模型无法加载"
        }];
        return nil;
    }
    _referenceAudioCache = [NSMutableDictionary dictionary];
    return self;
}

- (NSInteger)modelSampleRate {
    return _tts ? SherpaOnnxOfflineTtsSampleRate(_tts) : 0;
}

- (void)dealloc {
    if (_tts) {
        SherpaOnnxDestroyOfflineTts(_tts);
        _tts = nullptr;
    }
}

- (nullable NSData *)synthesizeText:(NSString *)text
                 referenceAudioPath:(NSString *)referenceAudioPath
                      referenceText:(NSString *)referenceText
                              speed:(float)speed
                       cancellation:(nullable ISZipVoiceSynthesisCancellation *)cancellation
                         sampleRate:(NSInteger *)sampleRate
                              error:(NSError **)error {
    if (!_tts || text.length == 0 || referenceText.length == 0) {
        if (error) *error = [NSError errorWithDomain:ISZipVoiceErrorDomain code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"缺少正文或参考文字"
        }];
        return nil;
    }
    NSDictionary<NSString *, id> *cached = _referenceAudioCache[referenceAudioPath];
    if (!cached) {
        const SherpaOnnxWave *wave = SherpaOnnxReadWave(referenceAudioPath.UTF8String);
        if (!wave || !wave->samples || wave->num_samples <= 0) {
            if (wave) SherpaOnnxFreeWave(wave);
            if (error) *error = [NSError errorWithDomain:ISZipVoiceErrorDomain code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"参考 WAV 无法读取，请使用 PCM WAV 文件"
            }];
            return nil;
        }
        NSData *samples = [NSData dataWithBytes:wave->samples length:(NSUInteger)wave->num_samples * sizeof(float)];
        cached = @{
            @"samples": samples,
            @"count": @(wave->num_samples),
            @"sampleRate": @(wave->sample_rate)
        };
        _referenceAudioCache[referenceAudioPath] = cached;
        SherpaOnnxFreeWave(wave);
    }
    NSData *referenceSamples = cached[@"samples"];
    NSNumber *referenceCount = cached[@"count"];
    NSNumber *referenceRate = cached[@"sampleRate"];

    SherpaOnnxGenerationConfig generation = {};
    generation.silence_scale = 0.04f;
    generation.speed = MAX(0.7f, MIN(1.2f, speed));
    generation.reference_audio = (const float *)referenceSamples.bytes;
    generation.reference_audio_len = referenceCount.intValue;
    generation.reference_sample_rate = referenceRate.intValue;
    generation.reference_text = referenceText.UTF8String;
    // Four flow-matching steps are the official distilled ZipVoice setting.
    // Eight doubled first-audio latency on iPhone without being required by
    // the INT8 distilled model.
    generation.num_steps = 4;
    generation.extra = "{\"min_char_in_sentence\":\"10\",\"max_char_in_sentence\":\"120\"}";

    const SherpaOnnxGeneratedAudio *audio = SherpaOnnxOfflineTtsGenerateWithConfig(
        _tts,
        text.UTF8String,
        &generation,
        cancellation ? ISZipVoiceProgressCallback : nullptr,
        cancellation ? (__bridge void *)cancellation : nullptr
    );
    if (!audio || !audio->samples || audio->n <= 0 || audio->sample_rate <= 0) {
        if (audio) SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
        if (cancellation.isCancelled) {
            if (error) *error = [NSError errorWithDomain:ISZipVoiceErrorDomain code:5 userInfo:@{
                NSLocalizedDescriptionKey: @"ZipVoice 生成已取消"
            }];
            return nil;
        }
        if (error) *error = [NSError errorWithDomain:ISZipVoiceErrorDomain code:4 userInfo:@{
            NSLocalizedDescriptionKey: @"ZipVoice 没有生成有效音频"
        }];
        return nil;
    }
    NSData *pcm = [NSData dataWithBytes:audio->samples length:(NSUInteger)audio->n * sizeof(float)];
    if (sampleRate) *sampleRate = audio->sample_rate;
    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
    return pcm;
}

- (void)clearReferenceAudioCacheKeepingPath:(nullable NSString *)referenceAudioPath {
    if (!referenceAudioPath) {
        [_referenceAudioCache removeAllObjects];
        return;
    }
    NSDictionary<NSString *, id> *retained = _referenceAudioCache[referenceAudioPath];
    [_referenceAudioCache removeAllObjects];
    if (retained) _referenceAudioCache[referenceAudioPath] = retained;
}

@end
