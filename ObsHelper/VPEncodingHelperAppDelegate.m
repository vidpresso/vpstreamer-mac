//
//  AppDelegate.m
//  ObsHelper
//
//  Created by Pauli Ojala on 23/06/16.
/******************************************************************************
    Copyright (C) 2016-18 by Vidpresso Inc.
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
******************************************************************************/

#import "VPEncodingHelperAppDelegate.h"
#import "VPObsStreamer.h"
#import "../VDPAudioUtils/VDPAudioMixer.h"

#include <obs.h>
#include "vp_obs_source.h"
#include "vp_obs_audio_source.h"

#import <CoreAudio/CoreAudio.h>


#define TEST_LOCAL_RECORDING_AND_MIXING 0


extern void test_sinewave_register();

static VPObsStreamer *g_obsStreamer = NULL;



@interface VPEncodingHelperAppDelegate ()

@property (weak) IBOutlet NSWindow *window;

@property (nonatomic) NSSize videoSize;

@property (atomic) BOOL isPlaying;
@property (atomic) BOOL didTerminate;

@property (atomic) double lastIconUpdateT;

- (void)vpSourceReceivedData;
@end


static void vpOBSSourceDataCb(void *data)
{
    VPEncodingHelperAppDelegate *self = (__bridge VPEncodingHelperAppDelegate *)data;
    [self vpSourceReceivedData];
}


/*
static CFArrayRef createListOfAudioOutputDevices()
{
    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };
    
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize);
    if(kAudioHardwareNoError != status) {
        fprintf(stderr, "AudioObjectGetPropertyDataSize (kAudioHardwarePropertyDevices) failed: %i\n", status);
        return NULL;
    }
    
    UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
    
    AudioDeviceID *audioDevices = malloc(dataSize);
    if(NULL == audioDevices) {
        fputs("Unable to allocate memory", stderr);
        return NULL;
    }
    
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize, audioDevices);
    if(kAudioHardwareNoError != status) {
        fprintf(stderr, "AudioObjectGetPropertyData (kAudioHardwarePropertyDevices) failed: %i\n", status);
        free(audioDevices), audioDevices = NULL;
        return NULL;
    }
    
    CFMutableArrayRef outputDeviceArray = CFArrayCreateMutable(kCFAllocatorDefault, deviceCount, &kCFTypeArrayCallBacks);
    
    // Iterate through all the devices and determine which are output-capable
    propertyAddress.mScope = kAudioDevicePropertyScopeOutput;
    for(UInt32 i = 0; i < deviceCount; ++i) {
        // Query device UID
        CFStringRef deviceUID = NULL;
        dataSize = sizeof(deviceUID);
        propertyAddress.mSelector = kAudioDevicePropertyDeviceUID;
        status = AudioObjectGetPropertyData(audioDevices[i], &propertyAddress, 0, NULL, &dataSize, &deviceUID);
        if(kAudioHardwareNoError != status) {
            fprintf(stderr, "AudioObjectGetPropertyData (kAudioDevicePropertyDeviceUID) failed: %i\n", status);
            continue;
        }
        
        // Query device name
        CFStringRef deviceName = NULL;
        dataSize = sizeof(deviceName);
        propertyAddress.mSelector = kAudioDevicePropertyDeviceNameCFString;
        status = AudioObjectGetPropertyData(audioDevices[i], &propertyAddress, 0, NULL, &dataSize, &deviceName);
        if(kAudioHardwareNoError != status) {
            fprintf(stderr, "AudioObjectGetPropertyData (kAudioDevicePropertyDeviceNameCFString) failed: %i\n", status);
            continue;
        }
        
        // Query device manufacturer
        CFStringRef deviceManufacturer = NULL;
        dataSize = sizeof(deviceManufacturer);
        propertyAddress.mSelector = kAudioDevicePropertyDeviceManufacturerCFString;
        status = AudioObjectGetPropertyData(audioDevices[i], &propertyAddress, 0, NULL, &dataSize, &deviceManufacturer);
        if(kAudioHardwareNoError != status) {
            fprintf(stderr, "AudioObjectGetPropertyData (kAudioDevicePropertyDeviceManufacturerCFString) failed: %i\n", status);
            continue;
        }
        
        NSLog(@"... device '%@'", (__bridge NSString *)deviceName);
        
        // Determine if the device has channels of the type we want (determined by propertyAddress scope)
        dataSize = 0;
        propertyAddress.mSelector = kAudioDevicePropertyStreamConfiguration;
        status = AudioObjectGetPropertyDataSize(audioDevices[i], &propertyAddress, 0, NULL, &dataSize);
        if(kAudioHardwareNoError != status) {
            fprintf(stderr, "AudioObjectGetPropertyDataSize (kAudioDevicePropertyStreamConfiguration) failed: %i\n", status);
            continue;
        }
        
        AudioBufferList *bufferList = malloc(dataSize);
        
        status = AudioObjectGetPropertyData(audioDevices[i], &propertyAddress, 0, NULL, &dataSize, bufferList);
        NSLog(@" ... 2: numbuffers %d", bufferList->mNumberBuffers);
        if(kAudioHardwareNoError != status || 0 == bufferList->mNumberBuffers) {
            if(kAudioHardwareNoError != status)
                fprintf(stderr, "AudioObjectGetPropertyData (kAudioDevicePropertyStreamConfiguration) failed: %i\n", status);
            free(bufferList), bufferList = NULL;
            continue;
        }
        
        free(bufferList), bufferList = NULL;
        
        // Add a dictionary for this device to the array of input devices
        CFStringRef keys    []  = { CFSTR("deviceUID"),     CFSTR("deviceName"),    CFSTR("deviceManufacturer") };
        CFStringRef values  []  = { deviceUID,              deviceName,             deviceManufacturer };
        
        CFDictionaryRef deviceDictionary = CFDictionaryCreate(kCFAllocatorDefault,
                                                              (const void **)keys,
                                                              (const void **)values,
                                                              3,
                                                              &kCFTypeDictionaryKeyCallBacks,
                                                              &kCFTypeDictionaryValueCallBacks);
        
        
        CFArrayAppendValue(outputDeviceArray, deviceDictionary);
        
        CFRelease(deviceDictionary), deviceDictionary = NULL;
    }
    
    free(audioDevices), audioDevices = NULL;
    
    return outputDeviceArray;
}
 */


