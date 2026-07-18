#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ISZipVoiceTTSBridge : NSObject

- (nullable instancetype)initWithEncoderPath:(NSString *)encoderPath
                                  decoderPath:(NSString *)decoderPath
                                  vocoderPath:(NSString *)vocoderPath
                                   tokensPath:(NSString *)tokensPath
                                  lexiconPath:(NSString *)lexiconPath
                                dataDirectory:(NSString *)dataDirectory
                                        error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (nullable NSData *)synthesizeText:(NSString *)text
                 referenceAudioPath:(NSString *)referenceAudioPath
                      referenceText:(NSString *)referenceText
                              speed:(float)speed
                         sampleRate:(NSInteger *)sampleRate
                              error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
