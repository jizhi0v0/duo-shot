#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside `@try`/`@catch` and returns the NSException it raised, or
/// nil.
///
/// Swift has no way to catch an ObjC exception, and — worse — Swift frames carry
/// no cleanup for one: an NSException thrown by AppKit under a Swift call
/// unwinds straight through, skipping every release and leaving half-registered
/// objects behind. That is not hypothetical here; see the note at the call site
/// in OverlayController.
///
/// This is a containment shim, not error handling. Anything caught is a bug in
/// us or in AppKit; the caller's job is to log it and get back to a sane state.
NSException *_Nullable DSExceptionFrom(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
