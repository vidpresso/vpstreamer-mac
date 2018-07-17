//
//  vp_obs_audio_source.c
//  VidpressoStation
//
//  Created by Pauli Ojala on 01/07/16.
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

#import <Foundation/Foundation.h>
#import "../VDPAudioUtils/VDPAudioCapture.h"
#import "../VDPAudioUtils/VDPAudioMixer.h"

#include "vp_obs_audio_source.h"
#include <math.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <util/bmem.h>
#include <util/threading.h>
#include <util/platform.h>
#include <obs.h>


volatile bool g_vpAudioSourceAlive = true;
volatile double g_vpAudioSourceSyncOffset_local = 0.0;
volatile double g_vpAudioSourceSyncOffset_remote = 0.0;
volatile double g_vpAudioSourceVolume_local = 1.0;

void *g_vpLocalAudioCaptureObj = NULL;
void *g_vpLocalAudioMixerObj = NULL;


static VDPAudioCapture *getLocalVDPAudioCapture()
{
    return (__bridge VDPAudioCapture *)g_vpLocalAudioCaptureObj;
}


#define WRITE_AUDIO_DEBUG_FILE 0


#define MSGPORTNAME "com.vidpresso.EncodingHelperAudioOutput"


#include "VPAudioOutputIPC.c"



typedef struct VPAudioRingBuffer {
    
    float *data;
    size_t bufferSize;
    
    long writerPosition;
    long readerPosition;
    
} VPAudioRingBuffer;


#ifndef VPAUDIORINGBUF_ADVANCE
  #define VPAUDIORINGBUF_ADVANCE(rb_, p_, n_) \
                    *(p_) += n_; \
                    if (*(p_) >= rb_->bufferSize) *(p_) = 0;
#endif


static void vpAudioRingBufferRead(VPAudioRingBuffer *rb, int count, float *dst)
{
    if ( !rb || !dst || count < 1) return;
    
    long availEnd = rb->bufferSize - rb->readerPosition;
    long n1 = MIN(count, availEnd);
    count -= n1;
    
    memcpy(dst, rb->data + rb->readerPosition, n1*sizeof(float));
    dst += n1;
    VPAUDIORINGBUF_ADVANCE(rb, &rb->readerPosition, n1);
    
    if (count > 0) {
        long n2 = MIN(count, rb->bufferSize);
        
        memcpy(dst, rb->data + rb->readerPosition, n2*sizeof(float));
        
        VPAUDIORINGBUF_ADVANCE(rb, &rb->readerPosition, n2);
    }
}

static void vpAudioRingBufferWrite(VPAudioRingBuffer *rb, int count, float *src)
{
    if ( !rb || !src || count < 1) return;
    
    long availEnd = rb->bufferSize - rb->writerPosition;
    long n1 = MIN(count, availEnd);
    count -= n1;
    
    memcpy(rb->data + rb->writerPosition, src, n1*sizeof(float));
    src += n1;
    VPAUDIORINGBUF_ADVANCE(rb, &rb->writerPosition, n1);
    
    if (count > 0) {
        long n2 = MIN(count, rb->bufferSize);
        
        memcpy(rb->data + rb->writerPosition, src, n2*sizeof(float));
        
        VPAUDIORINGBUF_ADVANCE(rb, &rb->readerPosition, n2);
    }
}


typedef struct VPSourceData {
    bool         initialized_thread;
    pthread_t    source_thread;
    pthread_t    driver_consumer_thread;
    os_event_t   *event;
    obs_source_t *source;
    volatile bool active;
    uint64_t startTime;
    
    CFMessagePortRef msgPort;
    CFRunLoopSourceRef localPortSrc;
    
    pthread_mutex_t audioDataLock;
    //float *audioData;
    //int audioDataNumFrames;
    VPAudioRingBuffer ringBuffer;
    uint64_t totalWrittenToRingBuf;
} VPSourceData;



static inline uint64_t samples_to_ns(size_t frames, uint_fast32_t rate)
{
    return frames * NSEC_PER_SEC / rate;
}

static inline uint64_t get_sample_time(size_t frames, uint_fast32_t rate)
{
    return os_gettime_ns() - samples_to_ns(frames, rate);
}

#define STARTUP_TIMEOUT_NS (500 * NSEC_PER_MSEC)


/* middle C */
static const double rate = 261.63/48000.0;

#ifndef M_PI
#define M_PI 3.1415926535897932384626433832795
#endif

#define M_PI_X2 M_PI*2


