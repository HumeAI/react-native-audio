#ifndef RNASamplePlayer_h
#define RNASamplePlayer_h

#import <React/RCTBridgeModule.h>

#import "RNAudioException.h"

@interface RNASamplePlayer: NSObject
- (id) init:(OnError)onError
isSpeakerOutput:(BOOL)isSpeakerOutput;

- (void) load:(NSString*)name
     fromPath:(NSString*)path
      resolve:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject;

- (void) play:(NSString*)sampleName
         loop:(BOOL)loop
      resolve:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject;

- (void) stop:(NSString*)sampleName
      resolve:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject;

- (void) unload:(NSString*)sampleName
        resolve:(RCTPromiseResolveBlock)resolve
         reject:(RCTPromiseRejectBlock)reject;

- (void) setIsSpeakerOutput:(BOOL)isSpeakerOutput;

+ (RNASamplePlayer*) samplePlayerWithError:(OnError)onError isSpeakerOutput:(BOOL)isSpeakerOutput;
@end // RNASamplePlayer

#endif /* RNASamplePlayer_h */
