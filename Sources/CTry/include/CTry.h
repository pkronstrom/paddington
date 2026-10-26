#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil. AVFoundation raises NSExceptions (for example
/// "player did not see an IO cycle" from AVAudioPlayerNode.play), which Swift can't catch: uncaught, they abort.
NSException * _Nullable CTryCatch(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
