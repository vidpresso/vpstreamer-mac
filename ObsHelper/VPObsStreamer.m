//
//  VPObsStreamer.m
//  VidpressoStation
//
//  Created by Pauli Ojala on 27/06/16.
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

#import "VPObsStreamer.h"
#import <obs.h>
#include <util/threading.h>
#include <util/platform.h>
#import "vp_obs_source.h"
#import "vp_obs_audio_source.h"
#import "../VDPAudioUtils/VDPAudioCapture.h"


@implementation VPObsServerDestination
@end


#define MAXSERVICES 8


@interface VPObsStreamer () {
    
    obs_encoder_t *_aacStreaming;
    obs_encoder_t *_h264Streaming;

    obs_source_t *_vpSource;
    obs_source_t *_audioSource_VP;
    obs_source_t *_audioSource_CoreAudio;
    obs_source_t *_activeAudioSource;
    //obs_scene_t *_scene;
    
    //obs_service_t *_service;
    
    // streaming server destinations
    int _numStreams;
    obs_output_t *_streamOutputs[MAXSERVICES];
    obs_service_t *_services[MAXSERVICES];
    
    // recording
    obs_output_t *_fileOutput;
    
    
    NSTimer *_debugUpdateTimer;
    
    VDPAudioCapture *_localAudioCapForMix;
    
    NSString *_pingbackNotifObj;
    NSTimer *_pingbackToMainProcessTimer;
    
    NSString *_latestVideoEncoderSettingsInfo;
}

- (void)outputStarted:(long)outputIndex;
- (void)outputStopped:(long)outputIndex;
- (void)outputReconnecting:(long)outputIndex;
- (void)outputReconnectSuccess:(long)outputIndex;

@property (nonatomic, assign) BOOL isStreaming;
@property (nonatomic, assign) BOOL isRecording;

@end


typedef struct {
    void *streamer;
    long serviceIndex;
} VPObsCallbackData;


static void _output_start_cb(void *data, struct calldata *calldata)
{
    VPObsCallbackData *cbData = (VPObsCallbackData *)data;
    long idx = cbData->serviceIndex;
    VPObsStreamer *self = (__bridge VPObsStreamer *)cbData->streamer;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self outputStarted:idx];
    });
}

static void _output_stop_cb(void *data, struct calldata *calldata)
{
    VPObsCallbackData *cbData = (VPObsCallbackData *)data;
    long idx = cbData->serviceIndex;
    VPObsStreamer *self = (__bridge VPObsStreamer *)cbData->streamer;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self outputStopped:idx];
    });
}

static void _output_reconnect_cb(void *data, struct calldata *calldata)
{
    VPObsCallbackData *cbData = (VPObsCallbackData *)data;
    long idx = cbData->serviceIndex;
    VPObsStreamer *self = (__bridge VPObsStreamer *)cbData->streamer;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self outputReconnecting:idx];
    });
}

static void _output_reconnect_success_cb(void *data, struct calldata *calldata)
{
    VPObsCallbackData *cbData = (VPObsCallbackData *)data;
    long idx = cbData->serviceIndex;
    VPObsStreamer *self = (__bridge VPObsStreamer *)cbData->streamer;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self outputReconnectSuccess:idx];
    });
}



@implementation VPObsStreamer

- (id)init
{
    self = [super init];
    
    self.audioSyncOffsetInSecs = 0.6;
    
    self.useVidpressoAudioInput = YES;
    
    return self;
}

- (void)setAudioSyncOffsetInSecs:(double)audioSyncOffsetInSecs
{
    _audioSyncOffsetInSecs = audioSyncOffsetInSecs;
    
    if (_activeAudioSource) {
        obs_source_set_sync_offset(_activeAudioSource, _audioSyncOffsetInSecs*NSEC_PER_SEC);
    }
}

