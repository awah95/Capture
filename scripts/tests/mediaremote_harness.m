// Isolated native tests: every MediaRemote/CoreAudio entry point below is a fake.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import "adapter/globals.h"
#import "adapter/get.h"
#import "utility/helpers.h"
#import <unistd.h>

MediaRemote *g_mediaRemote;
dispatch_queue_t g_serialdispatchQueue;
static NSString *mode;
static int reads;
static bool sent;
@implementation MediaRemote
@end
void printOut(NSString *value) { puts(value.UTF8String); }
void printErrf(NSString *format, ...) {}
void fail(NSString *value) { fprintf(stderr, "%s\n", value.UTF8String); exit(1); }
NSString *serializeJsonDictionarySafe(NSDictionary *value, bool pretty) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] encoding:NSUTF8StringEncoding];
}

#ifdef TEST_GET
NSString *kMRMediaRemoteNowPlayingInfoServiceIdentifier = @"service";
NSString *getEnvOption(NSString *value) { return nil; }
void makePayloadHumanReadable(NSMutableDictionary *value) {}
bool appForPID(int pid, void (^block)(NSRunningApplication *)) { return false; }
NSDictionary *convertNowPlayingInformation(NSDictionary *info, bool a, bool b, bool c) { return @{}; }
static void pidQuery(dispatch_queue_t q, MRMediaRemoteGetNowPlayingApplicationPIDCompletion_t callback) {
    if ([mode isEqual:@"empty"]) callback(0);
}
static void clientQuery(dispatch_queue_t q, MRMediaRemoteGetNowPlayingClientCompletion_t callback) {
    if ([mode isEqual:@"empty"]) callback(nil);
}
static void playingQuery(dispatch_queue_t q, MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion_t callback) {
    if ([mode isEqual:@"empty"]) callback(false);
}
static void infoQuery(dispatch_queue_t q, MRMediaRemoteGetNowPlayingInfoCompletion_t callback) {
    if ([mode isEqual:@"empty"]) callback(nil);
}
#else
OSStatus AudioObjectGetPropertyDataSize(AudioObjectID a, const AudioObjectPropertyAddress *b, UInt32 c, const void *d, UInt32 *size) {
    *size = 0; return noErr;
}
OSStatus AudioObjectGetPropertyData(AudioObjectID a, const AudioObjectPropertyAddress *b, UInt32 c, const void *d, UInt32 *size, void *data) {
    return noErr;
}
NSDictionary *internal_get(BOOL test) {
    reads++;
    if ([mode isEqual:@"revoke"] || (sent && [mode isEqual:@"revoke-after"])) unlink(getenv("CAPTUR_MEDIA_PERMIT"));
    BOOL play = [NSProcessInfo.processInfo.environment[@"CAPTUR_MEDIA_COMMAND"] isEqual:@"play"];
    BOOL after = sent && reads >= 4 && ![mode isEqual:@"unchanged"];
    return @{@"bundleIdentifier":@"com.apple.Music", @"processIdentifier":@123,
             @"title": sent && [mode isEqual:@"changed"] ? @"Other" : @"Track",
             @"playing": @(after ? play : !play)};
}
static bool sendCommand(MRCommand command, id info) { sent = true; fputs("SENT\n", stderr); return true; }
void waitForCommandCompletion(void) {}
void adapter_get_env(void) { printOut(serializeJsonDictionarySafe(internal_get(NO), false)); }
void captur_guarded_command(void);
#endif

@interface FakeRemote : MediaRemote
@end
@implementation FakeRemote
#ifdef TEST_GET
- (MRMediaRemoteGetNowPlayingApplicationPID_t)getNowPlayingApplicationPID { return pidQuery; }
- (MRMediaRemoteGetNowPlayingClient_t)getNowPlayingClient { return clientQuery; }
- (MRMediaRemoteGetNowPlayingApplicationIsPlaying_t)getNowPlayingApplicationIsPlaying { return playingQuery; }
- (MRMediaRemoteGetNowPlayingInfo_t)getNowPlayingInfo { return infoQuery; }
#else
- (MRMediaRemoteSendCommand_t)sendCommand { return sendCommand; }
#endif
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
        mode = [NSString stringWithUTF8String:argv[1]];
        g_mediaRemote = [FakeRemote new];
        g_serialdispatchQueue = dispatch_queue_create("fake", DISPATCH_QUEUE_SERIAL);
#ifdef TEST_GET
        extern void adapter_get_env(void);
        adapter_get_env();
#else
        captur_guarded_command();
#endif
    }
    return 0;
}