@implementation VPEncodingHelperAppDelegate

- (void)initializeObsLibraries
{
    int ret;
    
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    
    chdir([bundlePath stringByDeletingLastPathComponent].UTF8String);
    
    NSFileManager *fm = [[NSFileManager alloc] init];
    NSString *currentPath = [fm currentDirectoryPath];
    
    NSLog(@"current dir is: %@\nbundlepath: %@", currentPath, bundlePath);

    obs_startup("en-US", NULL, NULL);
    
    NSLog(@"obs startup done");
    /*
    obs_add_module_path([bundlePath stringByAppendingPathComponent:@"Contents/obs-plugins"].UTF8String, [bundlePath stringByAppendingPathComponent:@"Contents/data/obs-plugins/%module%"].UTF8String);
    
    obs_add_module_path([currentPath stringByAppendingPathComponent:@"obs-plugins"].UTF8String, [currentPath stringByAppendingPathComponent:@"data/obs-plugins/%module%"].UTF8String);

        obs_add_module_path([currentPath stringByAppendingPathComponent:@"../obs-plugins"].UTF8String, [currentPath stringByAppendingPathComponent:@"../data/obs-plugins/%module%"].UTF8String);
    // /data/obs-plugins/%module%
    */
    obs_load_all_modules();
    
    NSLog(@"obs load modules done");
    
    vp_source_register(vpOBSSourceDataCb, (__bridge void *)(self));
    vp_audio_source_register();
    test_sinewave_register();
    
    NSLog(@"obs vpSource register done");
    
    g_obsStreamer = [[VPObsStreamer alloc] init];
    
    NSLog(@"%s done", __func__);
    
    
    struct obs_audio_info oai;
    memset(&oai, 0, sizeof(oai));
    
    oai.samples_per_sec = 48000;
    oai.speakers = 2;
    
    if ((ret = obs_reset_audio(&oai)) != 0) {
        NSLog(@"** %s: reset_audio failed, error %d", __func__, ret);
    }
}

