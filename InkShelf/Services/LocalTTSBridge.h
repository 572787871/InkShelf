#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ISLocalTTSBridge : NSObject

@property(nonatomic, readonly) NSInteger numberOfSpeakers;

- (nullable instancetype)initWithEngine:(NSString *)engine
                               modelPath:(NSString *)modelPath
                              voicesPath:(nullable NSString *)voicesPath
                              tokensPath:(NSString *)tokensPath
                              lexiconPath:(nullable NSString *)lexiconPath
                           dataDirectory:(nullable NSString *)dataDirectory
                                   error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (nullable NSData *)synthesizeText:(NSString *)text
                          speakerID:(NSInteger)speakerID
                              speed:(float)speed
                         sampleRate:(NSInteger *)sampleRate
                              error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end


NS_ASSUME_NONNULL_END
