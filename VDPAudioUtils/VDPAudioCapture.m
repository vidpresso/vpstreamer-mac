//
//  VDPAudioCapture.m
//  VidpressoStation
//
//  Created by Pauli Ojala on 04/08/16.
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

#import "VDPAudioCapture.h"
#import <AudioToolbox/AudioToolbox.h>


#define kNumberRecordBuffers    3


@interface VDPAudioCapture () {
    
    AudioQueueRef				_queue;
    
    CFAbsoluteTime				_queueStartTime;
    CFAbsoluteTime				_queueStopTime;
    int64_t                     _recordPacket; // current packet number in record file
}

@property (atomic, assign) BOOL running;

- (void)audioQueuePropertyChanged:(AudioQueuePropertyID)propertyID;

- (void)audioQueueHasInputBuffer:(AudioQueueBufferRef)buffer
                       timeStamp:(const AudioTimeStamp *)startTime
                 numberOfPackets:(int32_t)numPackets
                      packetDesc:(const AudioStreamPacketDescription *)packetDesc;

@end




// Determine the size, in bytes, of a buffer necessary to represent the supplied number
// of seconds of audio data.
static int aqRecord_ComputeRecordBufferSize(const AudioStreamBasicDescription *format, AudioQueueRef queue, float seconds)
{
    int packets, frames, bytes;
    OSStatus err;
    
    frames = (int)ceil(seconds * format->mSampleRate);
    
    if (format->mBytesPerFrame > 0)
        bytes = frames * format->mBytesPerFrame;
    else {
        UInt32 maxPacketSize;
        if (format->mBytesPerPacket > 0)
            maxPacketSize = format->mBytesPerPacket;	// constant packet size
        else {
            UInt32 propertySize = sizeof(maxPacketSize);
            err = AudioQueueGetProperty(queue, kAudioConverterPropertyMaximumOutputPacketSize, &maxPacketSize, &propertySize);
            if (err != noErr)
                NSLog(@"** %s: couldn't get max output packet size", __func__);
        }
        if (format->mFramesPerPacket > 0)
            packets = frames / format->mFramesPerPacket;
        else
            packets = frames;	// worst-case scenario: 1 frame in a packet
        if (packets == 0)		// sanity check
            packets = 1;
        bytes = packets * maxPacketSize;
    }
    return bytes;
}


// AudioQueue callback function, called when a property changes.
static void aqRecord_PropertyListener(void *userData, AudioQueueRef queue, AudioQueuePropertyID propertyID)
{
    VDPAudioCapture *self = (__bridge VDPAudioCapture *)userData;
    
    [self audioQueuePropertyChanged:propertyID];
    
    /*
    [g_pcmStateLock lock];
    TwtwAQRecorder *aqr = g_pcmState.aqRecorder;
    
    if (propertyID == kAudioQueueProperty_IsRunning) {
        aqr->queueStartTime = CFAbsoluteTimeGetCurrent();
    }
    
    [g_pcmStateLock unlock];
     */
}

// AudioQueue callback function, called when an input buffers has been filled.
static void aqRecord_InputBufferHandler(
                                        void *                          inUserData,
                                        AudioQueueRef                   inAQ,
                                        AudioQueueBufferRef             inBuffer,
                                        const AudioTimeStamp *          inStartTime,
                                        UInt32							inNumPackets,
                                        const AudioStreamPacketDescription *inPacketDesc)
{
    VDPAudioCapture *self = (__bridge VDPAudioCapture *)inUserData;
    
    [self audioQueueHasInputBuffer:inBuffer timeStamp:inStartTime numberOfPackets:inNumPackets packetDesc:inPacketDesc];
    
    /*
        if (aqr->verbose) {
            printf("%s: buf data %p, %i bytes, %i packets\n", __func__, inBuffer->mAudioData,
                   (int)inBuffer->mAudioDataByteSize, (int)inNumPackets);
            
            printf("    record packet: %i; record file: %p\n", (int)aqr->recordPacket, aqr->recordFile);
        }
        
        if (inNumPackets > 0) {
            // write packets to file
            err = AudioFileWritePackets(aqr->recordFile, FALSE, inBuffer->mAudioDataByteSize,
                                        inPacketDesc, aqr->recordPacket, &inNumPackets, inBuffer->mAudioData);
            
            if (err != noErr) {
                NSString *desc = (err == paramErr) ? @"paramErr" : [[NSString alloc] initWithFormat:@"err %i", err];
                
                NSLog(@"*** %s: AudioFileWritePackets failed (%@); %p, audioDataByteSize %i, inPacketDesc %p, recPacket %i, numPackets %i, outdata %p", __func__, desc,
                      aqr->recordFile, inBuffer->mAudioDataByteSize, inPacketDesc, (int)aqr->recordPacket,
                      (int)inNumPackets, inBuffer->mAudioData);
            }
            
            aqr->recordPacket += inNumPackets;
        }
        
        if (g_pcmState.callbacks.audioInProgressFunc && aqr->queueStartTime > 0.0) {
            double elapsedTime = CFAbsoluteTimeGetCurrent() - aqr->queueStartTime;
            g_pcmState.callbacks.audioInProgressFunc(TWTW_AUDIOSTATUS_REC, elapsedTime, g_pcmState.cbData);
        }
        
        
        // if we're not stopping, re-enqueue the buffer so that it gets filled again
        if (aqr->running) {
            err = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
            
            if ( err != noErr) NSLog(@"** %s: AudioQueueEnqueueBuffer failed", __func__);
        }
    }
    [g_pcmStateLock unlock];
     */
}



