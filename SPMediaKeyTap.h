#include <Cocoa/Cocoa.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import <Carbon/Carbon.h>

// http://overooped.com/post/2593597587/mediakeys

#define SPSystemDefinedEventMediaKeys 8

@class SPMediaKeyTap;

@protocol SPMediaKeyTapDelegate <NSObject>
- (void)mediaKeyTap:(SPMediaKeyTap *)keyTap receivedMediaKeyEvent:(NSEvent *)event;
@end

@interface SPMediaKeyTap : NSObject {
	EventHandlerRef _app_switching_ref;
	EventHandlerRef _app_terminating_ref;
	CFMachPortRef _eventPort;
	CFRunLoopSourceRef _eventPortSource;
	CFRunLoopRef _tapThreadRL;
	BOOL _shouldInterceptMediaKeyEvents;
}

@property (nonatomic, weak) id<SPMediaKeyTapDelegate> delegate;

+ (NSArray*)defaultMediaKeyUserBundleIdentifiers;

- (instancetype)initWithDelegate:(id<SPMediaKeyTapDelegate>)delegate;

+(BOOL)usesGlobalMediaKeyTap;
-(void)startWatchingMediaKeys;
-(void)stopWatchingMediaKeys;
-(void)handleAndReleaseMediaKeyEvent:(NSEvent *)event;

@end

#ifdef __cplusplus
extern "C" {
#endif

extern NSString *kMediaKeyUsingBundleIdentifiersDefaultsKey;
extern NSString *kIgnoreMediaKeysDefaultsKey;

#ifdef __cplusplus
}
#endif