static void *vp_audio_driver_consumer_thread(void *pdata)
{
    VPSourceData *sd = pdata;
    uint64_t last_time = os_gettime_ns();
    int64_t lastReadSharedMemId = 0;
    uint64_t first_ts = 0;
    int64_t totalPackets = 0;
    int64_t totalFrames = 0;
    
    uint64_t lastShmAttempt = os_gettime_ns();
    vpAudio_createSharedMemoryFileIfNeeded_Consumer();
    
    const long bufSize = 20000;
    float buf[bufSize];
    
    long numWarningsAboutHeader = 0;
    
    VDPAudioCapture *localAudioCap = getLocalVDPAudioCapture();
    VDPAudioMixer *mixer = nil;
    if (localAudioCap) {
        mixer = [[VDPAudioMixer alloc] initWithAudioCapture:localAudioCap];
        
        mixer.capturedAudioDelayInSecs = g_vpAudioSourceSyncOffset_local;
        mixer.channel2AudioDelayInSecs = g_vpAudioSourceSyncOffset_remote;
        mixer.capturedAudioVolume = g_vpAudioSourceVolume_local;
        
        g_vpLocalAudioMixerObj = (__bridge void *)(mixer);
    }
    NSLog(@"VP audio source thread starting, local audio %p, mixer %p, sync offset for local audio %.3f, channel2 %.3f; local volume %.3f", localAudioCap, mixer, mixer.capturedAudioDelayInSecs, mixer.channel2AudioDelayInSecs, mixer.capturedAudioVolume);
    
    FILE *debugRecFile = NULL;
#if WRITE_AUDIO_DEBUG_FILE
    debugRecFile = fopen("/Users/pauli/temp/vpaudiorec.raw", "wb");
#endif
    
    
    while (os_event_try(sd->event) == EAGAIN) {
        if (!os_sleepto_ns(last_time += 500000))
            last_time = os_gettime_ns();
        
        if (!g_sharedMemPtr &&
            os_atomic_load_bool(&g_vpAudioSourceAlive) &&
            os_gettime_ns() - lastShmAttempt > 1000000000) {
            // try to open the mmap file again
            if (vpAudio_createSharedMemoryFileIfNeeded_Consumer()) {
                NSLog(@"%s: got shared mem file at runtime", __func__);
            }
            lastShmAttempt = os_gettime_ns();
        }
        
        if ( !vpAudio_shmem_checkValidMagicHeader()) {
            if (os_atomic_load_bool(&g_vpAudioSourceAlive) && ++numWarningsAboutHeader < 10) {
                NSLog(@"** %s: shmem file has invalid header", __func__);
            }
        }
        else {
            VPAudioSharedMemData *sharedMem = g_sharedMemPtr;
            //printf("trying to read sharedmem, msg id %ld\n", (long)sharedMem->msgId);
            if (sharedMem->msgId > lastReadSharedMemId) {
                //printf("... newest shared mem msg: %ld, datasize %d\n", (long)sharedMem->msgId, sharedMem->dataSize);
                lastReadSharedMemId = sharedMem->msgId;

                //int numFrames = sharedMem->dataSize / sizeof(float) / 2;
                
                // read latest ringbuffer data into local buffer
                long numFloatsRead = vpAudio_shmem_RingBufferReadAvailable(sharedMem, bufSize, buf);
                long numFrames = numFloatsRead / 2;
                
                
#if 0
                pthread_mutex_lock(&sd->audioDataLock);
                
                vpAudioRingBufferWrite(&sd->ringBuffer, numFrames*2, (float *)sharedMem->data);
                
                sd->totalWrittenToRingBuf += numFrames*2;
                
                pthread_mutex_unlock(&sd->audioDataLock);
#else
     
                if (mixer) {
                    long numSamples = numFrames*2;
                    
                    //[mixer mixInFloatSamples:buf count:numSamples];
                    
                    [mixer addChannel2FloatSamples:buf count:numSamples];
                    
                    long mixed = [mixer consumeFloatSamples:buf requestedCount:numSamples];
                    if (mixed != numSamples && mixed > 0) {
                        printf("** vp audio: mixed numsamples is different from input (%ld, input was %ld)\n", mixed, numSamples);
                    }
                    numFrames = mixed / 2;
                }

                
                if (numFrames > 0) {
                    if (debugRecFile) {
                        fwrite(buf, 1, numFrames*2*sizeof(float), debugRecFile);
                    }

                    struct obs_source_audio data;
                    //data.data[0] = (const uint8_t *)sharedMem->data;
                    data.data[0] = (const uint8_t *)buf;
                    data.speakers = SPEAKERS_STEREO;
                    data.frames = (int)numFrames;
                    data.samples_per_sec = 48000;
                    data.format = AUDIO_FORMAT_FLOAT;
                    data.timestamp = get_sample_time(data.frames, data.samples_per_sec);
                    
                    if ( !first_ts)
                        first_ts = data.timestamp + STARTUP_TIMEOUT_NS;
                    
                    if (data.timestamp > first_ts) {
                        if (os_atomic_load_bool(&sd->active) && os_atomic_load_bool(&g_vpAudioSourceAlive))
                            obs_source_output_audio(sd->source, &data);
                    }
                    
                    totalPackets++;
                    totalFrames += data.frames;
                    
                    
                }
                
                //NSLog(@"...audio consumer read %ld frames", numFrames);
#endif
            }
        }
    }
    
    if (g_sharedMemPtr) {
        munmap(g_sharedMemPtr, SHAREDMEM_FILE_SIZE);
        g_sharedMemPtr = NULL;
    }
    
    if (g_sharedMemFd) {
        // don't unlink on consumer side
        // shm_unlink(SHAREDMEM_FILENAME);
        g_sharedMemFd = 0;
    }
    
    if (debugRecFile) fclose(debugRecFile);
    
    return NULL;
}


