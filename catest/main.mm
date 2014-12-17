// -------------------------------------------------------------------------------
// CoreAudio continuous play test
// (c) 2014 by Arthur Langereis (@zenmumbler)
// created: 2014-12-07
//
// As part of my efforts for stardazed and to create a Mac OS X version of
// Handmade Hero.
//
// compile with:
// clang++ -std=c++11 -stdlib=libc++ -framework Cocoa -framework CoreAudio catest.mm -o catest
// then run:
// ./catest
// -------------------------------------------------------------------------------

#include <thread>
#include <chrono>
#include <algorithm>
#include <cstring>
#include <cmath>
#include <cassert>

#import <Cocoa/Cocoa.h>
#import <AudioUnit/AudioUnit.h>
#import <IOKit/hid/IOHIDLib.h>

struct SoundState {
	float toneFreq, volume;
	float sampleRate, frameOffset;
	float squareWaveSign;
	AudioBuffer leBuffer;
};

static bool running;
static SoundState soundState;
static AudioUnit auUnit;
static IOHIDManagerRef hidManager;


// capture all the app objects so ARC won't deallocate them immediately
@class HHAppDelegate;
@class HHWindowDelegate;

static HHAppDelegate *appDelegate;
static NSWindow *mainWindow;
static HHWindowDelegate *winDelegate;

@interface HHAppDelegate : NSObject<NSApplicationDelegate> {}
@end
@implementation HHAppDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
	// Cocoa will kill your app on the spot if you don't stop it
	// So if you want to do anything beyond your main loop then include this method.
	running = false;
	return NSTerminateCancel;
}
@end


@interface HHWindowDelegate : NSObject<NSWindowDelegate> {}
@end
@implementation HHWindowDelegate
- (BOOL)windowShouldClose:(id)sender {
	running = false;
	return NO;
}
@end

namespace X360Button {
	enum Mask {
		None          = 0x0000,
		DPadUp        = 0x0001,
		DPadDown      = 0x0002,
		DPadLeft      = 0x0004,
		DPadRight     = 0x0008,
		Start         = 0x0010,
		Back          = 0x0020,
		LeftThumb     = 0x0040,
		RightThumb    = 0x0080,
		LeftShoulder  = 0x0100,
		RightShoulder = 0x0200,
		A = 0x1000,
		B = 0x2000,
		X = 0x4000,
		Y = 0x8000,
		Home = 0x0800 // not present in XINPUT_GAMEPAD
	};
}

// from XInput.h
static const int XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE = 7849;
static const int XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE = 8689;

struct X360ControllerState {
	float thumbLeftX, thumbLeftY;    // -1.0 .. 1.0
	float thumbRightX, thumbRightY;
	float triggerLeft, triggerRight; // 0.0 .. 1.0
	uint32_t buttons;
	
	constexpr bool pressed(X360Button::Mask button) const {
		return (buttons & button);
	};
};

static X360ControllerState controllerState;


struct XINPUT_GAMEPAD {
	uint16_t wButtons;
	uint8_t bLeftTrigger;
	uint8_t bRightTrigger;
	int16_t sThumbLX;
	int16_t sThumbLY;
	int16_t sThumbRX;
	int16_t sThumbRY;
};


static void HIDX360Action(void* context, IOReturn result, void* sender, IOHIDValueRef value) {
	IOHIDElementRef element = IOHIDValueGetElement(value);
	if (CFGetTypeID(element) != IOHIDElementGetTypeID()) {
		return;
	}
	
	int usage = IOHIDElementGetUsage(element);
	CFIndex elementValue = IOHIDValueGetIntegerValue(value);
	
	if (usage == 50) {
		printf("Left %lu\n", elementValue);
	}
	else if (usage == 53) {
		printf("Right %lu\n", elementValue);
	}
	else if (usage > 47) {
		float normValue = elementValue;
		float deadZone = usage < 50 ? XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE : XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE;
		
		if (normValue < 0) {
			normValue = std::min(0.0f, normValue + deadZone) / (32768.f - deadZone);
		}
		else {
			normValue = std::max(0.0f, normValue - deadZone) / (32767.f - deadZone);
		}
		
		switch (usage) {
			case 48: controllerState.thumbLeftX = normValue; break;
			case 49:
				controllerState.thumbLeftY = normValue;
				soundState.toneFreq = 532.2 + (normValue * 261.6);
				break;
			case 51: controllerState.thumbRightX = normValue; break;
			case 52: controllerState.thumbRightY = normValue; break;
		}
	}
	else {
		X360Button::Mask m = X360Button::None;
		
		switch (usage) {
			case  1: m = X360Button::A; break;
			case  2: m = X360Button::B; break;
			case  3: m = X360Button::X; break;
			case  4: m = X360Button::Y; break;
			case  5: m = X360Button::LeftShoulder; break;
			case  6: m = X360Button::RightShoulder; break;
			case  7: m = X360Button::LeftThumb; break;
			case  8: m = X360Button::RightThumb; break;
			case  9: m = X360Button::Start; break;
			case 10: m = X360Button::Back; break;
			case 11: m = X360Button::Home; break;
			case 12: m = X360Button::DPadUp; break;
			case 13: m = X360Button::DPadDown; break;
			case 14: m = X360Button::DPadLeft; break;
			case 15: m = X360Button::DPadRight; break;
			default: break;
		}
		
		if (elementValue)
			controllerState.buttons |= m;
		else
			controllerState.buttons &= ~m;
	}
}


