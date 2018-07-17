//
//  VDPAudioMixer.m
//  VidpressoStation
//
//  Created by Pauli Ojala on 07/09/16.
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

#import "VDPAudioMixer.h"

#define WRITE_AUDIO_DEBUG_FILE 0



#include "VDPAudioMixBufferInclude.c"



@interface VDPAudioMixer () <VDPAudioCaptureDelegate> {
    
    VDPAudioMixBuffer _delayBuffer_captured;
    VDPAudioMixBuffer _delayBuffer_ch2;

    VDPAudioMixBuffer _finalMixBuffer;
    
    float *_tempBuf1;
    float *_tempBuf2;

    NSLock *_inBufLock;
    
    FILE *_debugRecFile;
}

@property (nonatomic, retain) VDPAudioCapture *audioCapture;
@property (nonatomic, assign) long sampleRate;

@end


@implementation VDPAudioMixer

- (id)initWithAudioCapture:(VDPAudioCapture *)audioCapture
{
    self.audioCapture = audioCapture;
    self.audioCapture.delegate = self;
    
    [self.audioCapture start];
    
    self.sampleRate = SAMPLERATE;
    
    self.capturedAudioVolume = 1.0;

    initMixBuffer(&_delayBuffer_captured);
    initMixBuffer(&_delayBuffer_ch2);

    initMixBuffer(&_finalMixBuffer);
    
    _tempBuf1 = malloc(_delayBuffer_captured.capacity * sizeof(float));
    _tempBuf2 = malloc(_delayBuffer_captured.capacity * sizeof(float));
    
    _inBufLock = [[NSLock alloc] init];
    
    NSLog(@"%s, mixbuf1 (local) %p, mixbuf2 (remote + mix) %p", __func__, &_delayBuffer_captured, &_finalMixBuffer);

#if WRITE_AUDIO_DEBUG_FILE
    _debugRecFile = fopen("/Users/pauli/temp/vpaudiorec_mixer_input.raw", "wb");
#endif
    
    return self;
}

- (void)dealloc
{
    self.audioCapture.delegate = nil;
    self.audioCapture = nil;
    
    free(_delayBuffer_captured.sampleData);
    free(_delayBuffer_ch2.sampleData);
    free(_finalMixBuffer.sampleData);
    
    free(_tempBuf1);
    free(_tempBuf2);

#if !__has_feature(objc_arc)
    [_inBufLock release];
    
    [super dealloc];
#endif
}



#pragma mark --- audio capture delegate ---

- (void)audioCapture:(VDPAudioCapture *)cap
 received16BitBuffer:(int16_t *)data
         numChannels:(int)srcNumChannels
      numberOfFrames:(int)numberOfFrames
{
    const int dstNumChannels = 2;
    const NSInteger numSamples = dstNumChannels * numberOfFrames;
    float tempBuf[numSamples];
    
    const float volume = self.capturedAudioVolume;
    
    //printf("...audiomix: local capture got %ld samples, numchannels %d, volume %.3f\n", numSamples, srcNumChannels, volume);
    
    if (srcNumChannels == 1) {
        for (NSInteger i = 0; i < numberOfFrames; i++) {
            float v = (float)data[i] / 32768.0f * volume;
            v = MAX(-1.0f, MIN(1.0f, v));
            tempBuf[i*2] = v;
            tempBuf[i*2 + 1] = v;
        }
    }
    else {
        for (NSInteger i = 0; i < numSamples; i++) {
            float v = (float)data[i] / 32768.0f * volume;
            v = MAX(-1.0f, MIN(1.0f, v));
            tempBuf[i] = v;
        }
    }

#if 0
    // TEST: render sinewave
    const float rate = 261.63/48000.0;
    static float cos_val = 0.0;
    for (size_t i = 0; i < numSamples; i++) {
        cos_val += rate * M_PI*2;
        if (cos_val > M_PI*2)
            cos_val -= M_PI*2;
        
        float wave = cosf(cos_val) * 0.5f;
        tempBuf[i] = (wave+1.0f)*0.5;
    }
#endif
    
    if (_debugRecFile) {
        fwrite(tempBuf, 1, numSamples*sizeof(float), _debugRecFile);
    }
    
    [_inBufLock lock];
    
    appendToMixBuffer(&_delayBuffer_captured, tempBuf, numSamples);
    
    [_inBufLock unlock];
}


