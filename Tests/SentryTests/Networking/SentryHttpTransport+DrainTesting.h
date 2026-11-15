#import "SentryHttpTransport.h"

NS_ASSUME_NONNULL_BEGIN

@interface SentryHttpTransport (DrainTesting)

- (void)setDrainFlushStateCallback:(void (^_Nullable)(
                                       NSObject *identity, BOOL activated, BOOL terminal))callback;
- (void)setDrainFlushCleanupCallback:(void (^_Nullable)(
                                         NSObject *identity, NSInteger waitResult))callback;

@end

NS_ASSUME_NONNULL_END
