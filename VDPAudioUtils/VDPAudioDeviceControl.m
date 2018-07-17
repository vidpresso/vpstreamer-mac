//
//  VDPAudioDeviceControl.m
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

#import "VDPAudioDeviceControl.h"
#import <CoreAudio/CoreAudio.h>



@implementation VDPAudioDeviceControl

+ (VDPAudioDeviceControl *)sharedDeviceControl
{
    static VDPAudioDeviceControl *s_obj = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_obj = [[self alloc] init];
    });
    return s_obj;
}



- (id)init
{
    self = [super init];
    
    [self refreshOutputDevicesList];
    
    NSLog(@"audio outputs: %@", _outputDevs);
    
    return self;
}

- (void)refreshOutputDevicesList
{
    [_outputDevs autorelease];
    _outputDevs = [[self _getOutputDevices] retain];
}

- (NSArray *)allOutputDevices
{
    return _outputDevs;
}

- (NSArray *)_getOutputDevices
{
    OSStatus result;
    UInt32 propSize;
    AudioObjectPropertyAddress propAddress;
    UInt32 size;
    
    // get the device list
    propAddress.mSelector = kAudioHardwarePropertyDevices;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    result = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddress, 0, NULL, &propSize);
    if (result) { printf("Error in AudioObjectGetPropertyDataSize: %d\n", result); return nil; }
    
    // Find out how many devices are on the system
    int numDevices = propSize / sizeof(AudioDeviceID);
    AudioDeviceID *deviceList = (AudioDeviceID*)calloc(numDevices, sizeof(AudioDeviceID));
    
    result = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &propSize, deviceList);
    if (result) { printf("Error in AudioObjectGetPropertyData: %d\n", result); return nil; }
    
    NSMutableArray *arr = [NSMutableArray array];
    
    for (UInt32 i = 0; i < numDevices; i++)
    {
        // get the number of channels of the device
        propAddress.mScope = kAudioDevicePropertyScopeOutput;
        propAddress.mSelector = kAudioDevicePropertyStreams;
        size = 0;
        result = AudioObjectGetPropertyDataSize(deviceList[i], &propAddress, 0, NULL, &size);
        
        if (size < 1)  // no wanted type of streams for this device
            continue;
        
        // get the device name
        CFStringRef cfStr;
        propSize = sizeof(CFStringRef);
        propAddress.mSelector = kAudioObjectPropertyName;
        propAddress.mScope = kAudioObjectPropertyScopeGlobal;
        propAddress.mElement = kAudioObjectPropertyElementMaster;
        result = AudioObjectGetPropertyData(deviceList[i], &propAddress, 0, NULL, &propSize, &cfStr);
        if (result) { printf("Error in AudioObjectGetPropertyData: %d\n", result); continue; }
        
        [arr addObject:(NSString *)cfStr];

        CFRelease(cfStr);
    }
    
    return arr;
}

- (NSString *)defaultOutputAudioDevice
{
    OSStatus result;
    UInt32 propSize;
    AudioObjectPropertyAddress propAddress;
    UInt32 size;
    
    // get the device list
    propAddress.mSelector = kAudioHardwarePropertyDevices;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    result = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddress, 0, NULL, &propSize);
    if (result) { printf("Error in AudioObjectGetPropertyDataSize: %d\n", result); return nil; }
    
    // Find out how many devices are on the system
    int numDevices = propSize / sizeof(AudioDeviceID);
    AudioDeviceID *deviceList = (AudioDeviceID*)calloc(numDevices, sizeof(AudioDeviceID));
    
    result = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &propSize, deviceList);
    if (result) { printf("Error in AudioObjectGetPropertyData: %d\n", result); return nil; }
    
    // find out the default
    AudioDeviceID defaultDevice = 0;
    propSize = sizeof(AudioDeviceID);
    propAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    result = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &propSize, &defaultDevice);
    if (result) { printf("Error in AudioObjectGetPropertyData: kAudioHardwarePropertyDefaultOutputDevice: %d\n", result); return nil; }
    
    for (UInt32 i = 0; i < numDevices; i++)
    {
        // get the number of channels of the device
        propAddress.mScope = kAudioDevicePropertyScopeOutput;
        propAddress.mSelector = kAudioDevicePropertyStreams;
        size = 0;
        result = AudioObjectGetPropertyDataSize(deviceList[i], &propAddress, 0, NULL, &size);
        
        if (size < 1)  // no wanted type of streams for this device
            continue;
        
        if (deviceList[i] == defaultDevice) {
            // get the device name
            CFStringRef cfStr;
            propSize = sizeof(CFStringRef);
            propAddress.mSelector = kAudioObjectPropertyName;
            propAddress.mScope = kAudioObjectPropertyScopeGlobal;
            propAddress.mElement = kAudioObjectPropertyElementMaster;
            result = AudioObjectGetPropertyData(deviceList[i], &propAddress, 0, NULL, &propSize, &cfStr);
            if (result) { printf("Error in AudioObjectGetPropertyData: %d\n", result); continue; }
            
            NSString *name = [[(__bridge NSString *)cfStr copy] autorelease];
            CFRelease(cfStr);
            
            return name;
        }
        
    }
    
    return nil;
}