static void *vp_audio_source_thread(void *pdata)
{
    VPSourceData *sd = pdata;
    uint64_t last_time = os_gettime_ns();
    uint64_t ts = 0;
    float cos_val = 0.0;
    float buf[1024*2];
    
    while (os_event_try(sd->event) == EAGAIN) {
        if (!os_sleepto_ns(last_time += 10000000))
            last_time = os_gettime_ns();
        
        if (!os_atomic_load_bool(&sd->active))
            continue;
        
        int numFrames = 480;
        for (size_t i = 0; i < numFrames; i++) {
            cos_val += rate * M_PI_X2;
            if (cos_val > M_PI_X2)
                cos_val -= M_PI_X2;
            
            float wave = cosf(cos_val) * 0.5f;
            buf[i*2] = (wave+1.0f)*0.5f;
            buf[i*2+1] = (wave+1.0f)*0.5f;
        }
#if 1
        pthread_mutex_lock(&sd->audioDataLock);
        
        /*
        if (sd->audioData) {
            numFrames = MIN(1024, sd->audioDataNumFrames);
            memcpy(buf, sd->audioData, numFrames * 2 *sizeof(float));
        }*/
        if (sd->totalWrittenToRingBuf > 1000) {
            vpAudioRingBufferRead(&sd->ringBuffer, numFrames*2, buf);
        }
        
        pthread_mutex_unlock(&sd->audioDataLock);
#endif
        
        struct obs_source_audio data;
        data.data[0] = (const uint8_t *)buf;
        data.frames = numFrames;
        data.speakers = SPEAKERS_STEREO;
        data.samples_per_sec = 48000;
        data.timestamp = ts;
        data.format = AUDIO_FORMAT_FLOAT;
        obs_source_output_audio(sd->source, &data);
        
        ts += 10000000;
    }
    
    return NULL;
}

/*
static void copyFloatAudioToObs(float *srcBuf, size_t numSamples, VPSourceData *sd)
{
    uint64_t timeNow = os_gettime_ns();
    uint64_t elapsedTime = timeNow - sd->startTime;
    
    printf("%s, num samples %ld -- frames %ld\n", __func__, numSamples, numSamples / 2);
    
    struct obs_source_audio data;
    data.data[0] = (void *)srcBuf;
    data.frames = (int)numSamples / 2;
    data.speakers = SPEAKERS_STEREO;
    data.samples_per_sec = 44100;
    data.timestamp = elapsedTime;
    data.format = AUDIO_FORMAT_FLOAT;
    obs_source_output_audio(sd->source, &data);
}
*/

//static double g_last = 0.0;

static CFDataRef msgPortReceivedDataCb(CFMessagePortRef msgPort, SInt32 msgid, CFDataRef cfData, void *info)
{
    VPSourceData *sd = info;
    NSData *inData = (__bridge NSData *)cfData;
    
    const size_t expectedDataSize = 16 * 2 * sizeof(float);
    
    if (inData.length < expectedDataSize) {
        NSLog(@"** %s: invalid data from audio driver (%ld)", __func__, inData.length);
        return NULL;
    }
    
    double t0 = CFAbsoluteTimeGetCurrent();
    
#if 1
    float *inAudio = (float *)inData.bytes;
    int numFrames = (int)inData.length / sizeof(float) / 2;
    
    //printf("%s, num samples %ld -- frames %ld\n", __func__, numSamples, numSamples / 2);
    
    if ((0)) {
        // TEST: print out max/min values in input data
        float maxL = -FLT_MAX;
        float maxR = -FLT_MAX;
        float *buf = inAudio;
        for (int i = 0; i < numFrames; i++) {
            float l = buf[0];
            float r = buf[1];
            buf += 2;
            maxL = MAX(maxL, l);
            maxR = MAX(maxR, r);
        }
        
        printf("numframes %d, datasize %ld; maxL %.5f, maxR %.5f\n", numFrames, inData.length, maxL, maxR);
    }
    
    pthread_mutex_lock(&sd->audioDataLock);
    
    //copyFloatAudioToObs(inAudio, numSamples, sd);
    
    /*
    if ( !sd->audioData || sd->audioDataNumFrames != numFrames) {
        bfree(sd->audioData);
        sd->audioData = bzalloc(numFrames*2*sizeof(float));
        sd->audioDataNumFrames = numFrames;
    }
    memcpy(sd->audioData, inAudio, inData.length);
     */
    
    vpAudioRingBufferWrite(&sd->ringBuffer, numFrames*2, inAudio);
    
    sd->totalWrittenToRingBuf += numFrames*2;
    
    
    pthread_mutex_unlock(&sd->audioDataLock);
    
#else
    //dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    renderTestData(sd);
    //});
#endif
    
    return NULL;
}