#if 0

static void stopAQRecording()
{
    NSCAssert(g_pcmState.aqRecorder, @"no recorder state");
    [g_pcmStateLock lock];
    
    TwtwAQRecorder *aqr = g_pcmState.aqRecorder;
    OSStatus err;
    
    aqr->running = FALSE;
    g_pcmState.state = TwtwPCMIsIdle;
    [g_pcmStateLock unlock];
    
    if ((err = AudioQueueStop(aqr->queue, TRUE)) != noErr) {
        NSLog(@"** %s: AudioQueueStop failed (%i)", __func__, err);
    }
    
    // a codec may update its cookie at the end of an encoding session, so reapply it to the file now
    aqRecord_CopyEncoderCookieToFile(aqr->queue, aqr->recordFile);
    
    AudioQueueDispose(aqr->queue, TRUE);
    AudioFileClose(aqr->recordFile);
    
    free(g_pcmState.aqRecorder);
    g_pcmState.aqRecorder = NULL;
    
    if (g_pcmState.timer) {
        CFRunLoopTimerInvalidate(g_pcmState.timer);
        CFRelease(g_pcmState.timer);
    }
    
    if (g_pcmState.callbacks.audioCompletedFunc) {
        g_pcmState.callbacks.audioCompletedFunc(TWTW_AUDIOSTATUS_REC, g_pcmState.cbData);
    }
    
    memset(&g_pcmState, 0, sizeof(TwtwPCMState));
}


static void aqRecord_TimerCallback (CFRunLoopTimerRef timer, void *userdata)
{
    [g_pcmStateLock lock];
    
    BOOL doStop = YES;
    if (g_pcmState.state != TwtwPCMIsRecording) {
        NSLog(@"** %s: not in recording state (this timer should have been invalidated)", __func__);
        doStop = NO;
    }
    
    if (doStop) g_pcmState.didComplete = TRUE;
    
    [g_pcmStateLock unlock];
    
    if (doStop) stopAQRecording();
}


static NSString *printableOSStatusError(OSStatus error, const char *operation)
{
    if (error == noErr) return @"(no error)";
    
    char str[20];
    // see if it appears to be a 4-char-code
    *(UInt32 *)(str + 1) = CFSwapInt32HostToBig(error);
    if (isprint(str[1]) && isprint(str[2]) && isprint(str[3]) && isprint(str[4])) {
        str[0] = str[5] = '\'';
        str[6] = '\0';
    } else
        // no, format it as an integer
        sprintf(str, "%d", (int)error);
    
    return [NSString stringWithFormat:@"%s (%s)", operation, str];
}