- (void)_resetObsVideo
{
    int ret;

    struct obs_video_info ovi;
    memset(&ovi, 0, sizeof(ovi));
    
    ovi.graphics_module = "libobs-opengl";
    
    ovi.fps_num = 30;
    ovi.fps_den = 1;
    
    ovi.base_width = _videoSize.width;
    ovi.base_height = _videoSize.height;
    
    ovi.output_width = _videoSize.width;
    ovi.output_height = _videoSize.height;
    ovi.output_format = VIDEO_FORMAT_RGBA;
    
    if ((ret = obs_reset_video(&ovi)) != 0) {
        NSLog(@"** %s: obs_reset_video failed, error %d", __func__, ret);
    } else {
        NSLog(@"%s reset complete", __func__);
    }
    
    g_obsStreamer.videoSize = _videoSize;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notif
{
    //NSArray *audioDevs = (NSArray *)CFBridgingRelease(createListOfAudioOutputDevices());
    //NSLog(@"audio output devices: %@", audioDevs);

    [self initializeObsLibraries];

    NSLog(@"Obs initialized %d, version %d", obs_initialized(), obs_get_version());
    
    
    _videoSize = NSMakeSize(1280, 720);
    
    // TESTING: Pauli's youtube url
    //g_obsStreamer.serverUrl = @"rtmp://a.rtmp.youtube.com/live2";
    //g_obsStreamer.serverKey = @"dh5q-g412-mbpz-2t0u";
    
    
    NSLog(@"process args: %@", [NSProcessInfo processInfo].arguments);
    
    NSArray *streamingDestinations = [NSArray array];
    
    enum {
        kArgState_serverDestinations = 1,
        //kArgState_serverUrl = 1,
        //kArgState_serverKey,
        kArgState_videoW,
        kArgState_videoH,
        kArgState_audioSyncOffset,
        kArgState_audioBitrate,
        kArgState_videoBitrate,
        kArgState_keyIntervalSecs,
        kArgState_h264ProfileName,
        kArgState_h264PresetName,
        kArgState_h264EncoderOptionsString,
        kArgState_mixedAudioSyncOffset_local,
        kArgState_mixedAudioSyncOffset_remote,
        kArgState_mixedAudioVolume_local,
    };
    NSInteger state = 0;
    NSArray *args = [NSProcessInfo processInfo].arguments;
    args = [args subarrayWithRange:NSMakeRange(1, args.count - 1)];
    for (NSString *arg in args) {
        
        switch (state) {
            default:
                /*if ([arg isEqualToString:@"--server-url"]) {
                    state = kArgState_serverUrl;
                } else if ([arg isEqualToString:@"--server-key"]) {
                    state = kArgState_serverKey;
                } else*/ if ([arg isEqualToString:@"--streaming-destinations"]) {
                    state = kArgState_serverDestinations;
                } else if ([arg isEqualToString:@"--video-w"]) {
                    state = kArgState_videoW;
                } else if ([arg isEqualToString:@"--video-h"]) {
                    state = kArgState_videoH;
                } else if ([arg isEqualToString:@"--audio-sync-offset"]) {
                    state = kArgState_audioSyncOffset;
                
                } else if ([arg isEqualToString:@"--audio-bitrate"]) {
                    state = kArgState_audioBitrate;
                } else if ([arg isEqualToString:@"--video-bitrate"]) {
                    state = kArgState_videoBitrate;
                } else if ([arg isEqualToString:@"--video-key-interval-secs"]) {
                    state = kArgState_keyIntervalSecs;
                } else if ([arg isEqualToString:@"--h264-profile-name"]) {
                    state = kArgState_h264ProfileName;
                } else if ([arg isEqualToString:@"--h264-preset-name"]) {
                    state = kArgState_h264PresetName;
                } else if ([arg isEqualToString:@"--h264-encoder-options"]) {
                    state = kArgState_h264EncoderOptionsString;

                } else if ([arg isEqualToString:@"--mixed-audio-sync-offset-local"]) {
                    state = kArgState_mixedAudioSyncOffset_local;
                } else if ([arg isEqualToString:@"--mixed-audio-sync-offset-remote"]) {
                    state = kArgState_mixedAudioSyncOffset_remote;
                } else if ([arg isEqualToString:@"--use-vidpresso-audio"]) {
                    g_obsStreamer.useVidpressoAudioInput = YES;
                    g_obsStreamer.mixLocalInputIntoVidpressoAudio = NO;
                    NSLog(@"... selecting vp audio");
                } else if ([arg isEqualToString:@"--use-system-audio"]) {
                    g_obsStreamer.useVidpressoAudioInput = NO;
                    g_obsStreamer.mixLocalInputIntoVidpressoAudio = NO;
                    NSLog(@"... selecting system audio");
                }  else if ([arg isEqualToString:@"--use-mixed-audio"]) {
                    g_obsStreamer.useVidpressoAudioInput = YES;
                    g_obsStreamer.mixLocalInputIntoVidpressoAudio = YES;
                    NSLog(@"... selecting mixed vp + system audio");
                } else if ([arg isEqualToString:@"--mixed-audio-volume-local"]) {
                    state = kArgState_mixedAudioVolume_local;
                } else {
                    NSLog(@"** unknown arg: '%@'", arg);
                }
                break;
                
            /*case kArgState_serverUrl:
                g_obsStreamer.serverUrl = arg;
                state = 0;
                break;

            case kArgState_serverKey:
                g_obsStreamer.serverKey = arg;
                state = 0;
                break;
             */
            case kArgState_serverDestinations: {
                NSData *data = [arg dataUsingEncoding:NSUTF8StringEncoding];
                NSError *jsonErr = nil;
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
                if ( !obj || ![obj isKindOfClass:[NSArray class]]) {
                    NSLog(@"** could not decode 'streaming-destinations': %@", jsonErr);
                } else {
                    streamingDestinations = obj;
                }
                state = 0;
                break;
            }
                
            case kArgState_videoW: {
                int v = [arg intValue];
                if (v > 0 && v < 6000) {
                    _videoSize.width = v;
                }
                state = 0;
                break;
            }
                
            case kArgState_videoH: {
                int v = [arg intValue];
                if (v > 0 && v < 6000) {
                    _videoSize.height = v;
                }
                state = 0;
                break;
            }
                
            case kArgState_audioBitrate: {
                int v = [arg intValue];
                g_obsStreamer.audioBitrate = v;
                NSLog(@"using audio bitrate %d", v);
                state = 0;
                break;
            }
                
            case kArgState_videoBitrate: {
                int v = [arg intValue];
                g_obsStreamer.videoBitrate = v;
                state = 0;
                break;
            }

            case kArgState_keyIntervalSecs: {
                int v = [arg intValue];
                g_obsStreamer.keyIntervalSecs = v;
                state = 0;
                break;
            }

            case kArgState_h264ProfileName: {
                g_obsStreamer.h264ProfileName = arg;
                state = 0;
                break;
            }
                
            case kArgState_h264PresetName: {
                g_obsStreamer.h264PresetName = arg;
                state = 0;
                break;
            }
                
            case kArgState_h264EncoderOptionsString: {
                g_obsStreamer.h264EncoderOptionsString = arg;
                state = 0;
                break;
            }
                
            case kArgState_audioSyncOffset: {
                double v = [arg doubleValue];
                if (isfinite(v)) {
                    g_obsStreamer.audioSyncOffsetInSecs = v / 1000.0;
                }
                state = 0;
                break;
            }

            case kArgState_mixedAudioSyncOffset_local: {
                double v = [arg doubleValue];
                if (isfinite(v) && v >= 0.0) {
                    g_vpAudioSourceSyncOffset_local = v / 1000.0;
                    
                    NSLog(@"local audio sync offset set to %.3f", v/1000.0);
                }
                state = 0;
                break;
            }

            case kArgState_mixedAudioSyncOffset_remote: {
                double v = [arg doubleValue];
                if (isfinite(v) && v >= 0.0) {
                    g_vpAudioSourceSyncOffset_remote = v / 1000.0;
                    
                    NSLog(@"remote audio sync offset set to %.3f", v/1000.0);
                }
                state = 0;
                break;
            }
                
            case kArgState_mixedAudioVolume_local: {
                double v = [arg doubleValue];
                if (isfinite(v) && v >= 0.0) {
                    g_vpAudioSourceVolume_local = v;
                    
                    NSLog(@"local audio volume set to %.3f", v);
                }
                state = 0;
                break;
            }

        }
    }
    
    if (g_obsStreamer.useVidpressoAudioInput && g_obsStreamer.mixLocalInputIntoVidpressoAudio) {
        NSLog(@"using mixed audio with offsets: local %f, remote %f", g_vpAudioSourceSyncOffset_local, g_vpAudioSourceSyncOffset_remote);
        
        g_obsStreamer.audioSyncOffsetInSecs = 0.0;  // clear out this offset since vp audio driver will do delay
    }

#if TEST_LOCAL_RECORDING_AND_MIXING
    streamingDestinations = [streamingDestinations arrayByAddingObject:@{
                                                @"url": @"rtmp://a.rtmp.youtube.com/live2",
                                                @"key": @"dh5q-g412-mbpz-2t0u",
                                                                         }];
    
    g_obsStreamer.useVidpressoAudioInput = YES;
    g_obsStreamer.mixLocalInputIntoVidpressoAudio = YES;
    
#endif
    

    NSMutableArray *servers = [NSMutableArray array];
    for (NSDictionary *obj in streamingDestinations) {
        if (obj[@"url"]) {
            VPObsServerDestination *server = [[VPObsServerDestination alloc] init];
            server.url = obj[@"url"];
            server.key = obj[@"key"];
            [servers addObject:server];
        } else {
            NSLog(@"** warning: invalid object in streaming destinations: %@", obj);
        }
    }
    g_obsStreamer.serverDestinations = servers;
    
    if (g_obsStreamer.serverDestinations.count < 1) {
        NSLog(@"warning: no streaming destinations, will only record to disk");
    }
    
    
    
    
    //NSLog(@"parsed args, server now '%@', key '%@', using vidpresso audio input %d", g_obsStreamer.serverUrl, g_obsStreamer.serverKey, g_obsStreamer.useVidpressoAudioInput);
    
    NSLog(@"parsed args: streaming server destinations now %@", g_obsStreamer.serverDestinations);
    
    [g_obsStreamer initObs];
    
    NSLog(@"setting video size to %@", NSStringFromSize(_videoSize));
    
    [self _resetObsVideo];
    

    [[NSDistributedNotificationCenter defaultCenter]
     addObserver:self selector:@selector(helperConfigChange:)
     name:@"VDPEncodingHelperConfigChangeNotification"
     object:nil];
    
    [[NSDistributedNotificationCenter defaultCenter]
     addObserver:self selector:@selector(helperShouldTerminate:)
     name:@"VDPEncodingHelperShouldTerminateNotification"
     object:nil];
    
    
#if TEST_RENDER_USING_GENPATTERN
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [g_obsStreamer startStreaming];
        self.isPlaying = YES;
    });
    
