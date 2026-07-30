#import "include/ObjCException.h"

NSException *_Nullable DSExceptionFrom(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