static void HIDDeviceAdded(void* context, IOReturn result, void* sender, IOHIDDeviceRef device) {
	CFStringRef manufacturer = (CFStringRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDManufacturerKey));
	CFStringRef product = (CFStringRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));

	CFNumberRef vendorIDRef = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
	CFNumberRef productIDRef = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));

	int vendorID, productID;
	CFNumberGetValue(vendorIDRef, kCFNumberIntType, &vendorID);
	CFNumberGetValue(productIDRef, kCFNumberIntType, &productID);

	CFNumberRef usageRef = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDPrimaryUsageKey));
	CFNumberRef usagePageRef = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey));

	uint32_t usage, usagePage;
	CFNumberGetValue(usageRef, kCFNumberIntType, &usage);
	CFNumberGetValue(usagePageRef, kCFNumberIntType, &usagePage);

	NSLog(@"Device detected: %@ %@, %d %d", manufacturer, product, usage, usagePage);

	NSArray *elements = (__bridge_transfer NSArray *)IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);

	for (id element in elements) {
		IOHIDElementRef elemRef = (__bridge IOHIDElementRef)element;
		IOHIDElementType elemType = IOHIDElementGetType(elemRef);
		IOHIDElementCookie cookie = IOHIDElementGetCookie(elemRef);
		
		switch(elemType) {
			case kIOHIDElementTypeInput_Misc:
				printf("[misc] ");
				break;

			case kIOHIDElementTypeInput_Button:
				printf("[button] ");
				break;

			case kIOHIDElementTypeInput_Axis:
				printf("[axis] ");
				break;

			default:
				continue;
		}
		
		printf("(%d) ", cookie);
		
		uint32_t reportSize = IOHIDElementGetReportSize(elemRef);
		uint32_t reportCount = IOHIDElementGetReportCount(elemRef);
		if ((reportSize * reportCount) > 64) {
			printf("report too big? %d\n", reportSize * reportCount);
			continue;
		}
		
		uint32_t usagePage = IOHIDElementGetUsagePage(elemRef);
		uint32_t usage = IOHIDElementGetUsage(elemRef);
		if (!usagePage || !usage) {
			printf("usagePage or usage is 0 %d, %d", usagePage, usage);
			continue;
		}
		if (-1 == usage) {
			printf("usage == -1\n");
			continue;
		}
		
		CFIndex logicalMin = IOHIDElementGetLogicalMin(elemRef);
		CFIndex logicalMax = IOHIDElementGetLogicalMax(elemRef);
		
		printf("page/usage = %d:%d  min/max = (%ld, %ld)\n", usagePage, usage, logicalMin, logicalMax);
	}
	
	if (vendorID == 1118 && productID == 654) {
		printf("X360 Controller\n");
		if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) == kIOReturnSuccess) {
			IOHIDDeviceRegisterInputValueCallback(device, HIDX360Action, nullptr);
		}
		else {
			// wrongness
		}
	}
	else {
		printf("Unrecognized controller\n");
	}
	
	CFRelease(manufacturer);
	CFRelease(product);
}


static void HIDDeviceRemoved(void* context, IOReturn result, void* sender, IOHIDDeviceRef device) {
	CFStringRef manufacturer = (CFStringRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDManufacturerKey));
	CFStringRef product = (CFStringRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));

	NSLog(@"Device removed: %@ %@", manufacturer, product);

	CFRelease(manufacturer);
	CFRelease(product);
}


