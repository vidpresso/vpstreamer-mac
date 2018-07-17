//
//  vp_obs_source.c
//  VidpressoStation
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

#import <Cocoa/Cocoa.h>
#import "VPEncodingHelperAppDelegate.h"
#import <Lacqit/LQStreamTimeWatcher.h>

#include "vp_obs_source.h"
#include <obs.h>
#include <obs-module.h>
#include <util/platform.h>
#include <util/threading.h>


char *g_encodingLogFileStr = NULL;


#define MSGPORTNAME "com.vidpresso.EncodingHelperVideoOutput"


/*
typedef struct {
    double *times;
    size_t size;
    size_t cursor;
} VPFrameTimingLog;

static bool VPFrameTimingLogAppend(VPFrameTimingLog *log, double t)
{
    if ( !log) return false;
    if (log->cursor >= log->size - 1) return false;
    
    log->times[log->cursor] = t;
    log->cursor++;
    
    return true;
}

static void VPFrameTimingLogPrintDebugInfo(VPFrameTimingLog *log)
{
    if ( !log || log->cursor < 2) return;
    
    double minIntv =
    
    NSLog(@"frame timing: ");
}
 */

// for debugging
static LQStreamTimeWatcher *g_rendTimeWatcher = nil;
static LQStreamTimeWatcher *g_rendDurWatcher = nil;
static LQStreamTimeWatcher *g_ioSurfAcqWatcher = nil;
static FILE *g_encodingLogFile = NULL;


typedef struct {
    obs_source_t *source;
    CFMessagePortRef msgPort;
    CFRunLoopSourceRef localPortSrc;
    
    pthread_mutex_t frameBufLock;
    uint8_t *frameBuf;
    int32_t frameW;
    int32_t frameH;
    
    int64_t frameIdx;
    double lastWrittenFrameT;
} VPSourceData;



static VPSourceDataCallback g_dataCb = NULL;
static void *g_dataCbUserData = NULL;

static void renderTestData(VPSourceData *sd);


static void debug_writeWhiteToObs(VPSourceData *sd)
{
    int w = sd->frameW;
    int h = sd->frameH;
    uint32_t rowBytes = w * 4;
    uint8_t *buf = malloc(rowBytes * h);
    
    memset(buf, 200, rowBytes * h);
    
    struct obs_source_frame obsFrame = {
        .data     = { [0] = buf },
        .linesize = { [0] = rowBytes },
        .width    = w,
        .height   = h,
        .format   = VIDEO_FORMAT_RGBA
    };
    
    obsFrame.timestamp = os_gettime_ns();
    
    obs_source_output_video(sd->source, &obsFrame);
    
    VPEncodingHelperAppDelegate *appDelegate = [NSApp delegate];
    [appDelegate vpSourceHasNewFrame:buf width:w height:h rowBytes:rowBytes qtPixelFormat:0x52474241];
    
    free(buf);
}

static void readIOSurfaceAndWriteToObs(VPSourceData *sd, IOSurfaceID surfaceId, double *pIoSurfLockT)
{
    double t0 = (double)os_gettime_ns() / NSEC_PER_SEC;
    IOSurfaceRef ioSurface = IOSurfaceLookup(surfaceId);
    uint8_t *buf = NULL;
    int32_t w = 0;
    int32_t h = 0;
    uint32_t pxf = 0;
    uint32_t rowBytes = 0;
    
    if ( !ioSurface) {
        NSLog(@"** %s: could not get iosurface %d", __func__, surfaceId);
        return;
    }
    
    IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    buf = IOSurfaceGetBaseAddress(ioSurface);
    w = (int)IOSurfaceGetWidth(ioSurface);
    h = (int)IOSurfaceGetHeight(ioSurface);
    pxf = IOSurfaceGetPixelFormat(ioSurface);
    rowBytes = (int)IOSurfaceGetBytesPerRow(ioSurface);
    
    double t1 = (double)os_gettime_ns() / NSEC_PER_SEC;
    if (pIoSurfLockT) *pIoSurfLockT = t1 - t0;
    
    //NSLog(@"iosurface size %d * %d, pxf %d", w, h, pxf);
    
    int obsFormat;
    if (pxf == 0x52474241) {  // QT-style 'RGBA' fourcc
        obsFormat = VIDEO_FORMAT_RGBA;
    }
    else if (pxf == 32) {
        // !! QT-style ARGB; not directly in libobs, so this format would need swapping
        obsFormat = VIDEO_FORMAT_RGBA;
    }
    else {
        obsFormat = VIDEO_FORMAT_BGRA;
    }
    
    struct obs_source_frame obsFrame = {
        .data     = { [0] = buf },
        .linesize = { [0] = rowBytes },
        .width    = w,
        .height   = h,
        .format   = obsFormat
    };

    obsFrame.timestamp = os_gettime_ns();
    
    obs_source_output_video(sd->source, &obsFrame);
    
    VPEncodingHelperAppDelegate *appDelegate = [NSApp delegate];
    [appDelegate vpSourceHasNewFrame:buf width:w height:h rowBytes:rowBytes qtPixelFormat:pxf];
    
    IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(ioSurface);
    
}


