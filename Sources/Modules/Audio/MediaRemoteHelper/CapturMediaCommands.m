#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <unistd.h>
#import "MediaRemoteAdapter.h"
#import "adapter/get.h"
#import "adapter/globals.h"
#import "adapter/now_playing.h"
#import "private/MediaRemote.h"
#import "utility/helpers.h"

// Read-only CoreAudio inspection: never stop, mute, or reconfigure another process.
// A browser that is also capturing microphone/audio input is left alone.
static BOOL capturHasNoActiveInput(NSDictionary *session) {
    AudioObjectPropertyAddress listAddress = { kAudioHardwarePropertyProcessObjectList,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &listAddress, 0, NULL, &size) != noErr) return NO;
    if (size == 0) return YES;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &listAddress, 0, NULL, &size, data.mutableBytes) != noErr) return NO;
    AudioObjectID *processes = data.mutableBytes;
    for (UInt32 index = 0; index < size / sizeof(AudioObjectID); index++) {
        AudioObjectPropertyAddress pidAddress = { kAudioProcessPropertyPID,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        pid_t pid = 0;
        UInt32 pidSize = sizeof(pid);
        if (AudioObjectGetPropertyData(processes[index], &pidAddress, 0, NULL, &pidSize, &pid) != noErr) continue;
        AudioObjectPropertyAddress bundleAddress = { kAudioProcessPropertyBundleID,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CFStringRef rawBundle = NULL;
        UInt32 bundleSize = sizeof(rawBundle);
        AudioObjectGetPropertyData(processes[index], &bundleAddress, 0, NULL, &bundleSize, &rawBundle);
        NSString *bundle = CFBridgingRelease(rawBundle);
        BOOL matches = pid == [session[@"processIdentifier"] intValue] ||
            (bundle && ([bundle isEqual:session[@"bundleIdentifier"]] ||
                        [bundle isEqual:session[@"parentApplicationBundleIdentifier"]]));
        if (!matches) continue;
        AudioObjectPropertyAddress inputAddress = { kAudioProcessPropertyIsRunningInput,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 input = 0;
        UInt32 inputSize = sizeof(input);
        if (AudioObjectGetPropertyData(processes[index], &inputAddress, 0, NULL, &inputSize, &input) != noErr || input != 0) return NO;
    }
    return YES;
}

// Check inside the entitled helper, rather than relying on a potentially stale
// snapshot taken by the app before spawning it. Commands are explicit, never toggle.
void captur_guarded_command(void) {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSData *expectedData = [env[@"CAPTUR_MEDIA_IDENTITY"] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *expected = expectedData ? [NSJSONSerialization JSONObjectWithData:expectedData options:0 error:nil] : nil;
    BOOL pause = [env[@"CAPTUR_MEDIA_COMMAND"] isEqualToString:@"pause"];
    BOOL play = [env[@"CAPTUR_MEDIA_COMMAND"] isEqualToString:@"play"];
    if ((!pause && !play) || ![expected isKindOfClass:NSDictionary.class] ||
        !expected[@"processIdentifier"] || !expected[@"bundleIdentifier"] || !expected[@"title"]) {
        fail(@"Invalid guarded command");
    }
    NSDictionary *current = internal_get(NO);
    if (!current || ![current[@"playing"] isKindOfClass:NSNumber.class] ||
        [current[@"playing"] boolValue] != pause) {
        fail(@"Playback state changed");
    }
    NSData *allowedData = [env[@"CAPTUR_MEDIA_ALLOWED_BUNDLES"] dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *allowed = allowedData ? [NSJSONSerialization JSONObjectWithData:allowedData options:0 error:nil] : nil;
    if (![allowed isKindOfClass:NSArray.class] ||
        (![allowed containsObject:current[@"bundleIdentifier"] ?: @""] &&
         ![allowed containsObject:current[@"parentApplicationBundleIdentifier"] ?: @""]) ||
        !capturHasNoActiveInput(current)) {
        fail(@"Recording, unknown capture state, or unsupported playback client");
    }
    for (NSString *key in expected) {
        if (![current[key] isEqual:expected[key]]) {
            fail(@"Playback session changed");
        }
    }
    NSString *permit = env[@"CAPTUR_MEDIA_PERMIT"];
    // Capture edges revoke this file while internal_get is waiting. Check at
    // dispatch, not merely when the helper was launched.
    if (!permit.length || access(permit.fileSystemRepresentation, F_OK) != 0) {
        fail(@"Capture changed before command dispatch");
    }
    if (!g_mediaRemote.sendCommand(pause ? kMRPause : kMRPlay, nil)) {
        fail(@"Playback command refused");
    }
    // Acceptance is not completion. Poll only state, never resend the command.
    // Once dispatched, keep confirming even if the capture permit is revoked:
    // Captur must still learn about a pause it needs to restore.
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2.0;
    do {
        NSDictionary *after = internal_get(NO);
        if (!after) fail(@"Playback confirmation unavailable");
        for (NSString *key in expected) {
            if (![after[key] isEqual:expected[key]]) fail(@"Playback session changed during confirmation");
        }
        if ([after[@"playing"] isKindOfClass:NSNumber.class] && [after[@"playing"] boolValue] == play) {
            NSString *json = serializeJsonDictionarySafe(after, false);
            if (!json) fail(@"Playback confirmation could not be serialized");
            printOut(json);
            return;
        }
        usleep(50000);
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    fail(@"Playback state did not confirm before deadline");
}