- (void)addChannel2FloatSamples:(float *)srcBuf count:(long)srcSize
{
    [_inBufLock lock];
    
    appendToMixBuffer(&_delayBuffer_ch2, srcBuf, MIN(srcSize, _delayBuffer_ch2.capacity));
    
    [_inBufLock unlock];
}


#pragma mark --- consuming mixed output ---


#define MINDELAY (20.0/1000.0)

static BOOL mixBufferHasEnoughDataForDelay(VDPAudioMixBuffer *mixBuf, double delay, long readSize)
{
    delay = MAX(MINDELAY, delay);
    
    long delaySamples = delay*SAMPLERATE;
    long availableDelayedSamples = mixBuf->writePos - mixBuf->readPos;

    return (availableDelayedSamples >= delaySamples + readSize);
}

static long readFromMixBufferWithDelay(VDPAudioMixBuffer *mixBuf, double delay, float *dstBuf, long dstNumSamples)
{
    delay = MAX(MINDELAY, delay);
    
    long delaySamples = delay*SAMPLERATE;
    long availableDelayedSamples = mixBuf->writePos - mixBuf->readPos;
    
    if (availableDelayedSamples < delaySamples + dstNumSamples) {
        return 0;
    }
    
    memcpy(dstBuf, mixBuf->sampleData + mixBuf->readPos, dstNumSamples*sizeof(float));
    
    mixBuf->readPos += dstNumSamples;
    
    return dstNumSamples;
}


- (long)consumeFloatSamples:(float *)dstBuf requestedCount:(long)dstSize
{
    [_inBufLock lock];
    
    if ( !mixBufferHasEnoughDataForDelay(&_delayBuffer_captured, self.capturedAudioDelayInSecs, dstSize)
        || !mixBufferHasEnoughDataForDelay(&_delayBuffer_ch2, self.channel2AudioDelayInSecs, dstSize)) {
        [_inBufLock unlock];
        return 0;
    }
    
    const long tempBufCapacity = _delayBuffer_captured.capacity;
    //memset(_tempBuf1, 0, tempBufCapacity*sizeof(float));
    //memset(_tempBuf2, 0, tempBufCapacity*sizeof(float));
    
    long numSamples1 = readFromMixBufferWithDelay(&_delayBuffer_captured, self.capturedAudioDelayInSecs, _tempBuf1, MIN(tempBufCapacity, dstSize));
    
    long numSamples2 = readFromMixBufferWithDelay(&_delayBuffer_ch2, self.channel2AudioDelayInSecs, _tempBuf2, MIN(tempBufCapacity, dstSize));
    
    long numSamples = MIN(numSamples1, numSamples2);
    
    for (NSInteger i = 0; i < numSamples; i++) {
        float v1 = _tempBuf1[i];
        float v2 = _tempBuf2[i];
        float v = v1 + v2;
        dstBuf[i] = MAX(-1.0f, MIN(1.0f, v));
    }
    
    [_inBufLock unlock];
    
    return numSamples;
}


#if 0

#pragma mark --- mixing of second channel ---

