#import "CloseSealURLSessionStub.h"

@implementation CloseSealURLSessionStub

- (instancetype)initForRecording
{
    // Foundation exposes no non-deprecated designated initializer for NSURLSession subclasses.
    // The Swift recorder forwards all real task creation to a configured backing session.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [super init];
#pragma clang diagnostic pop
}

@end