- (void)initObs
{
#if !TEST_RENDER_USING_GENPATTERN
    if (1) {
        _fileOutput = obs_output_create("ffmpeg_muxer",
                                        "file output", NULL, NULL);
    }
#endif
    
     const char *encoderId = NULL;
     for (size_t i = 0; obs_enum_encoder_types(i, &encoderId); i++) {
         NSLog(@"..encoder %ld: '%s'", i, encoderId);
     }
     
     _aacStreaming = obs_audio_encoder_create("ffmpeg_aac",
                                              "simple aac", NULL, 0, NULL);

    _h264Streaming = obs_video_encoder_create(//"vt_h264_hw",
                                              "obs_x264",
                                              "simple h264 stream", NULL, NULL);
    
    _vpSource = obs_source_create(VP_SOURCE_OBS_ID,
                                  "vidpresso live stream", NULL, NULL);
    
    
    if ((0)) {
        // TESTING: audio generator
        _audioSource_VP = obs_source_create("test_sinewave",
                                         "test sinewave source", NULL, NULL);
    } else {
        _audioSource_VP = obs_source_create(VP_AUDIO_SOURCE_OBS_ID,
                                            "vidpresso audio stream", NULL, NULL);
        
        _audioSource_CoreAudio = obs_source_create("coreaudio_input_capture",
                                             "system input audio stream", NULL, NULL);
        
        obs_source_set_sync_offset(_audioSource_VP, self.audioSyncOffsetInSecs*NSEC_PER_SEC);
        obs_source_set_sync_offset(_audioSource_CoreAudio, self.audioSyncOffsetInSecs*NSEC_PER_SEC);
    }
    
    //_scene = obs_scene_create("simple scene");
    //obs_scene_add(_scene, _vpSource);
    
    _numStreams = MIN(MAXSERVICES, (int)self.serverDestinations.count);
    
    for (int i = 0; i < _numStreams; i++) {
        NSString *outputName = [NSString stringWithFormat:@"streaming output %d", i+1];
        NSString *serviceName = [NSString stringWithFormat:@"streaming service %d", i+1];

        _streamOutputs[i] = obs_output_create("rtmp_output",
                                          outputName.UTF8String, NULL, NULL);
        
        VPObsCallbackData *cbData = calloc(1, sizeof(VPObsCallbackData));
        cbData->serviceIndex = i;
        cbData->streamer = (__bridge void *)(self);
        
        signal_handler_t *sh;
        sh = obs_output_get_signal_handler(_streamOutputs[i]);
        signal_handler_connect(sh, "start", _output_start_cb, cbData);
        signal_handler_connect(sh, "stop", _output_stop_cb, cbData);
        signal_handler_connect(sh, "reconnect", _output_reconnect_cb, cbData);
        signal_handler_connect(sh, "reconnect_success", _output_reconnect_success_cb, cbData);
        
        _services[i] = obs_service_create("rtmp_custom",
                                      serviceName.UTF8String, NULL, NULL);
    }
    
    obs_set_output_source(0, _vpSource);
    
    self.useVidpressoAudioInput = self.useVidpressoAudioInput;
}

- (void)setUseVidpressoAudioInput:(BOOL)f
{
    _useVidpressoAudioInput = f;
    
    _activeAudioSource = (_useVidpressoAudioInput) ? _audioSource_VP : _audioSource_CoreAudio;
    
    NSLog(@"activating VP audio input: %d", f);

    obs_set_output_source(1, _activeAudioSource);
}

- (void)setMixLocalInputIntoVidpressoAudio:(BOOL)f
{
    _mixLocalInputIntoVidpressoAudio = f;
    
    if (f) {
        if ( !_localAudioCapForMix) {
            _localAudioCapForMix = [[VDPAudioCapture alloc] init];
        }
        
        g_vpLocalAudioCaptureObj = (__bridge void *)(_localAudioCapForMix);
        
        NSLog(@"local audio cap for mix was created");
    }
    else {
        _localAudioCapForMix = nil;
        
        g_vpLocalAudioCaptureObj = NULL;
    }
}