#endif
}


- (void)helperConfigChange:(NSNotification *)notif
{
    NSString *cmd = notif.userInfo[@"cmd"];
    id value = notif.userInfo[@"value"];

    NSLog(@"helper config change received: cmd '%@', value: %@", cmd, value);

    VDPAudioMixer *mixer = (__bridge VDPAudioMixer *)(g_vpLocalAudioMixerObj);

    if ([cmd isEqualToString:@"setAudioSyncOffset"]) {
        double v = [value doubleValue];
        if (isfinite(v) && v >= 0.0) {
            g_obsStreamer.audioSyncOffsetInSecs = v / 1000.0;
            
            // also set the "remote audio" offset when using mixing
            mixer.channel2AudioDelayInSecs = g_vpAudioSourceSyncOffset_remote = v / 1000.0;
        }
    }
    else if ([cmd isEqualToString:@"setMixedAudioSyncOffset_Local"]) {// @"setAudioLocalInMixSyncOffset"]) {
        double v = [value doubleValue];
        if (isfinite(v) && v >= 0.0) {
            mixer.capturedAudioDelayInSecs = g_vpAudioSourceSyncOffset_local = v / 1000.0;
        }
    }
    else if ([cmd isEqualToString:@"setMixedAudioSyncOffset_Remote"]) {
        double v = [value doubleValue];
        if (isfinite(v) && v >= 0.0) {
            mixer.channel2AudioDelayInSecs = g_vpAudioSourceSyncOffset_remote = v / 1000.0;
        }
    }
    else if ([cmd isEqualToString:@"setMixedAudioVolume_Local"]) {
        double v = [value doubleValue];
        if (isfinite(v) && v >= 0.0) {
            mixer.capturedAudioVolume = g_vpAudioSourceVolume_local = v;
        }
    }
}

