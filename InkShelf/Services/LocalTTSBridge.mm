#import "LocalTTSBridge.h"
#include <sherpa-onnx/c-api/c-api.h>

static NSString *const ISLocalTTSErrorDomain = @"InkShelf.LocalTTS";

@implementation ISLocalTTSBridge {
    const SherpaOnnxOfflineTts *_tts;
}

- (nullable instancetype)initWithEngine:(NSString *)engine
                               modelPath:(NSString *)modelPath
                              voicesPath:(nullable NSString *)voicesPath
                              tokensPath:(NSString *)tokensPath
                              lexiconPath:(nullable NSString *)lexiconPath
                           dataDirectory:(nullable NSString *)dataDirectory
                                   error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    SherpaOnnxOfflineTtsConfig config = {};
    config.model.num_threads = 2;
    config.model.debug = 0;
    config.model.provider = "cpu";
    config.max_num_sentences = 1;
    config.silence_scale = 0.2f;

    if ([engine isEqualToString:@"kokoro"]) {
        config.model.kokoro.model = modelPath.UTF8String;
        config.model.kokoro.voices = voicesPath.UTF8String;
        config.model.kokoro.tokens = tokensPath.UTF8String;
        config.model.kokoro.lexicon = lexiconPath.UTF8String;
        config.model.kokoro.data_dir = dataDirectory.UTF8String;
        config.model.kokoro.length_scale = 1.0f;
    } else if ([engine isEqualToString:@"vits"]) {
        config.model.vits.model = modelPath.UTF8String;
        config.model.vits.tokens = tokensPath.UTF8String;
        config.model.vits.lexicon = lexiconPath.UTF8String;
        config.model.vits.data_dir = dataDirectory.UTF8String;
        config.model.vits.noise_scale = 0.667f;
        config.model.vits.noise_scale_w = 0.8f;
        config.model.vits.length_scale = 1.0f;
    } else {
        if (error) {
            *error = [NSError errorWithDomain:ISLocalTTSErrorDomain code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"不支持的本地音色引擎"
            }];
        }
        return nil;
    }

    _tts = SherpaOnnxCreateOfflineTts(&config);
    if (!_tts) {
        if (error) {
            *error = [NSError errorWithDomain:ISLocalTTSErrorDomain code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"本地音色模型无法加载"
            }];
        }
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_tts) {
        SherpaOnnxDestroyOfflineTts(_tts);
        _tts = nullptr;
    }
}

- (NSInteger)numberOfSpeakers {
    return _tts ? MAX(1, SherpaOnnxOfflineTtsNumSpeakers(_tts)) : 0;
}

- (nullable NSData *)synthesizeText:(NSString *)text
                          speakerID:(NSInteger)speakerID
                              speed:(float)speed
                         sampleRate:(NSInteger *)sampleRate
                              error:(NSError **)error {
    if (!_tts || text.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:ISLocalTTSErrorDomain code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"没有可以合成的正文"
            }];
        }
        return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const SherpaOnnxGeneratedAudio *audio = SherpaOnnxOfflineTtsGenerate(
        _tts,
        text.UTF8String,
        (int32_t)MAX(0, speakerID),
        MAX(0.5f, MIN(2.0f, speed))
    );
#pragma clang diagnostic pop

    if (!audio || !audio->samples || audio->n <= 0 || audio->sample_rate <= 0) {
        if (audio) SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
        if (error) {
            *error = [NSError errorWithDomain:ISLocalTTSErrorDomain code:4 userInfo:@{
                NSLocalizedDescriptionKey: @"本地音色没有生成有效音频"
            }];
        }
        return nil;
    }

    NSData *pcm = [NSData dataWithBytes:audio->samples
                                 length:(NSUInteger)audio->n * sizeof(float)];
    if (sampleRate) *sampleRate = audio->sample_rate;
    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
    return pcm;
}

@end