static void initControllers() {
	hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	
	NSArray* criteria = @[
		@{	(NSString*)CFSTR(kIOHIDDeviceUsagePageKey):
				[NSNumber numberWithInt:kHIDPage_GenericDesktop],
			(NSString*)CFSTR(kIOHIDDeviceUsageKey):
				[NSNumber numberWithInt:kHIDUsage_GD_Joystick]
		},
		@{	(NSString*)CFSTR(kIOHIDDeviceUsagePageKey):
				[NSNumber numberWithInt:kHIDPage_GenericDesktop],
			(NSString*)CFSTR(kIOHIDDeviceUsageKey):
				[NSNumber numberWithInt:kHIDUsage_GD_GamePad]
		},
		@{	(NSString*)CFSTR(kIOHIDDeviceUsagePageKey):
				[NSNumber numberWithInt:kHIDPage_GenericDesktop],
			(NSString*)CFSTR(kIOHIDDeviceUsageKey):
				[NSNumber numberWithInt:kHIDUsage_GD_MultiAxisController]
		}
	];
	
	IOHIDManagerSetDeviceMatchingMultiple(hidManager, (__bridge CFArrayRef)criteria);
	IOHIDManagerRegisterDeviceMatchingCallback(hidManager, HIDDeviceAdded, nullptr);
	IOHIDManagerRegisterDeviceRemovalCallback(hidManager, HIDDeviceRemoved, nullptr);
	IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
}


static void createWindow() {
	NSRect frame = NSMakeRect(0, 0, (CGFloat)1024, (CGFloat)768);
	
	mainWindow = [[NSWindow alloc]
				  initWithContentRect: frame
				  styleMask: NSTitledWindowMask | NSClosableWindowMask
				  backing: NSBackingStoreBuffered
				  defer: NO
				  ];
	[mainWindow setTitle: @"Handmade Hero"];
	[mainWindow setAcceptsMouseMovedEvents: YES];
	[mainWindow setOpaque: YES];
	[mainWindow center];
	
//	mainView = [[HHView alloc] initWithFrame:frame];
//	[mainWindow setContentView: mainView];
	
	winDelegate = [[HHWindowDelegate alloc] init];
	[mainWindow setDelegate: winDelegate];
	
	[mainWindow makeKeyAndOrderFront: nil];
}


static void setupMenuBar() {
	NSMenu* menubar = [NSMenu new];
 
	NSMenuItem* appMenuItem = [NSMenuItem new];
	[menubar addItem:appMenuItem];
 
	[NSApp setMainMenu:menubar];
 
	NSMenu* appMenu = [NSMenu new];
 
//	NSString* toggleFullScreenTitle = @"Toggle Full Screen";
//	NSMenuItem* toggleFullScreenMenuItem = [[NSMenuItem alloc] initWithTitle:toggleFullScreenTitle
//																	  action:@selector(toggleFullScreen:)
//															   keyEquivalent:@"f"];
//	[appMenu addItem:toggleFullScreenMenuItem];
 
	NSString* quitTitle = @"Quit ";
	NSMenuItem* quitMenuItem = [[NSMenuItem alloc] initWithTitle:quitTitle
														  action:@selector(terminate:)
												   keyEquivalent:@"q"];
	[appMenu addItem:quitMenuItem];
 
	[appMenuItem setSubmenu:appMenu];
}


static void initApp() {
	NSApplication* app = [NSApplication sharedApplication];
	[app setActivationPolicy: NSApplicationActivationPolicyRegular];
	
	appDelegate = [[HHAppDelegate alloc] init];
	[app setDelegate: appDelegate];
	
	setupMenuBar();

//	// -- allow relative paths to work from the Contents/Resources directory
//	const char *resourcePath = [[[NSBundle mainBundle] resourcePath] UTF8String];
//	chdir(resourcePath);
	
	running = true;
	[app finishLaunching];
}


static void frame() {
	@autoreleasepool {
		NSEvent* ev;
		do {
			ev = [NSApp nextEventMatchingMask: NSAnyEventMask
									untilDate: nil
									   inMode: NSDefaultRunLoopMode
									  dequeue: YES];
			if (ev) {
				if ([ev type] == NSKeyDown) {
					uint16_t keyCode = [ev keyCode];

					if (keyCode == 6) { // Z
						if (soundState.toneFreq > 60.f) {
							soundState.toneFreq -= 8.f;
						}
					}
					else if (keyCode == 7) { // X
						if (soundState.toneFreq < 4000.f) {
							soundState.toneFreq += 8.f;
						}
					}
					else {
						[NSApp sendEvent: ev];
					}
					
					printf("%f\n", soundState.toneFreq);
				}
				else {
					[NSApp sendEvent: ev];
				}
			}
		} while (ev);
	}
}


