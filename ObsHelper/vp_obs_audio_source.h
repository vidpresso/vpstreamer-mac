//
//  vp_obs_audio_source.h
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

#ifndef vp_obs_audio_source_h
#define vp_obs_audio_source_h

#include <stdio.h>



#define VP_AUDIO_SOURCE_OBS_ID "vp-audio-driver"


// delays applied to local and remote audio (unit is seconds)
extern volatile double g_vpAudioSourceSyncOffset_local;
extern volatile double g_vpAudioSourceSyncOffset_remote;
extern volatile double g_vpAudioSourceVolume_local;

extern volatile bool g_vpAudioSourceAlive;

extern void *g_vpLocalAudioCaptureObj;
extern void *g_vpLocalAudioMixerObj;


void vp_audio_source_register();


#endif /* vp_obs_audio_source_h */
