#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ISZipVoiceSynthesisCancellation : NSObject

@property(atomic, readonly, getter=isCancelled) BOOL cancelled;

- (void)cancel;

@end

@interface ISZipVoiceTTSBridge : NSObject

@property(nonatomic, readonly) NSInteger modelSampleRate;

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
                       cancellation:(nullable ISZipVoiceSynthesisCancellation *)cancellation
                         sampleRate:(NSInteger *)sampleRate
                              error:(NSError **)error;

- (void)clearReferenceAudioCacheKeepingPath:(nullable NSString *)referenceAudioPath;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