int twtw_audio_pcm_record_to_path_utf8 (const char *path, size_t pathLen, int seconds, TwtwAudioCallbacks callbacks, void *cbData)
{
    if ( !path || pathLen < 1 || seconds < 1)
        return -1;
    
    [g_pcmStateLock lock];
    BOOL stateIsOK = (g_pcmState.state == TwtwPCMIsIdle);
    [g_pcmStateLock unlock];
    
    if ( !stateIsOK) {
        NSLog(@"** %s: can't start recording, system is not idle (state: %i)", __func__, g_pcmState.state);
        return -1;
    }
    
    memset(&g_pcmState, 0, sizeof(TwtwPCMState));
    
    AudioStreamBasicDescription recordFormat;
    TwtwAQRecorder aqr;
    OSStatus err;
    
    memset(&recordFormat, 0, sizeof(recordFormat));
    memset(&aqr, 0, sizeof(aqr));
    
    recordFormat.mChannelsPerFrame = 1;
    recordFormat.mSampleRate = TWTW_PCM_SAMPLERATE;
    recordFormat.mBitsPerChannel = TWTW_PCM_SAMPLEBITS;
    recordFormat.mFormatID = kAudioFormatLinearPCM;
    recordFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    
#ifndef TWTW_PCM_LITTLE_ENDIAN
    recordFormat.mFormatFlags |= kLinearPCMFormatFlagIsBigEndian;
#endif
    
    recordFormat.mBytesPerPacket = recordFormat.mBytesPerFrame =
    (recordFormat.mBitsPerChannel / 8) * recordFormat.mChannelsPerFrame;
    
    recordFormat.mFramesPerPacket = 1;
    recordFormat.mReserved = 0;
    
    if ((err = AudioQueueNewInput(&recordFormat,
                                  aqRecord_InputBufferHandler,
                                  NULL,
                                  NULL /* run loop */, NULL /* run loop mode */,
                                  0 /* flags */, &aqr.queue)) != noErr) {
        NSLog(@"** AudioQueueNewInput failed");
        return err;
    }
    
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (Byte *)path, pathLen, FALSE);
    AudioFileTypeID audioFileType = kAudioFileWAVEType;
    
    if ((err = AudioFileCreateWithURL(url, audioFileType, &recordFormat, kAudioFileFlags_EraseFile,
                                      &aqr.recordFile)) != noErr) {
        NSLog(@"** failed: %@", printableOSStatusError(err, "AudioFileCreateWithURL"));
        return err;
    }
    
    CFRelease(url);
    url = NULL;
    
    
    // copy the cookie first to give the file object as much info as we can about the data going in
    aqRecord_CopyEncoderCookieToFile(aqr.queue, aqr.recordFile);
    
    // allocate and enqueue buffers
    int bufferByteSize = aqRecord_ComputeRecordBufferSize(&recordFormat, aqr.queue, 0.5);	// enough bytes for half a second
    int i;
    for (i = 0; i < kNumberRecordBuffers; ++i) {
        AudioQueueBufferRef buffer;
        AudioQueueAllocateBuffer(aqr.queue, bufferByteSize, &buffer);
        
        AudioQueueEnqueueBuffer(aqr.queue, buffer, 0, NULL);
    }
    
    aqr.running = TRUE;
    aqr.verbose = FALSE;
    
    g_pcmState.state = TwtwPCMIsRecording;
    g_pcmState.callbacks = callbacks;
    g_pcmState.cbData = cbData;
    
    g_pcmState.aqRecorder = malloc(sizeof(TwtwAQRecorder));
    memcpy(g_pcmState.aqRecorder, &aqr, sizeof(TwtwAQRecorder));
    
    // add listener to time the recording more accurately
    g_pcmState.aqRecorder->queueStartTime = 0.0;
    AudioQueueAddPropertyListener(aqr.queue, kAudioQueueProperty_IsRunning, aqRecord_PropertyListener, NULL);
    
    if ((err = AudioQueueStart(aqr.queue, NULL)) != noErr) {
        NSLog(@"** AudioQueueStart failed");
        stopAQRecording();
        return 16452;
    }
    
    CFAbsoluteTime waitForStartUntil = CFAbsoluteTimeGetCurrent() + 10;
    
    // wait for the started notification
    while (g_pcmState.aqRecorder->queueStartTime == 0.0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.010, FALSE);
        if (CFAbsoluteTimeGetCurrent() >= waitForStartUntil) {
            fprintf(stderr, "Timeout waiting for the queue's IsRunning notification\n");
            
            stopAQRecording();
            return 16455;
        }
    }
    
    g_pcmState.aqRecorder->queueStopTime = g_pcmState.aqRecorder->queueStartTime + seconds;
    CFAbsoluteTime stopTime = g_pcmState.aqRecorder->queueStopTime;
    //CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    
    ///NSLog(@"%s: got callback notif, now recording for %i seconds", __func__, seconds);
    
    CFRunLoopTimerRef recTimer = CFRunLoopTimerCreate(NULL,
                                                      stopTime,
                                                      0.0,  // interval
                                                      0,    // flags (ignored)
                                                      0,    // order (ignored)
                                                      aqRecord_TimerCallback,
                                                      NULL);
    
    g_pcmState.timer = recTimer;
    CFRunLoopAddTimer(CFRunLoopGetMain(), recTimer, kCFRunLoopCommonModes);
    
    return 0;
}

#endif


@implementation VDPAudioCapture