//static double g_last = 0.0;

static CFDataRef msgPortReceivedDataCb(CFMessagePortRef msgPort, SInt32 msgid, CFDataRef cfData, void *info)
{
    VPSourceData *sd = info;
    NSData *inData = (__bridge NSData *)cfData;
    
    if (inData.length < 4) {
        NSLog(@"** %s: invalid data from main app (%ld)", __func__, inData.length);
        return NULL;
    }
    
    double t0 = (double)os_gettime_ns() / NSEC_PER_SEC;
    
#if 1
    uint8_t *buf = (uint8_t *)inData.bytes;
    uint32_t surfaceId = *((uint32_t *)buf);
    
    if (t0 - sd->lastWrittenFrameT > (1.0/61.0)) {
        double ioSurfLockT = -1.0;
        readIOSurfaceAndWriteToObs(sd, surfaceId, &ioSurfLockT);
        //debug_writeWhiteToObs(sd);
        
        double t1 = (double)os_gettime_ns() / NSEC_PER_SEC;
        
        sd->lastWrittenFrameT = t0;
        sd->frameIdx++;
        
        if (sd->frameIdx > 8) { // skip first few frames
            [g_rendTimeWatcher addSampleRefTime:t0 withID:sd->frameIdx];
            [g_rendDurWatcher addInterval:t1 - t0 withID:sd->frameIdx];
            [g_ioSurfAcqWatcher addInterval:ioSurfLockT withID:sd->frameIdx];
        }
    
        if (sd->frameIdx % 100 == 0) {
            NSMutableString *s = [NSMutableString string];
            
            NSDateFormatter *dateFmt = [[NSDateFormatter alloc] init];
            [dateFmt setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US"]];
            [dateFmt setDateFormat:@"yyyy-MM-dd' 'HHmmss"];
            NSString *dateStr = [dateFmt stringFromDate:[NSDate date]];
            
            [s appendFormat:@"Encoder output summary at %@:  avg %.2f ms, min %.2f ms, max %.2f ms, variance %f\n",
             dateStr, 1000*[g_rendTimeWatcher averageInterval], 1000*[g_rendTimeWatcher minInterval], 1000*[g_rendTimeWatcher maxInterval], [g_rendTimeWatcher intervalVariance]];
            
            [s appendFormat:@" ... encoding time watcher contents:\n%@\n", g_rendTimeWatcher.debugContentsString];
            
            //[s appendFormat:@" ... ipcRead+output interval watcher contents:\n%@\n", g_rendDurWatcher.debugContentsString];

            //[s appendFormat:@" ... ipc data lock interval watcher contents:\n%@\n", g_ioSurfAcqWatcher.debugContentsString];
            
            [s appendString:@"\n"];

            NSLog(@"%@", s);
            
            if (g_encodingLogFileStr) {
                const char *utf8 = s.UTF8String;
                size_t utf8Len = strlen(utf8);
                
                if ( !g_encodingLogFile) {
                    g_encodingLogFile = fopen(g_encodingLogFileStr, "a");
                }
                
                fwrite(utf8, 1, utf8Len, g_encodingLogFile);
            }
        }
    }
    
    
#else
    //dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    renderTestData(sd);
    //});
#endif
    
    //double t2 = (double)os_gettime_ns() / NSEC_PER_SEC;
    
    //double timeSinceLast = (g_last > 0.0) ? (t0 - g_last) : -1.0;
    //g_last = t0;
    
    //NSLog(@"iosurface copied in %.3f ms, time since last %.3f ms", 1000*(t2-t0), 1000*timeSinceLast);
    
    if (g_dataCb) {
        g_dataCb(g_dataCbUserData);
    }
    
    return NULL;
}

static NSInteger s_v = 0;

static void renderTestData(VPSourceData *sd)
{
    //NSLog(@"%s", __func__);

    pthread_mutex_lock(&sd->frameBufLock);

    uint8_t *buf = sd->frameBuf;
    if ( !buf) {
        pthread_mutex_unlock(&sd->frameBufLock);
        return;
    }

    NSInteger w = sd->frameW;
    NSInteger h = sd->frameH;
    size_t rowBytes = w * 4;
    
    for (NSInteger y = 0; y < h; y++) {
        uint8_t *dst = buf + rowBytes*y;
        for (NSInteger x = 0; x < w; x++) {
            dst[0] = y+s_v;
            dst[1] = 128+s_v;
            dst[2] = 255+s_v;
            dst[3] = 255;
            dst += 4;
        }
    }
    s_v++;
    
    struct obs_source_frame obsFrame = {
        .data     = { [0] = sd->frameBuf },
        .linesize = { [0] = (int)rowBytes },
        .width    = (int)w,
        .height   = (int)h,
        .format   = VIDEO_FORMAT_RGBA
    };
    
    double ts = os_gettime_ns() / 1000000000.0;
    
    ts = (ts*60.0 + 0.5) / 60.0;
    
    obsFrame.timestamp = ts*1000000000.0;
    
    obs_source_output_video(sd->source, &obsFrame);
    
    pthread_mutex_unlock(&sd->frameBufLock);
    
#if TEST_RENDER_USING_GENPATTERN
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1.0/60.0) * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        renderTestData(sd);
    });
