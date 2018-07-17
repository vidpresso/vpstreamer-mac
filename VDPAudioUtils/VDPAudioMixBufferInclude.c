//
//  VDPAudioMixBufferInclude.c
//  VidpressoStation
//
//  Created by Pauli Ojala on 21/09/16.
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


#include "VDPAudioMixBuffer.h"


// HARDCODED: assumed sample rate for all devices
#define SAMPLERATE 48000



static void initMixBuffer(VDPAudioMixBuffer *mixBuf)
{
    memset(mixBuf, 0, sizeof(VDPAudioMixBuffer));
    
    mixBuf->capacity = SAMPLERATE * 10;
    mixBuf->sampleData = (float *)calloc(mixBuf->capacity, sizeof(float));
}


static void appendToMixBuffer(VDPAudioMixBuffer *mixBuf, float *data, long dataLen)
{
    if (dataLen < 1 || dataLen > mixBuf->capacity)
        return;
    
    if (mixBuf->writePos + dataLen > mixBuf->capacity) {
        long moveOffset = MIN(mixBuf->readPos, mixBuf->writePos);
        moveOffset = MAX(moveOffset, dataLen);
        
        long moveAmount = mixBuf->writePos - moveOffset;
        if (moveAmount < 1)
            moveAmount = mixBuf->capacity - moveOffset;
        
        //printf("%s, %p: moving from offset %ld, amount %ld (readpos %ld, writepos %ld)\n", __func__, mixBuf, moveOffset, moveAmount, mixBuf->readPos, mixBuf->writePos);
        
        if (moveAmount > 0)
            memmove(mixBuf->sampleData, mixBuf->sampleData + moveOffset, moveAmount*sizeof(float));
        
        mixBuf->readPos = MAX(0, mixBuf->readPos - moveOffset);
        mixBuf->writePos = MAX(0, mixBuf->writePos - moveOffset);
    }
    
    memcpy(mixBuf->sampleData + mixBuf->writePos, data, dataLen*sizeof(float));
    
    mixBuf->writePos += dataLen;
    mixBuf->totalSamplesWritten += dataLen;
    
    //printf("%s, %p: writepos now %ld (%ld)\n", __func__, mixBuf, mixBuf->writePos, mixBuf->capacity);
}

