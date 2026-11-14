#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The error domain of an Objective-C exception that was caught and turned into an error.
FOUNDATION_EXPORT NSErrorDomain const HushyObjCExceptionDomain;
/// `userInfo` keys: the exception's name and its reason, as the framework wrote them.
FOUNDATION_EXPORT NSErrorUserInfoKey const HushyObjCExceptionNameKey;
FOUNDATION_EXPORT NSErrorUserInfoKey const HushyObjCExceptionReasonKey;

/// Swift cannot catch an Objective-C exception: one raised under a Swift caller ends the app.
/// AVFAudio raises them for conditions that are ordinary on a Mac whose audio devices are
/// changing (a tap format the hardware no longer has). This runs one call and hands the
/// exception back as an error. Keep the block to the single framework call: nothing between the
/// raise and the catch is cleaned up.
@interface HushyObjCExceptionCatcher : NSObject
+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