#endif
}


static const char *vp_get_name(void *unused)
{
    UNUSED_PARAMETER(unused);
    return "Vidpresso Live Video";
}

static void *vp_create(obs_data_t *settings, obs_source_t *source)
{
    VPSourceData *sd = bzalloc(sizeof(VPSourceData));
    
    sd->source = source;

    int w = (int)obs_data_get_int(settings, "w");
    int h = (int)obs_data_get_int(settings, "h");
    
    sd->frameW = (w > 0) ? w : 1280;
    sd->frameH = (h > 0) ? h : 720;
    sd->frameBuf = bmalloc(sd->frameW * 4 * sd->frameH);
    
    pthread_mutex_init_value(&sd->frameBufLock);
    
    g_rendTimeWatcher = [[LQStreamTimeWatcher alloc] initWithCapacity:100];
    [g_rendTimeWatcher setIsFIFO:YES];
    
    g_rendDurWatcher = [[LQStreamTimeWatcher alloc] initWithCapacity:100];
    [g_rendDurWatcher setIsFIFO:YES];
    [g_rendDurWatcher setRecordsIntervals:YES];
    
    g_ioSurfAcqWatcher = [[LQStreamTimeWatcher alloc] initWithCapacity:100];
    [g_ioSurfAcqWatcher setIsFIFO:YES];
    [g_ioSurfAcqWatcher setRecordsIntervals:YES];

#if TEST_RENDER_USING_GENPATTERN
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        renderTestData(sd);
    });

#else

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

        NSLog(@"VP source created, localport '%s', msgport obj %p", MSGPORTNAME, localPort);
    }

#endif

    return sd;
}

static void vp_destroy(void *data)
{
    VPSourceData *sd = data;
    if (sd) {
        NSLog(@"%s, msgport %p", __func__, sd->msgPort);
        if (sd->msgPort) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), sd->localPortSrc, kCFRunLoopCommonModes);
            CFRelease(sd->localPortSrc), sd->localPortSrc = NULL;
            
            CFRelease(sd->msgPort), sd->msgPort = NULL;
        }
        
        pthread_mutex_lock(&sd->frameBufLock);
        if (sd->frameBuf) {
            bfree(sd->frameBuf), sd->frameBuf = NULL;
        }
        pthread_mutex_unlock(&sd->frameBufLock);
        
        bfree(sd);
    }
}

static void vp_update(void *data, obs_data_t *settings)
{
    VPSourceData *sd = data;
    if ( !sd) return;
    
    int w = (int)obs_data_get_int(settings, "w");
    int h = (int)obs_data_get_int(settings, "h");
    
    NSLog(@"%s, size %d * %d", __func__, w, h);
    
    pthread_mutex_lock(&sd->frameBufLock);
    
    if (sd->frameBuf) bfree(sd->frameBuf);
    
    sd->frameW = (w > 0) ? w : 1280;
    sd->frameH = (h > 0) ? h : 720;
    sd->frameBuf = bmalloc(sd->frameW * 4 * sd->frameH);
    
    pthread_mutex_unlock(&sd->frameBufLock);
}

struct obs_source_info vp_source_info = {
    .id             = VP_SOURCE_OBS_ID,
    .type           = OBS_SOURCE_TYPE_INPUT,
    .output_flags   = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_DO_NOT_DUPLICATE,
    .get_name       = vp_get_name,
    .create         = vp_create,
    .destroy        = vp_destroy,
    .update         = vp_update,
};


void vp_source_register(VPSourceDataCallback dataCb, void *userData)
{
    g_dataCb = dataCb;
    g_dataCbUserData = userData;
    
    obs_register_source(&vp_source_info);
}

