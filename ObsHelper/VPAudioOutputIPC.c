//
//  VPAudioOutputIPC.c
//  VidpressoStation
//
//  Created by Pauli Ojala on 21/07/16.
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


/*
 This file provides the shared memory IPC link between the Vidpresso audio driver and the encoding helper.
 
 NOTE: this file is meant to be included in code, not compiled separately.
 */


#include <sys/mman.h>
#include <fcntl.h>


#define SHAREDMEM_FILENAME      "vp_encodinghelper"

#define SHAREDMEM_HEADER_SIZE   (sizeof(int64_t) + sizeof(size_t) + sizeof(long)*2)
#define SHAREDMEM_DATA_SIZE     (32*1024)
#define SHAREDMEM_FILE_SIZE     (SHAREDMEM_HEADER_SIZE + SHAREDMEM_DATA_SIZE)

#define SHAREDMEM_MAGIC_NUM     (uint64_t)0xc0c1c2c3badabebe

static int g_sharedMemFd = 0;
static void *g_sharedMemPtr = NULL;

typedef struct {
    uint64_t magic;
    int64_t msgId;
    //int32_t dataSize;
    //uint8_t data[SHAREDMEM_SIZE - 8 - 4];
    
    // ring buffer data; size and position values are in float increments
    size_t bufferSize;
    long writerPosition;
    long readerPosition;
    long unconsumed;  // means "written but not yet read"
    float data[SHAREDMEM_DATA_SIZE / sizeof(float)];
    
} VPAudioSharedMemData;


static void *vpAudio_createSharedMemoryFileIfNeeded_Producer()
{
    if ( !g_sharedMemFd) {
        NSLog(@"%s...", __func__);
        int shm_fd = shm_open(SHAREDMEM_FILENAME, O_CREAT | O_RDWR, 0666);
        
        if (shm_fd == -1) {
            NSLog(@"** couldn't create shmem, errno %d", errno);
        }
        else {
            NSLog(@"%s: shm_open success, writing shmem file (fd %i)", __func__, shm_fd);
            
            ftruncate(shm_fd, SHAREDMEM_FILE_SIZE);  // may fail, doesn't matter
            
            void *shm_ptr = mmap(0, SHAREDMEM_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
            if (shm_ptr == MAP_FAILED) {
                NSLog(@"** %s: mmap failed, errno %d", __func__, errno);
            } else {
                g_sharedMemFd = shm_fd;
                g_sharedMemPtr = shm_ptr;
                
                VPAudioSharedMemData *data = g_sharedMemPtr;
                memset(data, 0, SHAREDMEM_FILE_SIZE);
                data->magic = SHAREDMEM_MAGIC_NUM;
                data->bufferSize = SHAREDMEM_DATA_SIZE / sizeof(float);
                
                NSLog(@"shared mem ptr created and cleared");
            }
        }
    }
    return g_sharedMemPtr;
}

static void *vpAudio_createSharedMemoryFileIfNeeded_Consumer()
{
    if ( !g_sharedMemFd) {
        NSLog(@"%s...", __func__);
        int shm_fd = shm_open(SHAREDMEM_FILENAME, O_RDWR, 0666);
        
        if (shm_fd == -1) {
            NSLog(@"** couldn't create shmem, errno %d", errno);
        }
        else {
            NSLog(@"%s: shm_open success, writing shmem file (fd %i)", __func__, shm_fd);
            
            void *shm_ptr = mmap(0, SHAREDMEM_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
            if (shm_ptr == MAP_FAILED) {
                NSLog(@"** %s: mmap failed, errno %d", __func__, errno);
            } else {
                g_sharedMemFd = shm_fd;
                g_sharedMemPtr = shm_ptr;
                
                VPAudioSharedMemData *data = g_sharedMemPtr;
                memset(data, 0, SHAREDMEM_FILE_SIZE);
                data->magic = SHAREDMEM_MAGIC_NUM;
                data->bufferSize = SHAREDMEM_DATA_SIZE / sizeof(float);
            }
        }
    }
    return g_sharedMemPtr;
}


static bool vpAudio_shmem_checkValidMagicHeader()
{
    if ( !g_sharedMemPtr)
        return false;
    
    VPAudioSharedMemData *data = g_sharedMemPtr;
    
    uint64_t magic = SHAREDMEM_MAGIC_NUM;
    
    return (0 == memcmp(&magic, &(data->magic), 8));
}



#ifndef VPAUDIORINGBUF_ADVANCE
  #define VPAUDIORINGBUF_ADVANCE(rb_, p_, n_) \
                    *(p_) += n_; \
                    if (*(p_) >= rb_->bufferSize) *(p_) = 0;
#endif


static long vpAudio_shmem_RingBufferReadAvailable(VPAudioSharedMemData *rb, long maxCount, float *dst)
{
    if ( !rb || !dst || maxCount < 1 || rb->unconsumed < 1) return 0;
    
    long consumed = 0;
    long count = MIN(maxCount, rb->unconsumed);
    
    if (rb->unconsumed > count) {
        VPAUDIORINGBUF_ADVANCE(rb, &rb->readerPosition, rb->unconsumed - count);
        rb->unconsumed = count;
    }
    
    long availEnd = rb->bufferSize - rb->readerPosition;
    long n1 = MIN(count, availEnd);
    count -= n1;
    
    memcpy(dst, rb->data + rb->readerPosition, n1*sizeof(float));
    dst += n1;
    
    VPAUDIORINGBUF_ADVANCE(rb, &rb->readerPosition, n1);
    consumed += n1;
    
    if (count > 0) {
        long n2 = MIN(count, rb->bufferSize);
        consumed += n2;
        
        memcpy(dst, rb->data + rb->readerPosition, n2*sizeof(float));
        
        VPAUDIORINGBUF_ADVANCE(rb, &rb->readerPosition, n2);
        consumed += n2;
    }
    rb->unconsumed -= consumed;
    return consumed;
}

static void vpAudio_shmem_RingBufferWrite(VPAudioSharedMemData *rb, long count, float *src)
{
    if ( !rb || !src || count < 1) return;
    
    if (rb->unconsumed >= rb->bufferSize - 1) {
        printf("%s: buffer overflowing (no consumer), will reset now\n", __func__);
        rb->unconsumed = 0;
        rb->writerPosition = 0;
        rb->readerPosition = 0;
    }
    
    long availEnd = rb->bufferSize - rb->writerPosition;
    long n1 = MIN(count, availEnd);
    count -= n1;
    
    long written = 0;
    
    memcpy(rb->data + rb->writerPosition, src, n1*sizeof(float));
    src += n1;
    VPAUDIORINGBUF_ADVANCE(rb, &rb->writerPosition, n1);
    written += n1;
    
    if (count > 0) {
        long n2 = MIN(count, rb->bufferSize);
        
        memcpy(rb->data + rb->writerPosition, src, n2*sizeof(float));
        
        VPAUDIORINGBUF_ADVANCE(rb, &rb->readerPosition, n2);
        written += n2;
    }
    
    rb->unconsumed += written;
}