static void genAudio(SoundState& state, AudioBuffer& buffer, uint32_t numSamples) {
	// calc the samples per up/down portion of each square wave (with 50% period)
	auto framesPerTransition = state.sampleRate / state.toneFreq;
	
	// sample to output at current state
	float sample = state.squareWaveSign * state.volume;
	
	auto bufferPos = static_cast<float*>(buffer.mData);
	auto frameOffset = state.frameOffset;
	
	while (numSamples) {
		// changing the frequency may cause the offset to exceed the transition size
		if (frameOffset > framesPerTransition) {
			frameOffset = 0;
		}

		// calc rounded frames to generate and accumulate fractional error
		uint32_t frames;
		auto needFrames = static_cast<uint32_t>(std::round(framesPerTransition - frameOffset));

		// if, after rounding, we end up with 0 frames, we flip the sample
		// and set framesNeeded to 1 full transition block
		if (needFrames == 0) {
			needFrames = framesPerTransition;
			sample = -sample;
		}
		
		frameOffset -= framesPerTransition - needFrames;
		
		// we may be at the end of the buffer, if so, place offset at location in wave and clip
		if (needFrames > numSamples) {
			frameOffset += numSamples;
			frames = numSamples;
		}
		else {
			frames = needFrames;
		}
		numSamples -= frames;
		
		// simply put the samples in
		for (int x = 0; x < frames; ++x) {
			*bufferPos++ = sample;
			*bufferPos++ = sample;
		}
		
		// flip sign of wave unless we were cut off prematurely
		if (needFrames == frames)
			sample = -sample;
	}
	
	// save square wave state for next callback
	if (sample > 0)
		state.squareWaveSign = 1;
	else
		state.squareWaveSign = -1;
	state.frameOffset = frameOffset;
}


OSStatus auCallback(void *inRefCon,
				AudioUnitRenderActionFlags *ioActionFlags,
				const AudioTimeStamp *inTimeStamp,
				UInt32 inBusNumber,
				UInt32 inNumberFrames,
				AudioBufferList *ioData)
{
	auto soundState = static_cast<SoundState*>(inRefCon);
	genAudio(*soundState, ioData->mBuffers[0], inNumberFrames);

	return noErr;
}


static void initAudio() {
	// stereo interleaved linear PCM audio data at 44.1kHz in float format
	AudioStreamBasicDescription streamDesc {};
	streamDesc.mSampleRate = 44100.0f;
	streamDesc.mFormatID = kAudioFormatLinearPCM;
	streamDesc.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
	streamDesc.mChannelsPerFrame = 2;
	streamDesc.mFramesPerPacket  = 1;
	streamDesc.mBitsPerChannel   = sizeof(float) * 8;
	streamDesc.mBytesPerFrame    = sizeof(float) * streamDesc.mChannelsPerFrame;
	streamDesc.mBytesPerPacket   = streamDesc.mBytesPerFrame * streamDesc.mFramesPerPacket;
	
	// our persistent state for sound playback
	soundState.toneFreq = 261.6 * 2; // 261.6 ~= Middle C frequency
	soundState.volume = 0.07; // don't crank this up and expect your ears to still function
	soundState.sampleRate = streamDesc.mSampleRate;
	soundState.frameOffset = 0;
	soundState.squareWaveSign = 1; // sign of the current part of the square wave
	
	soundState.leBuffer.mNumberChannels = 2;
	soundState.leBuffer.mDataByteSize = 2 * streamDesc.mSampleRate * sizeof(float); // 1s
	soundState.leBuffer.mData = calloc(1, soundState.leBuffer.mDataByteSize);
	
	OSStatus err;
	
	AudioComponentDescription acd;
	acd.componentType         = kAudioUnitType_Output;
	acd.componentSubType      = kAudioUnitSubType_DefaultOutput;
	acd.componentManufacturer = kAudioUnitManufacturer_Apple;
	
	AudioComponent outputComponent = AudioComponentFindNext(NULL, &acd);
	
	err = AudioComponentInstanceNew(outputComponent, &auUnit);
	if (! err) {
		err = AudioUnitInitialize(auUnit);
		
		err = AudioUnitSetProperty(auUnit,
								   kAudioUnitProperty_StreamFormat,
								   kAudioUnitScope_Input,
								   0,
								   &streamDesc,
								   sizeof(streamDesc));
		
		AURenderCallbackStruct cb;
		cb.inputProc       = &auCallback;
		cb.inputProcRefCon = &soundState;
		
		err = AudioUnitSetProperty(auUnit,
								   kAudioUnitProperty_SetRenderCallback,
								   kAudioUnitScope_Global,
								   0,
								   &cb,
								   sizeof(cb));
		
		AudioOutputUnitStart(auUnit);
	}
}


int main(int argc, const char * argv[]) {
	initApp();
	createWindow();
	initAudio();
	initControllers();
	
	while (running) {
		frame();
		std::this_thread::sleep_for(std::chrono::milliseconds{16});
	}

	// be nice even it doesn't really matter at this point
	if (auUnit) {
		AudioOutputUnitStop(auUnit);
		AudioUnitUninitialize(auUnit);
		AudioComponentInstanceDispose(auUnit);
	}
}
