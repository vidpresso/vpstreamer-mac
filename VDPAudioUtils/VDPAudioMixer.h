//
//  VDPAudioMixer.h
//  VidpressoStation
//
//  Created by Pauli Ojala on 07/09/16.
//  Copyright © 2016 Vidpresso. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "VDPAudioCapture.h"


/*
 Assumed audio format is interleaved stereo 48kHz
 */


@interface VDPAudioMixer : NSObject

- (id)initWithAudioCapture:(VDPAudioCapture *)audioCapture;

@property (readonly) VDPAudioCapture *audioCapture;

@property (atomic, assign) float capturedAudioVolume;

// these two delays can be used to
@property (atomic, assign) double capturedAudioDelayInSecs;
@property (atomic, assign) double channel2AudioDelayInSecs;



@property (readonly) long numberOfSamplesConsumable;

- (void)addChannel2FloatSamples:(float *)srcBuf count:(long)srcSize;

- (long)consumeFloatSamples:(float *)dstBuf requestedCount:(long)dstSize;

@end

