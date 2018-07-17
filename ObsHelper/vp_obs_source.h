//
//  vp_obs_source.h
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

#ifndef vp_obs_source_h
#define vp_obs_source_h


#define VP_SOURCE_OBS_ID "vp-live-input"

#define TEST_RENDER_USING_GENPATTERN 0


extern char *g_encodingLogFileStr;


typedef void (*VPSourceDataCallback)(void *userData);


void vp_source_register(VPSourceDataCallback dataCb, void *userData);


#endif /* vp_obs_source_h */