- (void)mixInFloatSamples:(float *)srcBuf count:(long)srcSize
{
    const double audioDelay = self.localAudioDelayInSecs;
    
    [_inBufLock lock];
    
    if (audioDelay >= 0.001) {
        long delaySamples = audioDelay*SAMPLERATE;
        long availableDelayedSamples = _delayBuffer.writePos - _delayBuffer.readPos;
        if (availableDelayedSamples < delaySamples + srcSize) {
            // wait for delay buffer to fill up
            [_inBufLock unlock];
            return; // --
        }
        
        appendToMixBuffer(&_inBuffer1, _delayBuffer.sampleData + _delayBuffer.readPos, srcSize);
        _delayBuffer.readPos += srcSize;
    }
    
    /*// wait for the first buffer to fill up enough so we can begin mixing
    const long minRequiredSamples = srcSize * 2;
    if (_inBuffer1.totalSamplesWritten < minRequiredSamples) {
        [_inBufLock unlock];
        return; // --
    }*/
    
    const NSInteger numSamples = srcSize;
    float tempBuf[numSamples];

    if (_inBuffer1.readPos + numSamples > _inBuffer1.writePos) {
        printf("%s: overflow when reading input buffer, local audio probably not running - will skip mixing (inbuf1 readpos %ld, writepos %ld, capacity %ld)\n", __func__, _inBuffer1.readPos, _inBuffer1.writePos, _inBuffer1.capacity);
        memcpy(tempBuf, srcBuf, numSamples*sizeof(float));
    }
    else {
        float *inBuf = _inBuffer1.sampleData + _inBuffer1.readPos;
        
        for (NSInteger i = 0; i < numSamples; i++) {
            tempBuf[i] = MAX(-1.0f, MIN(1.0f, inBuf[i] + srcBuf[i]));
            
            //tempBuf[i] = inBuf[i];
            //tempBuf[i] = srcBuf[i];
        }
        
        _inBuffer1.readPos += numSamples;
    }
    
#if 0
    // TEST: render sinewave
    static const float rate = 261.63/48000.0;
    static float cos_val = 0.0;
    for (size_t i = 0; i < numSamples; i++) {
        cos_val += rate * M_PI*2;
        if (cos_val > M_PI*2)
            cos_val -= M_PI*2;
        
        float wave = cosf(cos_val) * 0.5f;
        tempBuf[i] = (wave+1.0f)*0.5;
    }
#endif

    appendToMixBuffer(&_mixBuffer, tempBuf, numSamples);
    
    //printf("wrote mix, pos now %ld\n", _mixBuffer.writePos);
    
    [_inBufLock unlock];
}



#pragma mark --- consuming mixed output ---

- (long)numberOfSamplesConsumable
{
    [_inBufLock lock];
    
    long numSamplesAvailable = _mixBuffer.writePos - _mixBuffer.readPos;
    
    [_inBufLock unlock];
    
    return numSamplesAvailable;
}

- (long)consumeFloatSamples:(float *)dstBuf requestedCount:(long)dstSize
{
    if ( !dstBuf || dstSize < 1)
        return 0; // --
    
    [_inBufLock lock];
    
    long numSamplesAvailable = _mixBuffer.writePos - _mixBuffer.readPos;
    long numSamples = MIN(dstSize, numSamplesAvailable);
    
    //printf("consuming mix, readpos now %ld, numsamples requested %ld (available %ld)\n", _mixBuffer.readPos, numSamples, numSamplesAvailable);
    
    if (numSamples > 0) {
        float *srcBuf = _mixBuffer.sampleData + _mixBuffer.readPos;
        /*
        float minV = FLT_MAX;
        float maxV = -FLT_MAX;
        for (NSInteger i = 0; i < numSamples; i++) {
            float v = srcBuf[i];
            minV = MIN(minV, v);
            maxV = MAX(maxV, v);
        }
        printf("  ... data min %.5f, max %.5f\n", minV, maxV);
         */
        
        memcpy(dstBuf, srcBuf, numSamples*sizeof(float));
    
        _mixBuffer.readPos += numSamples;
        
        // TEST
        //memset(dstBuf, 0, numSamples*sizeof(float));
    }
    
    [_inBufLock unlock];
    
    return numSamples;
}

#endif

@end
