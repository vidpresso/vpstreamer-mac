//
//  VDPAudioDeviceControl.h
//  VidpressoStation
//
//  Created by Pauli Ojala on 01/03/16.
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

@interface VDPAudioDeviceControl : NSObject {
    
    NSArray *_outputDevs;
}

+ (VDPAudioDeviceControl *)sharedDeviceControl;

@property (nonatomic, readonly) NSArray *allOutputDevices;

- (void)refreshOutputDevicesList;


@property (nonatomic, assign) NSString *defaultOutputAudioDevice;

@property (nonatomic, readonly) NSString *defaultInputAudioDevice;

@end