- (void)_updateObsOutputSettings
{
    obs_data_t *h264Settings = obs_data_create();
    obs_data_t *aacSettings  = obs_data_create();
    
    int videoBitrate = (self.videoBitrate > 0) ? self.videoBitrate : 3.6*1024;
    int keyIntervalSecs = (self.keyIntervalSecs > 0) ? self.keyIntervalSecs : 2;
    NSString *profileName = (self.h264ProfileName.length > 0) ? self.h264ProfileName : @"main";
    NSString *presetName = (self.h264PresetName.length > 0) ? self.h264PresetName : @"veryfast";
    NSString *x264opts = (self.h264EncoderOptionsString.length > 0) ? self.h264EncoderOptionsString : nil;
    
    obs_data_set_int(h264Settings, "bitrate", videoBitrate);
    obs_data_set_int(h264Settings, "keyint_sec", keyIntervalSecs);
    obs_data_set_string(h264Settings, "profile", profileName.UTF8String);
    obs_data_set_string(h264Settings, "preset", presetName.UTF8String);
    if (x264opts) {
        obs_data_set_string(h264Settings, "x264opts", x264opts.UTF8String);
    }
    
    _latestVideoEncoderSettingsInfo = [NSString stringWithFormat:@"Video settings: encoder bitrate %d, interval %d, profile '%@', preset '%@', x264opts \"%@\"\n", videoBitrate, keyIntervalSecs, profileName, presetName, x264opts];
    
    NSLog(@"%@", _latestVideoEncoderSettingsInfo);
    
    /*
    obs_data_set_string(h264Settings, "x264opts",
                        "m8x8dct=1 aq-mode=2 bframes=1 chroma-qp-offset=1 colormatrix=smpte170m deblock=0:0 direct=auto ipratio=1.41 keyint=120 level=3.1 me=hex merange=16 min-keyint=auto mixed-refs=1 no-mbtree=0 partitions=i4x4,p8x8,b8x8 profile=high psy-rd=0.5:0.0 qcomp=0.6 qpmax=51 qpmin=10 qpstep=4 ratetol=10 rc-lookahead=30 ref=1 scenecut=40 subme=5 threads=0 trellis=2 weightb=1 weightp=2");
     */
    
    int audioBitrate = (self.audioBitrate > 0) ? self.audioBitrate : 128;
    obs_data_set_bool(aacSettings, "cbr", true);
    obs_data_set_int(aacSettings, "bitrate", audioBitrate);
    
    for (int i = 0; i < _numStreams; i++) {
        obs_service_apply_encoder_settings(_services[i], h264Settings, aacSettings);
    }
    
    obs_encoder_set_preferred_video_format(_h264Streaming, VIDEO_FORMAT_NV12);
    
    obs_encoder_update(_h264Streaming, h264Settings);
    obs_encoder_update(_aacStreaming,  aacSettings);
    
    obs_data_release(h264Settings);
    obs_data_release(aacSettings);
    
    int i = 0;
    for (VPObsServerDestination *serverDesc in _serverDestinations) {
        obs_data_t *serviceSettings = obs_data_create();
        
        obs_data_set_string(serviceSettings, "server", serverDesc.url.UTF8String);
        obs_data_set_string(serviceSettings, "key", serverDesc.key.UTF8String);
        
        obs_service_update(_services[i++], serviceSettings);
        
        obs_data_release(serviceSettings);
    }
    
    if (self.videoSize.width > 0) {
        obs_data_t *settings = obs_data_create();
        
        obs_data_set_int(settings, "w", self.videoSize.width);
        obs_data_set_int(settings, "h", self.videoSize.height);
        
        obs_source_update(_vpSource, settings);
        
        obs_data_release(settings);
    }
}

- (BOOL)startStreaming
{
    if (self.isStreaming) {
        NSLog(@"%s: already streaming", __func__);
        return YES;
    }
    
    [self _updateObsOutputSettings];
    
    os_atomic_set_bool(&g_vpAudioSourceAlive, self.useVidpressoAudioInput);
    
    obs_encoder_set_video(_h264Streaming, obs_get_video());
    obs_encoder_set_audio(_aacStreaming,  obs_get_audio());
    
    for (int i = 0; i < _numStreams; i++) {
        VPObsServerDestination *serverDesc = self.serverDestinations[i];
        
        obs_output_set_video_encoder(_streamOutputs[i], _h264Streaming);
        
        if (_aacStreaming) obs_output_set_audio_encoder(_streamOutputs[i], _aacStreaming, 0);
        
        obs_output_set_service(_streamOutputs[i], _services[i]);
        
        if ( !obs_output_start(_streamOutputs[i])) {
            [[NSDistributedNotificationCenter defaultCenter]
             postNotificationName:@"VDPEncodingHelperStreamingFailedNotification"
             object:serverDesc.url
             userInfo:nil
             deliverImmediately:YES];
            
            NSLog(@"** %s: start failed for url %@", __func__, serverDesc.url);
        }
        else {
            self.isStreaming = YES;
        }
        
        NSLog(@"obs streaming started, %@", serverDesc.url);
    }

    
    // set up file output
    NSDateFormatter *dateFmt = [[NSDateFormatter alloc] init];
    [dateFmt setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US"]];
    [dateFmt setDateFormat:@"yyyy-MM-dd' 'HHmmss"];
    NSString *dateStr = [dateFmt stringFromDate:[NSDate date]];
    
    NSString *logFileName = [NSString stringWithFormat:@"Vidpresso Live Encoding Session %@.log", dateStr];
    NSString *logPath = [@"/tmp" stringByAppendingPathComponent:logFileName];
    
    [_latestVideoEncoderSettingsInfo writeToFile:logPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    
    NSInteger logPathBufLen = strlen(logPath.UTF8String) + 1;
    g_encodingLogFileStr = malloc(logPathBufLen);
    snprintf(g_encodingLogFileStr, logPathBufLen, "%s", logPath.UTF8String);
    
    NSLog(@"logging encoding info to: %s", g_encodingLogFileStr);
    
    NSString *recPath = nil;
    if (_fileOutput) {
        obs_output_set_video_encoder(_fileOutput, _h264Streaming);
        
        if (_aacStreaming) obs_output_set_audio_encoder(_fileOutput, _aacStreaming, 0);
        
        obs_data_t *fileOutputSettings = obs_data_create();
        
        NSString *recDir = [@"~/Movies" stringByStandardizingPath];
        NSString *filename = [NSString stringWithFormat:@"Vidpresso Live Recording %@.mp4", dateStr];
        recPath = [recDir stringByAppendingPathComponent:filename];
        
        obs_data_set_string(fileOutputSettings, "path", recPath.UTF8String);
        //obs_data_set_string(fileOutputSettings, "muxer_settings", mux);
        obs_output_update(_fileOutput, fileOutputSettings);
        obs_data_release(fileOutputSettings);
    }
    
    if (recPath) {
        if ( !obs_output_start(_fileOutput)) {
            NSLog(@"** could not start file output (%@)", recPath);
        } else {
            NSLog(@"obs file recording started, path: %@", recPath);
            self.isRecording = YES;
        }
    }
    
    _debugUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(updateSkippedFramesTimer:) userInfo:nil repeats:YES];
    
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:@"VDPEncodingHelperWillStartStreamingNotification"
     object:nil
     userInfo:nil
     deliverImmediately:YES];
    
    return YES;
}