/* ------------------------------------------------------------------------- */

static const char *vp_audio_source_getname(void *unused)
{
    return "Vidpresso Audio Driver";
}

static void vp_audio_source_destroy(void *data)
{
    struct VPSourceData *sd = data;
    
    if (sd) {
        os_atomic_set_bool(&sd->active, false);
        
        if (sd->initialized_thread) {
            void *ret;
            os_event_signal(sd->event);
#if 0
            pthread_join(sd->source_thread, &ret);
#endif
            pthread_join(sd->driver_consumer_thread, &ret);
        }
        
        os_event_destroy(sd->event);
        
        if (sd->msgPort) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), sd->localPortSrc, kCFRunLoopCommonModes);
            CFRelease(sd->localPortSrc), sd->localPortSrc = NULL;
            
            CFRelease(sd->msgPort), sd->msgPort = NULL;
        }
        
        bfree(sd);
    }
}

static void *vp_audio_source_create(obs_data_t *settings,
                             obs_source_t *source)
{
    struct VPSourceData *sd = bzalloc(sizeof(struct VPSourceData));
    sd->source = source;

    pthread_mutex_init_value(&sd->audioDataLock);

    os_atomic_set_bool(&sd->active, true);
    
    sd->startTime = os_gettime_ns();
    
    sd->ringBuffer.bufferSize = 512*20;
    sd->ringBuffer.data = bmalloc(sd->ringBuffer.bufferSize * sizeof(float));
    
    NSLog(@"%s", __func__);
    
    if (os_event_init(&sd->event, OS_EVENT_TYPE_MANUAL) != 0)
        goto fail;
#if 0
    if (pthread_create(&sd->source_thread, NULL, vp_audio_source_thread, sd) != 0)
        goto fail;
#endif
    if (pthread_create(&sd->driver_consumer_thread, NULL, vp_audio_driver_consumer_thread, sd) != 0)
        goto fail;
    
    sd->initialized_thread = true;
    
#if 0
    CFMessagePortContext msgPortCtx;
    memset(&msgPortCtx, 0, sizeof(msgPortCtx));
    msgPortCtx.info = sd;
    
    CFMessagePortRef localPort = CFMessagePortCreateLocal(NULL, CFSTR(MSGPORTNAME), msgPortReceivedDataCb, &msgPortCtx, NULL);
    if ( !localPort) {
        printf("** %s: could not create local msgport\n", __func__);
    } else {
        sd->msgPort = localPort;
        
        sd->localPortSrc = CFMessagePortCreateRunLoopSource(NULL, localPort, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), sd->localPortSrc, kCFRunLoopCommonModes);
        
        NSLog(@"VP audio source created, localport '%s', msgport obj %p", MSGPORTNAME, localPort);
    }
#endif
    
#if 0
    char fifoPath[512];
    snprintf(fifoPath, 512, "/tmp/%s.fifo", MSGPORTNAME);
    
    if (0 != mkfifo(fifoPath, 0666)) {
        NSLog(@"** %s: mkfifo() failed with %d", __func__, errno);
    } else {
        NSLog(@"VP audio source fifo created (%s)", fifoPath);
    }
#endif
    
    
    
    UNUSED_PARAMETER(settings);
    return sd;
    
fail:
    vp_audio_source_destroy(sd);
    return NULL;
}

struct obs_source_info vp_audio_source_info = {
    .id           = VP_AUDIO_SOURCE_OBS_ID,
    .type         = OBS_SOURCE_TYPE_INPUT,
    .output_flags = OBS_SOURCE_AUDIO,
    .get_name     = vp_audio_source_getname,
    .create       = vp_audio_source_create,
    .destroy      = vp_audio_source_destroy,
};

void vp_audio_source_register() {
    obs_register_source(&vp_audio_source_info);
}