- (void)helperShouldTerminate:(NSNotification *)notif
{
    NSLog(@"%s, stopping now", __func__);
    
    [g_obsStreamer stopStreaming];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

- (void)applicationWillTerminate:(NSNotification *)notif
{
    if ( !self.didTerminate) {
        NSLog(@"%s, terminating now", __func__);
        
        [g_obsStreamer stopStreaming];
        
        obs_shutdown();
        
        self.didTerminate = YES;
        
    }
}


- (void)vpSourceReceivedData
{
    if (self.isPlaying)
        return;
    
    self.isPlaying = YES;
    
    const double delay = 2.0;
    
    NSLog(@"%s -- got first data, will play after %.1f s", __func__, delay);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [g_obsStreamer startStreaming];
    });
    
}

- (void)vpSourceHasNewFrame:(uint8_t *)buf width:(int)w height:(int)h rowBytes:(size_t)rowBytes qtPixelFormat:(uint32_t)qtPxf
{
    double t0 = CACurrentMediaTime();
    
    if (t0 - self.lastIconUpdateT < 1.0)
        return; // --
    
    CGColorSpaceRef cspace = CGColorSpaceCreateDeviceRGB();
    CGContextRef cgCtx = CGBitmapContextCreate(buf, w, h, 8, rowBytes, cspace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef cgImage = CGBitmapContextCreateImage(cgCtx);
    
    NSImage *nsImage = [[NSImage alloc] initWithCGImage:cgImage size:NSMakeSize(w, h)];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp setApplicationIconImage:nsImage];
    });
    
    CGImageRelease(cgImage);
    CGContextRelease(cgCtx);
    CGColorSpaceRelease(cspace);
    
    self.lastIconUpdateT = t0;
}

@end