- (void)setDefaultOutputAudioDevice:(NSString *)devName
{
    OSStatus result;
    UInt32 propSize;
    AudioObjectPropertyAddress propAddress;
    //UInt32 size;
    
    // get the device list
    propAddress.mSelector = kAudioHardwarePropertyDevices;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    result = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddress, 0, NULL, &propSize);
    if (result) { printf("Error in AudioObjectGetPropertyDataSize: %d\n", result); return; }
    
    // Find out how many devices are on the system
    int numDevices = propSize / sizeof(AudioDeviceID);
    AudioDeviceID *deviceList = (AudioDeviceID*)calloc(numDevices, sizeof(AudioDeviceID));
    
    result = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &propSize, deviceList);
    if (result) { printf("Error in AudioObjectGetPropertyData: %d\n", result); return; }
    
    BOOL found = NO;
    for (UInt32 i = 0; i < numDevices; i++)
    {
        // get the device name
        CFStringRef cfStr;
        propSize = sizeof(CFStringRef);
        propAddress.mSelector = kAudioObjectPropertyName;
        propAddress.mScope = kAudioObjectPropertyScopeGlobal;
        propAddress.mElement = kAudioObjectPropertyElementMaster;
        result = AudioObjectGetPropertyData(deviceList[i], &propAddress, 0, NULL, &propSize, &cfStr);
        if (result) { printf("Error in AudioObjectGetPropertyData: %d\n", result); continue; }
        
        if ([devName isEqualToString:(NSString *)cfStr]) {
            NSLog(@"setting default audio output to: '%@'", devName);
            found = YES;
            
            // we found the device, now it as the default output device
            propAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
            propAddress.mScope = kAudioObjectPropertyScopeGlobal;
            propAddress.mElement = kAudioObjectPropertyElementMaster;
            
            result = AudioObjectSetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, sizeof(AudioDeviceID), &deviceList[i]);
            if (result) { printf("Error in AudioObjectSetPropertyData: kAudioHardwarePropertyDefaultOutputDevice: %d\n", result); }
        }
        
        CFRelease(cfStr);
        
        if (found) break;
    }
}


- (NSString *)defaultInputAudioDevice
{
    OSStatus result;
    UInt32 propSize;
    AudioObjectPropertyAddress propAddress;
    UInt32 size;
    
    // get the device list
    propAddress.mSelector = kAudioHardwarePropertyDevices;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    result = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddress, 0, NULL, &propSize);
    if (result) { printf("Error in AudioObjectGetPropertyDataSize: %d\n", result); return nil; }
    
    // Find out how many devices are on the system
    int numDevices = propSize / sizeof(AudioDeviceID);
    AudioDeviceID *deviceList = (AudioDeviceID*)calloc(numDevices, sizeof(AudioDeviceID));
    
    result = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &propSize, deviceList);
    if (result) { printf("Error in AudioObjectGetPropertyData: %d\n", result); return nil; }
    
    // find out the default
    AudioDeviceID defaultDevice = 0;
    propSize = sizeof(AudioDeviceID);
    propAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = kAudioObjectPropertyElementMaster;
    
    result = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &propSize, &defaultDevice);
    if (result) { printf("Error in AudioObjectGetPropertyData: kAudioHardwarePropertyDefaultInputDevice: %d\n", result); return nil; }
    
    for (UInt32 i = 0; i < numDevices; i++)
    {
        // get the number of channels of the device
        propAddress.mScope = kAudioDevicePropertyScopeInput;
        propAddress.mSelector = kAudioDevicePropertyStreams;
        size = 0;
        result = AudioObjectGetPropertyDataSize(deviceList[i], &propAddress, 0, NULL, &size);
        
        if (size < 1)  // no wanted type of streams for this device
            continue;
        
        if (deviceList[i] == defaultDevice) {
            // get the device name
            CFStringRef cfStr;
            propSize = sizeof(CFStringRef);
            propAddress.mSelector = kAudioObjectPropertyName;
            propAddress.mScope = kAudioObjectPropertyScopeGlobal;
            propAddress.mElement = kAudioObjectPropertyElementMaster;
            result = AudioObjectGetPropertyData(deviceList[i], &propAddress, 0, NULL, &propSize, &cfStr);
            if (result) { printf("Error in AudioObjectGetPropertyData: %d\n", result); continue; }
            
            NSString *name = [[(__bridge NSString *)cfStr copy] autorelease];
            CFRelease(cfStr);
            
            return name;
        }
        
    }
    
    return nil;
}

@end
