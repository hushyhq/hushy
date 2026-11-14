#import "HushyObjC.h"

NSErrorDomain const HushyObjCExceptionDomain = @"app.hushy.objc-exception";
NSErrorUserInfoKey const HushyObjCExceptionNameKey = @"HushyObjCExceptionName";
NSErrorUserInfoKey const HushyObjCExceptionReasonKey = @"HushyObjCExceptionReason";

@implementation HushyObjCExceptionCatcher

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: @"";
            *error = [NSError errorWithDomain:HushyObjCExceptionDomain code:1 userInfo:@{
                HushyObjCExceptionNameKey: exception.name,
                HushyObjCExceptionReasonKey: reason,
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, reason],
            }];
        }
        return NO;
    }
}

@end
