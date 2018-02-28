// Copyright (c) 2010 Spotify AB
#import "SPMediaKeyTap.h"
#import "SPInvocationGrabbing/NSObject+SPInvocationGrabbing.h" // https://gist.github.com/511181, in submodule

@interface SPMediaKeyTap ()

@property (nonatomic) NSMutableArray *mediaKeyAppList;


-(BOOL)shouldInterceptMediaKeyEvents;
-(void)setShouldInterceptMediaKeyEvents:(BOOL)newSetting;
-(void)startWatchingAppSwitching;
-(void)stopWatchingAppSwitching;
-(void)eventTapThread;
@end
static SPMediaKeyTap *singleton = nil;


// Inspired by http://gist.github.com/546311

@implementation SPMediaKeyTap

#pragma mark -
#pragma mark Setup and teardown
- (instancetype)initWithDelegate:(id<SPMediaKeyTapDelegate>)delegate
{
    self = [super init];
    if (self) {
        self.delegate = delegate;
        [self startWatchingAppSwitching];
        singleton = self;
        self.mediaKeyAppList = [NSMutableArray new];
        _tapThreadRL=nil;
        _eventPort=nil;
        _eventPortSource=nil;
    }
	return self;
}

-(void)dealloc;
{
	[self stopWatchingMediaKeys];
	[self stopWatchingAppSwitching];
}