- (void)stopStreaming
{
    if (self.isStreaming) {
        for (int i = 0; i < _numStreams; i++) {
            obs_output_stop(_streamOutputs[i]);
        }
        self.isStreaming = NO;
    }
    if (self.isRecording) {
        obs_output_stop(_fileOutput);
        self.isRecording = NO;
    }
    
    os_atomic_set_bool(&g_vpAudioSourceAlive, false);
    
    [_debugUpdateTimer invalidate], _debugUpdateTimer = nil;
    
}

- (void)updateSkippedFramesTimer:(NSTimer *)timer
{
    //NSInteger droppedFrames = obs_output_get_frames_dropped(_streamOutput);
    //NSInteger totalFrames = obs_output_get_total_frames(_streamOutput);
    
    //NSLog(@"dropped frames %ld, total %ld -- %.2f %%", droppedFrames, totalFrames, 100*((double)droppedFrames / totalFrames));
}


- (void)outputStarted:(long)outputIndex
{
    VPObsServerDestination *serverDesc = self.serverDestinations[outputIndex];
    
    NSLog(@"%s, %ld, %@", __func__, outputIndex, serverDesc.url);
    
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:@"VDPEncodingHelperDidStartStreamingNotification"
     object:serverDesc.url
     userInfo:nil
     deliverImmediately:YES];
    
    _pingbackNotifObj = serverDesc.url;
    
    _pingbackToMainProcessTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(pingbackToMainProcessTimer:) userInfo:nil repeats:YES];
    
    /*dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"DEBUG: killing pingback timer");
        [_pingbackToMainProcessTimer invalidate], _pingbackToMainProcessTimer = nil;
    });*/
}

- (void)pingbackToMainProcessTimer:(NSTimer *)timer
{
    //NSLog(@"%s", __func__);
    
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:@"VDPEncodingHelperIsActiveNotification"
     object:_pingbackNotifObj
     userInfo:nil
     deliverImmediately:YES];
}

- (void)outputStopped:(long)outputIndex
{
    VPObsServerDestination *serverDesc = self.serverDestinations[outputIndex];
    
    NSLog(@"%s, %ld, %@", __func__, outputIndex, serverDesc.url);
    
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:@"VDPEncodingHelperDidStopStreamingNotification"
     object:serverDesc.url
     userInfo:nil
     deliverImmediately:YES];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [_pingbackToMainProcessTimer invalidate], _pingbackToMainProcessTimer = nil;
    });
}

- (void)outputReconnecting:(long)outputIndex
{
    VPObsServerDestination *serverDesc = self.serverDestinations[outputIndex];
    
    NSLog(@"%s, %ld, %@", __func__, outputIndex, serverDesc.url);
    
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:@"VDPEncodingHelperIsReconnectingNotification"
     object:serverDesc.url
     userInfo:nil
     deliverImmediately:YES];

}

- (void)outputReconnectSuccess:(long)outputIndex
{
    VPObsServerDestination *serverDesc = self.serverDestinations[outputIndex];
    
    NSLog(@"%s, %ld, %@", __func__, outputIndex, serverDesc.url);
    
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:@"VDPEncodingHelperDidReconnectNotification"
     object:serverDesc.url
     userInfo:nil
     deliverImmediately:YES];

}


@end
