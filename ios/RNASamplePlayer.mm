#import "RNASamplePlayer.h"

#import <AVFoundation/AVFoundation.h>

@interface RNAOutputStream: NSObject

- (id) init:(AVAudioEngine*)engine
     sample:(AVAudioPCMBuffer*)sample
       loop:(BOOL)loop;

- (void) play:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject
       isSpeakerOutput:(BOOL)isSpeakerOutput;

- (void) stop;

@end // RNAOutputStream

@implementation RNAOutputStream {
  AVAudioPlayerNode *player;
  NSTimer *timer;
  RCTPromiseResolveBlock resolveBlock;
  RCTPromiseRejectBlock rejectBlock;
}

- (id) init:(AVAudioEngine*)engine
     sample:(AVAudioPCMBuffer *)sample
       loop:(BOOL)loop
{
  player = [[AVAudioPlayerNode alloc] init];
  [engine attachNode:player];
    
  [engine connect:player to:engine.mainMixerNode format:sample.format];

  [player scheduleBuffer:sample
                  atTime:nil
                 options:loop ? AVAudioPlayerNodeBufferLoops : 0
  completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
       completionHandler:^(AVAudioPlayerNodeCompletionCallbackType) {
      if (self->resolveBlock) {
        self->resolveBlock(nil);
        self->resolveBlock = nil;
      }
      // NOTE: Node detachment should be done async, otherwise it just hangs,
      // presumably because the engine waits till completion handler exists
      // before it assumes the node can be detached.
    dispatch_async(dispatch_get_main_queue(), ^(void) {
      [engine detachNode:self->player];
    });
  }];
    
  return self;
}

- (void) play:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject
       isSpeakerOutput:(BOOL)isSpeakerOutput
{
  NSError *error;
  AVAudioEngine *engine = player.engine;
    
  self->resolveBlock = resolve;
  self->rejectBlock = reject;
    
  if (engine.running != YES && [engine startAndReturnError:&error] != YES) {
    [[RNAudioException fromError:error] reject:reject];
    return;
  }
    
  [player play];
    
    if (isSpeakerOutput) {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error];
        [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
        /*
         The output audio port overrides are needed here for playback with echo cancellation to function properly.
         Apple developer forum post here: https://forums.developer.apple.com/forums/thread/721535
         No one seems to knows why and Apple doesn't seem to acknowledge that this is an issue.
         */
        
        if (error) {
            [[RNAudioException fromError:error] reject:reject];
            return;
        }
    }
    
}

- (void) stop
{
    [player stop];
    if (self->resolveBlock) {
        self->resolveBlock(nil);
        self->resolveBlock = nil;
    }
    return;
}

@end // RNAOutputStream

@implementation RNASamplePlayer {
  OnError onError;
  AVAudioEngine *engine;
  NSMutableDictionary<NSString*,AVAudioPCMBuffer*> *samples;
  RNAOutputStream *activeStream;
  BOOL isSpeakerOutput;
}

/**
 * Inits RNASamplePlayer instance.
 */
- (id) init:(OnError)onError
       isSpeakerOutput:(BOOL)isSpeakerOutput;
{
  self->onError = onError;
  self->isSpeakerOutput = isSpeakerOutput;
  engine = [[AVAudioEngine alloc] init];
  samples = [NSMutableDictionary new];
  return self;
}



- (void) load:(NSString*)name
     fromPath:(NSString*)path
      resolve:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject
{
  NSURL *url = [NSURL fileURLWithPath:path];
  if ([url checkResourceIsReachableAndReturnError:nil] == NO) {
    [[RNAudioException OPERATION_FAILED:@"Invalid sample path"] reject:reject];
    return;
  }

  NSError *error;
  AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&error];
  if (error != nil) {
    [[RNAudioException OPERATION_FAILED:error.localizedDescription]
     reject:reject];
    return;
  }

  AVAudioPCMBuffer *sample = [[AVAudioPCMBuffer alloc]
                              initWithPCMFormat:file.processingFormat
                              frameCapacity:file.length];

  if (![file readIntoBuffer:sample error:&error]) {
    [[RNAudioException OPERATION_FAILED:error.localizedDescription]
     reject:reject];
    return;
  }

  samples[name] = sample;
  resolve(nil);
}

- (void) play:(NSString *)sampleName
         loop:(BOOL)loop
      resolve:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject
{
  [self stop:@"" resolve:nil reject:nil];

  AVAudioPCMBuffer *sample = samples[sampleName];
  if (sample == nil) {
    [RNAudioException UNKNOWN_SAMPLE_NAME:reject];
    return;
  }

  activeStream = [[RNAOutputStream alloc]
                  init:engine
                  sample:sample
                  loop:loop];
  [activeStream play:resolve reject:reject isSpeakerOutput:self->isSpeakerOutput];
}

- (void) stop:(NSString*)sampleName
      resolve:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject
{
  if (activeStream != nil) {
    [activeStream stop];
    activeStream = nil;
  }
  if (resolve != nil) resolve(nil);
}

- (void) unload:(NSString *)sampleName
        resolve:(RCTPromiseResolveBlock)resolve
         reject:(RCTPromiseRejectBlock)reject
{
  if (samples[sampleName] == nil) {
    [RNAudioException UNKNOWN_SAMPLE_NAME:reject];
    return;
  }

  [samples removeObjectForKey:sampleName];
  resolve(nil);
}

- (void) setIsSpeakerOutput:(BOOL)isSpeakerOutput
{
    if (self->isSpeakerOutput == isSpeakerOutput) return;
    
    self->isSpeakerOutput = isSpeakerOutput;
    
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error;
    if (isSpeakerOutput) {
        [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
    } else {
        [session overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error];
    }
    
    if(error) {
        self->onError(error.localizedDescription);
    }
}


/**
 * Creates a new RNASamplePlayer instance.
 */
+ (RNASamplePlayer *)samplePlayerWithError:(OnError)onError isSpeakerOutput:(BOOL)isSpeakerOutput {
    return [[RNASamplePlayer alloc] init:onError isSpeakerOutput:isSpeakerOutput];
}

@end // RNASamplePlayer