-(void)startWatchingAppSwitching;
{
	// Listen to "app switched" event, so that we don't intercept media keys if we
	// weren't the last "media key listening" app to be active
//    EventTypeSpec eventType = { kEventClassApplication, kEventAppFrontSwitched };
//    OSStatus err = InstallApplicationEventHandler(NewEventHandlerUPP(appSwitched), 1, &eventType, (__bridge void*)self, &_app_switching_ref);
//    assert(err == noErr);
//
//    eventType.eventKind = kEventAppTerminated;
//    err = InstallApplicationEventHandler(NewEventHandlerUPP(appTerminated), 1, &eventType, (__bridge void*)self, &_app_terminating_ref);
//    assert(err == noErr);
    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    [center addObserver:self selector:@selector(appTerminated:) name:NSWorkspaceDidTerminateApplicationNotification object:nil];
    [center addObserver:self selector:@selector(appSwitched:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
}
-(void)stopWatchingAppSwitching;
{
//    if(!_app_switching_ref) return;
//    RemoveEventHandler(_app_switching_ref);
//    _app_switching_ref = NULL;
    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    [center removeObserver:self name:NSWorkspaceDidTerminateApplicationNotification object:nil];
    [center removeObserver:self name:NSWorkspaceDidActivateApplicationNotification object:nil];
}

-(void)startWatchingMediaKeys;{
    // Prevent having multiple mediaKeys threads
    [self stopWatchingMediaKeys];
    
	[self setShouldInterceptMediaKeyEvents:YES];
	
	// Add an event tap to intercept the system defined media key events
	_eventPort = CGEventTapCreate(kCGSessionEventTap,
								  kCGHeadInsertEventTap,
								  kCGEventTapOptionDefault,
								  CGEventMaskBit(NX_SYSDEFINED),
								  tapEventCallback,
								  (__bridge void*)self);
	assert(_eventPort != NULL);
	
    _eventPortSource = CFMachPortCreateRunLoopSource(kCFAllocatorSystemDefault, _eventPort, 0);
	assert(_eventPortSource != NULL);
	
	// Let's do this in a separate thread so that a slow app doesn't lag the event tap
	[NSThread detachNewThreadSelector:@selector(eventTapThread) toTarget:self withObject:nil];
}
- (void)stopWatchingMediaKeys;
{
	// TODO<nevyn>: Shut down thread, remove event tap port and source
    
    if(_tapThreadRL){
        CFRunLoopStop(_tapThreadRL);
        _tapThreadRL=nil;
    }
    
    if(_eventPort){
        CFMachPortInvalidate(_eventPort);
        CFRelease(_eventPort);
        _eventPort=nil;
    }
    
    if(_eventPortSource){
        CFRelease(_eventPortSource);
        _eventPortSource=nil;
    }
}

#pragma mark -
#pragma mark Accessors

+ (BOOL)usesGlobalMediaKeyTap
{
    return NO;
}

+ (NSArray*)defaultMediaKeyUserBundleIdentifiers;
{
	return @[
		[[NSBundle mainBundle] bundleIdentifier],
		@"com.spotify.client",
		@"com.apple.iTunes",
		@"com.apple.QuickTimePlayerX",
		@"com.apple.quicktimeplayer",
		@"com.apple.iWork.Keynote",
		@"com.apple.iPhoto",
		@"org.videolan.vlc",
		@"com.apple.Aperture",
		@"com.plexsquared.Plex",
		@"com.soundcloud.desktop",
		@"org.niltsh.MPlayerX",
		@"com.ilabs.PandorasHelper",
		@"com.mahasoftware.pandabar",
		@"com.bitcartel.pandorajam",
		@"org.clementine-player.clementine",
		@"fm.last.Last.fm",
		@"com.beatport.BeatportPro",
		@"com.Timenut.SongKey",
		@"com.macromedia.fireworks", // the tap messes up their mouse input
		@"com.radev.Spacebeat",
        @"pl.micropixels.Anesidora"
	];
}


-(BOOL)shouldInterceptMediaKeyEvents;
{
	BOOL shouldIntercept = NO;
	@synchronized(self) {
		shouldIntercept = _shouldInterceptMediaKeyEvents;
	}
	return shouldIntercept;
}

-(void)pauseTapOnTapThread:(BOOL)yeahno;
{
	CGEventTapEnable(self->_eventPort, yeahno);
}

-(void)setShouldInterceptMediaKeyEvents:(BOOL)newSetting;
{
	BOOL oldSetting;
	@synchronized(self) {
		oldSetting = _shouldInterceptMediaKeyEvents;
		_shouldInterceptMediaKeyEvents = newSetting;
	}
	if(_tapThreadRL && oldSetting != newSetting) {
		id grab = [self grab];
		[grab pauseTapOnTapThread:newSetting];
		NSTimer *timer = [NSTimer timerWithTimeInterval:0 invocation:[grab invocation] repeats:NO];
		CFRunLoopAddTimer(_tapThreadRL, (__bridge CFRunLoopTimerRef)timer, kCFRunLoopCommonModes);
	}
}

#pragma mark 
#pragma mark -
#pragma mark Event tap callbacks

// Note: method called on background thread

static CGEventRef tapEventCallback2(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
	SPMediaKeyTap *self = (__bridge id)refcon;

    if (type == kCGEventTapDisabledByTimeout) {
		CGEventTapEnable(self->_eventPort, TRUE);
		return event;
	} else if(type == kCGEventTapDisabledByUserInput) {
		// Was disabled manually by -[pauseTapOnTapThread]
		return event;
	}
	NSEvent *nsEvent = nil;
	@try {
		nsEvent = [NSEvent eventWithCGEvent:event];
	}
	@catch (NSException * e) {
		NSLog(@"Strange CGEventType: %d: %@", type, e);
		assert(0);
		return event;
	}

	if (type != NX_SYSDEFINED || [nsEvent subtype] != SPSystemDefinedEventMediaKeys)
		return event;

	int keyCode = (([nsEvent data1] & 0xFFFF0000) >> 16);
    if (keyCode != NX_KEYTYPE_PLAY && keyCode != NX_KEYTYPE_FAST && keyCode != NX_KEYTYPE_REWIND && keyCode != NX_KEYTYPE_PREVIOUS && keyCode != NX_KEYTYPE_NEXT)
		return event;

	if (![self shouldInterceptMediaKeyEvents])
		return event;
	
	[self performSelectorOnMainThread:@selector(handleAndReleaseMediaKeyEvent:) withObject:nsEvent waitUntilDone:NO];
	
	return NULL;
}

static CGEventRef tapEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
	CGEventRef ret = tapEventCallback2(proxy, type, event, refcon);
	return ret;
}


// event will have been retained in the other thread
- (void)handleAndReleaseMediaKeyEvent:(NSEvent *)event
{
    [self.delegate mediaKeyTap:self receivedMediaKeyEvent:event];
}


-(void)eventTapThread;
{
	_tapThreadRL = CFRunLoopGetCurrent();
	CFRunLoopAddSource(_tapThreadRL, _eventPortSource, kCFRunLoopCommonModes);
	CFRunLoopRun();
}

#pragma mark Task switching callbacks

NSString *kMediaKeyUsingBundleIdentifiersDefaultsKey = @"SPApplicationsNeedingMediaKeys";
NSString *kIgnoreMediaKeysDefaultsKey = @"SPIgnoreMediaKeys";

- (void)appTerminated:(NSNotification *)note;
{
    NSRunningApplication *app = [note.userInfo objectForKey:NSWorkspaceApplicationKey];
    [_mediaKeyAppList removeObject:app];
    [self mediaKeyAppListChanged];
}

- (void)appSwitched:(NSNotification *)note
{
    NSRunningApplication *app = [note.userInfo objectForKey:NSWorkspaceApplicationKey];
    NSString *bundleIdentifier = app.bundleIdentifier;
    
    NSArray *whitelistIdentifiers = [SPMediaKeyTap defaultMediaKeyUserBundleIdentifiers];
    if (![whitelistIdentifiers containsObject:bundleIdentifier]) return;
    
    [self.mediaKeyAppList removeObject:app];
    [self.mediaKeyAppList insertObject:app atIndex:0];
    [self mediaKeyAppListChanged];
}

-(void)mediaKeyAppListChanged;
{
    if (self.mediaKeyAppList.count == 0) return;

    NSRunningApplication *myTopApp = [self.mediaKeyAppList objectAtIndex:0];
    NSRunningApplication *myApp = [NSRunningApplication currentApplication];
    
    [self setShouldInterceptMediaKeyEvents:[myTopApp isEqual:myApp]];
}


@end