- (BOOL)start
{
    AudioStreamBasicDescription recordFormat;
    OSStatus err;
    
    memset(&recordFormat, 0, sizeof(recordFormat));
    
    recordFormat.mChannelsPerFrame = 1;
    recordFormat.mFramesPerPacket = 1;

    recordFormat.mSampleRate = 48000;
    recordFormat.mBitsPerChannel = 16;
    recordFormat.mFormatID = kAudioFormatLinearPCM;
    recordFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    
    recordFormat.mBytesPerPacket = recordFormat.mBytesPerFrame =
                (recordFormat.mBitsPerChannel / 8) * recordFormat.mChannelsPerFrame;
    
    if ((err = AudioQueueNewInput(&recordFormat,
                                  aqRecord_InputBufferHandler,
                                  (__bridge void *)self,
                                  NULL /* run loop */, NULL /* run loop mode */,
                                  0 /* flags */, &_queue)) != noErr) {
        NSLog(@"** AudioQueueNewInput failed: %d", err);
        return NO;
    }

    // allocate and enqueue buffers
    int bufferByteSize = aqRecord_ComputeRecordBufferSize(&recordFormat, _queue, 0.25);  // last value is seconds
    int i;
    for (i = 0; i < kNumberRecordBuffers; ++i) {
        AudioQueueBufferRef buffer;
        AudioQueueAllocateBuffer(_queue, bufferByteSize, &buffer);
        
        AudioQueueEnqueueBuffer(_queue, buffer, 0, NULL);
    }
    
    self.running = YES;
    
    _queueStartTime = 0.0;

    AudioQueueAddPropertyListener(_queue, kAudioQueueProperty_IsRunning, aqRecord_PropertyListener, (__bridge void *)self);
    
    if ((err = AudioQueueStart(_queue, NULL)) != noErr) {
        NSLog(@"** AudioQueueStart failed");
        return NO;
    }

    /*
    CFAbsoluteTime waitForStartUntil = CFAbsoluteTimeGetCurrent() + 10;
    
    // wait for the started notification
    while (g_pcmState.aqRecorder->queueStartTime == 0.0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.010, FALSE);
        if (CFAbsoluteTimeGetCurrent() >= waitForStartUntil) {
            fprintf(stderr, "Timeout waiting for the queue's IsRunning notification\n");
            
            stopAQRecording();
            return 16455;
        }
    }
    */
    
    NSLog(@"%s -- audio queue started, %p", __func__, _queue);
    
    return YES;
}



- (void)audioQueuePropertyChanged:(AudioQueuePropertyID)propertyID
{
    if (propertyID == kAudioQueueProperty_IsRunning) {
        _queueStartTime = CFAbsoluteTimeGetCurrent();
    }
}

- (void)audioQueueHasInputBuffer:(AudioQueueBufferRef)inBuffer
                       timeStamp:(const AudioTimeStamp *)startTime
                 numberOfPackets:(int32_t)numPackets
                      packetDesc:(const AudioStreamPacketDescription *)packetDesc
{
    OSStatus err;
    
    if (0) {
        printf("%s: buf data %p, %i bytes, %i packets\n", __func__, inBuffer->mAudioData,
               (int)inBuffer->mAudioDataByteSize, (int)numPackets);
    }
    
    id delegate = self.delegate;
    
    if (delegate && numPackets > 0) {
        [delegate audioCapture:self
            received16BitBuffer:(int16_t *)(inBuffer->mAudioData)
                    numChannels:1
                 numberOfFrames:numPackets];
    }
    
    /*
    if (numPackets > 0) {
        // write packets to file
        err = AudioFileWritePackets(aqr->recordFile, FALSE, inBuffer->mAudioDataByteSize,
                                    inPacketDesc, aqr->recordPacket, &inNumPackets, inBuffer->mAudioData);
        
        if (err != noErr) {
            NSString *desc = (err == paramErr) ? @"paramErr" : [[NSString alloc] initWithFormat:@"err %i", err];
            
            NSLog(@"*** %s: AudioFileWritePackets failed (%@); %p, audioDataByteSize %i, inPacketDesc %p, recPacket %i, numPackets %i, outdata %p", __func__, desc,
                  aqr->recordFile, inBuffer->mAudioDataByteSize, inPacketDesc, (int)aqr->recordPacket,
                  (int)inNumPackets, inBuffer->mAudioData);
        }
    }
    */
    _recordPacket += numPackets;
    
    if (self.running) {
        err = AudioQueueEnqueueBuffer(_queue, inBuffer, 0, NULL);
        
        if ( err != noErr) NSLog(@"** %s: AudioQueueEnqueueBuffer failed: %d", __func__, err);
    }
}

@end
