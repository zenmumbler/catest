// -------------------------------------------------------------------------------
// CoreAudio continuous play test
// (c) 2014 by Arthur Langereis (@zenmumbler)
// created: 2014-12-07
//
// As part of my efforts for stardazed and to create a Mac OS X version of
// Handmade Hero.
//
// compile with:
// clang++ -std=c++11 -stdlib=libc++ -framework AudioToolbox catest.cpp -o catest
// then run:
// ./catest
// -------------------------------------------------------------------------------

#include <thread>
#include <chrono>
#include <cstring>
#include <cmath>
#include <cassert>

#import <Cocoa/Cocoa.h>
#import <AudioUnit/AudioUnit.h>

struct SoundState {
	float toneFreq, volume;
	float sampleRate, frameOffset;
	float squareWaveSign;
	AudioBuffer leBuffer;
};

static bool running;
static SoundState soundState;
static AudioUnit auUnit;


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


void setupMenuBar() {
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


void initApp() {
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


void frame() {
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

					if (keyCode == 12) {
						if (soundState.toneFreq > 60.f) {
							soundState.toneFreq -= 8.f;
						}
					}
					else if (keyCode == 14) {
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


void genAudio(SoundState& state, AudioBuffer& buffer, uint32_t numSamples) {
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


void initAudio() {
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
	soundState.toneFreq = 261.6 * 1; // 261.6 ~= Middle C frequency
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
