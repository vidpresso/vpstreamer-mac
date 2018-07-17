//
//  VPObsStreamer.h
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

#import <Foundation/Foundation.h>


@interface VPObsServerDestination : NSObject
@property (nonatomic) NSString *url;
@property (nonatomic) NSString *key;
@end


@interface VPObsStreamer : NSObject

//@property (nonatomic) NSString *serverUrl;
//@property (nonatomic) NSString *serverKey;
@property (nonatomic) NSArray *serverDestinations;

@property (nonatomic) NSSize videoSize;

@property (nonatomic) BOOL useVidpressoAudioInput;
@property (nonatomic) BOOL mixLocalInputIntoVidpressoAudio;

@property (nonatomic) double audioSyncOffsetInSecs;

@property (nonatomic) int videoBitrate;
@property (nonatomic) int keyIntervalSecs;
@property (nonatomic) NSString *h264ProfileName;
@property (nonatomic) NSString *h264PresetName;
@property (nonatomic) NSString *h264EncoderOptionsString;

@property (nonatomic) int audioBitrate;

- (void)initObs;

- (BOOL)startStreaming;
- (void)stopStreaming;

@end
