#import <React/RCTLog.h>

#import "ReactNativeAudio.h"
#import "RNAudioException.h"
#import "RNAInputAudioStream.h"
#import "RNASamplePlayer.h"

NSString *EVENT_AUDIO_CHUNK = @"RNA_AudioChunk";
NSString *EVENT_INPUT_AUDIO_STREAM_ERROR = @"RNA_InputAudioStreamError";
NSString *EVENT_SAMPLE_PLAYER_ERROR = @"RNA_SamplePlayerError";

@implementation ReactNativeAudio {
  NSMutableDictionary<NSNumber*,RNAInputAudioStream*> *inputStreams;
  NSMutableDictionary<NSNumber*,RNASamplePlayer*> *samplePlayers;
  NSMutableData *audioBuffer;
  
}

RCT_EXPORT_MODULE()

- (instancetype) init {
  inputStreams = [NSMutableDictionary new];
  samplePlayers = [NSMutableDictionary new];
    audioBuffer = [NSMutableData new];
  return [super init];
}

- (NSDictionary *) constantsToExport {
  return @{
    @"AUDIO_FORMAT_PCM_16BIT": [NSNumber numberWithInt:PCM_16BIT],
    @"AUDIO_FORMAT_PCM_FLOAT": [NSNumber numberWithInt:PCM_FLOAT],
    @"AUDIO_SOURCE_DEFAULT": [NSNumber numberWithInt:DEFAULT],
    @"AUDIO_SOURCE_MIC": [NSNumber numberWithInt:MIC],
    @"AUDIO_SOURCE_UNPROCESSED": [NSNumber numberWithInt:UNPROCESSED],
    @"CHANNEL_IN_MONO": [NSNumber numberWithInt:MONO],
    @"CHANNEL_IN_STEREO": [NSNumber numberWithInt:STEREO],
    @"IS_MAC_CATALYST": @(TARGET_OS_MACCATALYST)
  };
}

- (NSDictionary*) getConstants {
  return [self constantsToExport];
}

RCT_REMAP_METHOD(getInputAvailable,
  getInputAvailable:(RCTPromiseResolveBlock)resolve
  reject:(RCTPromiseRejectBlock)reject
) {
  resolve([NSNumber numberWithBool: AVAudioSession.sharedInstance.inputAvailable]);
}

/**
 *  Creates a dedicated queue for module operations.
 */
- (dispatch_queue_t)methodQueue
{
  return dispatch_queue_create("hume.ai.react_native_audio", DISPATCH_QUEUE_SERIAL);
}

- (NSArray<NSString*>*)supportedEvents
{
  return @[
    EVENT_AUDIO_CHUNK,
    EVENT_INPUT_AUDIO_STREAM_ERROR,
    EVENT_SAMPLE_PLAYER_ERROR
  ];
}

- (void)registerAVAudioSessionObservers {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center addObserver:self selector:@selector(handleRouteChange:) name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:self selector:@selector(handleAudioInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
}

- (void)unregisterAVAudioSessionObservers {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleAudioRouting {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    
    AudioSessionIO ioConfig = getBestFitAudioPorts(session, &error);
    
    if (error) {
        [RNAudioException fromError:error];
        return;
    }
    
    BOOL speakerOutput = [ioConfig.output.portType isEqual:AVAudioSessionPortBuiltInSpeaker];
    
    for (id key in samplePlayers) {
        RNASamplePlayer *player = [samplePlayers objectForKey:key];
        [player setIsSpeakerOutput:speakerOutput];
    }
    
    [session setPreferredInput:ioConfig.input error:&error];
    
    if (error) {
        [RNAudioException fromError:error];
        return;
    }
    
    if ([inputStreams count] == 1) {
        id key = [[inputStreams allKeys] firstObject];
        RNAInputAudioStream *stream = [inputStreams objectForKey:key];
        [stream reconfigureInputEngine];
    }
}

- (void)handleRouteChange:(NSNotification *)notification {
    AVAudioSessionRouteChangeReason reason = (AVAudioSessionRouteChangeReason)[notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];

    switch (reason) {
        case AVAudioSessionRouteChangeReasonUnknown:
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
        case AVAudioSessionRouteChangeReasonCategoryChange:
        case AVAudioSessionRouteChangeReasonWakeFromSleep:
        case AVAudioSessionRouteChangeReasonRouteConfigurationChange:
            @synchronized (self) {
                [self handleAudioRouting];
            }
            break;
        case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory:
        case AVAudioSessionRouteChangeReasonOverride:
            break;
    }
}

- (void)handleAudioInterruption:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    AVAudioSessionInterruptionType interruptionType = (AVAudioSessionInterruptionType)[userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    
    AVAudioSession *session = [AVAudioSession sharedInstance];
    
    switch (interruptionType) {
        case AVAudioSessionInterruptionTypeBegan:
            [session setActive:NO error:nil];
            break;
        case AVAudioSessionInterruptionTypeEnded: {
            [self configureAudioSessionWithError:nil];
            break;
        }
    }
}



typedef struct {
    AVAudioSessionPortDescription *input;
    AVAudioSessionPortDescription *output;
} AudioSessionIO;

/// Get the best fit audio ports based on the available I/O in the session. Always prefer I/O routes and fall back to built-ins (assuming that if the user has a device connected they want to use it)
AudioSessionIO getBestFitAudioPorts(AVAudioSession *session, NSError **error) {
    
    AudioSessionIO io = { nil, nil };
    
    // Observe current output route to determine best configuration. We can not programmatically change/access the full list of available outputs
    // as we can inputs outside of an MPVolumeView component.
    NSArray<AVAudioSessionPortDescription *> *outputs = [session currentRoute].outputs;
    NSArray<AVAudioSessionPortDescription *> *inputs = [session availableInputs];
    
    if (inputs.count == 0 || outputs.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.hume.rnaudio" code:100 userInfo:@{ NSLocalizedDescriptionKey: @"No available input or output devices in current session." }];
        }
        return io;
    }
    
    if (outputs.count > 1) { // I am not 100% confident this is correct, but I _think_ we can only have multiple output routes with AVAudioSessionCategoryMultiRoute
        if (error) {
            *error = [NSError errorWithDomain:@"com.hume.rnaudio" code:100 userInfo:@{ NSLocalizedDescriptionKey: @"Multiple output routes in current session"}];
        }
        return io;
    }
    
    io.output = outputs.firstObject;
    
    AVAudioSessionPort outputPortType = outputs.firstObject.portType;
    
    // Check for a matching input port type. This would imply an I/O port (https://developer.apple.com/documentation/avfaudio/avaudiosessionport#3591390)
    // These ports provide input and output so we'd want them to match. (Bluetooth, CarPlay, etc.)
    for (AVAudioSessionPortDescription *port in inputs) {
        if ([port.portType isEqual:outputPortType]) {
            io.input = port;
            return io;
        }
    }
    
    // No matching I/O port so check inputs again for any non built-in type. This would imply a wired microphone or other line-in device
    for (AVAudioSessionPortDescription *port in inputs) {
        if (![port.portType isEqual:AVAudioSessionPortBuiltInMic]) {
            io.input = port;
            return io;
        }
    }
    
    // By process of elimination we know that the input is the built-in mic and the only input, so grab the first port in the list
    io.input = inputs.firstObject;
    
    return io;
}

- (void)configureAudioSessionWithError:(NSError **)error {
  RCTLogInfo(@"Audio session configuration...");
    
  AVAudioSession *audioSession = AVAudioSession.sharedInstance;
  NSArray<AVAudioSessionCategory> *cats = audioSession.availableCategories;

  AVAudioSessionCategory category;
  if ([cats containsObject:AVAudioSessionCategoryPlayAndRecord]) {
    category = AVAudioSessionCategoryPlayAndRecord;
  } else {
    if (error) {
      *error = [NSError errorWithDomain:@"incompatible_audio_session"
                                   code:1001
                               userInfo:@{NSLocalizedDescriptionKey: @"neither play-and-record, nor playback category is supported"}];
    }
    return;
  }

  AVAudioSessionCategoryOptions options =
    AVAudioSessionCategoryOptionAllowBluetooth |
    AVAudioSessionCategoryOptionAllowBluetoothA2DP |
    AVAudioSessionCategoryOptionDefaultToSpeaker;

  if (@available(iOS 14.5, *)) {
    options |= AVAudioSessionCategoryOptionOverrideMutedMicrophoneInterruption;
  }

  // In below function calls, error pointer is populated for us
  BOOL res = [audioSession setCategory:category
                           withOptions:options
                                 error:error];
  if (!res) {
    return;
  }

  res = [audioSession setActive:YES error:error];
  if (!res) {
    return;
  }
}



// TODO: Should we somehow plug-in this audio system configuration into
// AudioStream initialization, and base it on the "audioSource" parameter,
// which is now ignored on iOS?
RCT_REMAP_METHOD(configAudioSystem,
  configAudioSystem:(RCTPromiseResolveBlock)resolve
  reject:(RCTPromiseRejectBlock)reject
) {

    NSLog(@"INITIAL CONFIG");
  NSError *error = nil;
  [self configureAudioSessionWithError:&error];

  if (error) {
    reject(error.domain, error.localizedDescription, error);
    return;
  }

  resolve(nil);
}



// NOTE: Can't use enum as the argument type here, as RN won't understand that.
RCT_REMAP_METHOD(listen,
  listen:(double)streamId
  audioSource:(double)audioSource
  sampleRate:(double)sampleRate
  channelConfig:(double)channelConfig
  audioFormat:(double)audioFormat
  samplingSize:(double)samplingSize
  resolve:(RCTPromiseResolveBlock) resolve
  reject:(RCTPromiseRejectBlock) reject
) {
  NSNumber *sid = [NSNumber numberWithDouble:streamId];
  [self registerAVAudioSessionObservers];
    
/// audioBuffer code is for saving tapped bytes in the device document directory for de-bugging. It was cumbersome finding this code again any time I wanted to check the taps
/// Woth noting that this only fires when the stream is not muted, resulting in sped-up and choppy audio if the device is struggling to keep up with the RN bridge
//   [audioBuffer setLength:0];
    
//    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
//    NSString *documentsDirectory = [paths firstObject];
//
//    NSFileManager *fileManager = [NSFileManager defaultManager];
//    NSArray *documentFiles = [fileManager contentsOfDirectoryAtPath:documentsDirectory error:nil];
//    for (NSString *file in documentFiles) {
//      NSString *filePath = [documentsDirectory stringByAppendingPathComponent:file];
//      [fileManager removeItemAtPath:filePath error:nil];
//        RCTLogInfo(@"Removed file at path %@",filePath);
//    }
    
  OnChunk onChunk = ^void(int chunkId, unsigned char *chunk, int size) {
    NSData* data = [NSData dataWithBytesNoCopy:chunk
                                        length:size
                                  freeWhenDone:NO];
      
//  [audioBuffer appendBytes:chunk length:size];
      
    [self sendEventWithName:EVENT_AUDIO_CHUNK
                       body:@{@"streamId":sid,
                              @"chunkId":@(chunkId),
                              @"data":[data base64EncodedStringWithOptions:0]}];
  };
  
  OnError onError = ^void(NSString* error) {
    [self sendEventWithName:EVENT_INPUT_AUDIO_STREAM_ERROR
                       body:@{@"streamId":sid, @"error":error}];
  };
  
  RNAInputAudioStream *stream =
  [RNAInputAudioStream streamAudioSource:(AUDIO_SOURCES)audioSource
                              sampleRate:sampleRate
                           channelConfig:(CHANNEL_CONFIGS)channelConfig
                             audioFormat:(AUDIO_FORMATS)audioFormat
                            samplingSize:samplingSize
                                 onChunk:onChunk
                                 onError:onError];
  
  inputStreams[sid] = stream;
  resolve(nil);
}

RCT_REMAP_METHOD(unlisten,
  unlisten:(double)streamId
  resolve:(RCTPromiseResolveBlock) resolve
  reject:(RCTPromiseRejectBlock) reject
) {
    NSNumber *id = [NSNumber numberWithDouble:streamId];
/// Second part of saving tapped audio
//    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
//    NSString *documentsDirectory = [paths firstObject];
//
//    NSString *wavFilePath = [documentsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"audio_%@.wav", id]];
//
//    [self saveWAVFile:audioBuffer sampleRate:44100 numChannels:1 bitsPerSample:16 toPath:wavFilePath]; // 44.1k mono PCM16
//
//    [audioBuffer setLength:0];
    
    [inputStreams[id] stop];
    [inputStreams removeObjectForKey:id];
    [self unregisterAVAudioSessionObservers];
      
    RCTLogInfo(@"[Stream %@] Is unlistened", id);
      
    resolve(nil);
}

typedef struct {
    char chunkID[4];       // "RIFF"
    int chunkSize;         // Size of the entire file in bytes minus 8 bytes for the two fields not included in this count: chunkID and chunkSize.
    char format[4];        // "WAVE"
    char subchunk1ID[4];   // "fmt "
    int subchunk1Size;     // 16 for PCM. This is the size of the rest of the Subchunk which follows this number.
    short audioFormat;     // PCM = 1 (i.e. Linear quantization). Values other than 1 indicate some form of compression.
    short numChannels;     // Number of channels. Mono = 1, Stereo = 2, etc.
    int sampleRate;        // Sample rate (e.g., 44100, 48000, etc.)
    int byteRate;          // SampleRate * NumChannels * BitsPerSample/8
    short blockAlign;      // NumChannels * BitsPerSample/8
    short bitsPerSample;   // Number of bits per sample (usually 16 or 24)
    char subchunk2ID[4];   // "data"
    int subchunk2Size;     // NumSamples * NumChannels * BitsPerSample/8
} WAVHeader;

// This and above struct used for saving tapped audio
- (void)saveWAVFile:(NSData *)pcmData sampleRate:(int)sampleRate numChannels:(int)numChannels bitsPerSample:(int)bitsPerSample toPath:(NSString *)filePath {
    WAVHeader header;
    int pcmDataSize = (int)[pcmData length];

    memcpy(header.chunkID, "RIFF", 4);
    header.chunkSize = 36 + pcmDataSize;
    memcpy(header.format, "WAVE", 4);
    memcpy(header.subchunk1ID, "fmt ", 4);
    header.subchunk1Size = 16;
    header.audioFormat = 1; // PCM
    header.numChannels = numChannels;
    header.sampleRate = sampleRate;
    header.byteRate = sampleRate * numChannels * bitsPerSample / 8;
    header.blockAlign = numChannels * bitsPerSample / 8;
    header.bitsPerSample = bitsPerSample;
    memcpy(header.subchunk2ID, "data", 4);
    header.subchunk2Size = pcmDataSize;

    NSMutableData *wavData = [NSMutableData dataWithBytes:&header length:sizeof(WAVHeader)];
    [wavData appendData:pcmData];
    [wavData writeToFile:filePath atomically:YES];

    RCTLogInfo(@"WAV file saved at: %@", filePath);
}


RCT_REMAP_METHOD(muteInputStream,
  muteInputStream:(double)streamId muted:(BOOL)muted
) {
  inputStreams[[NSNumber numberWithDouble:streamId]].muted = muted;
}

RCT_EXPORT_METHOD(destroySamplePlayer:(double)playerId
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  NSNumber *id = [NSNumber numberWithDouble:playerId];
  if (samplePlayers[id] == nil) {
    [RNAudioException UNKNOWN_PLAYER_ID:reject];
    return;
  }

  [samplePlayers removeObjectForKey:id];
  resolve(nil);
}

RCT_EXPORT_METHOD(initSamplePlayer:(double)playerId
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  NSNumber *id = [NSNumber numberWithDouble:playerId];
    if (samplePlayers.count > 0) { // We only need 1 sample player, and this init block is being called multiple times per session from somewhere upstream.
        resolve(nil);
        return;
    }
    
  if (samplePlayers[id] != nil) {
    [[RNAudioException INTERNAL_ERROR:0
                              details:@"Sample player ID is occupied"]
     reject:reject];
    return;
  }

  OnError onError = ^void(NSString *error) {
    [self sendEventWithName:EVENT_SAMPLE_PLAYER_ERROR
                       body:@{@"playerId":id, @"error":error}];
  };
    
  NSError *error = nil;
  AVAudioSession *session = [AVAudioSession sharedInstance];
    
  AudioSessionIO ioConfig = getBestFitAudioPorts(session, &error);
    
  if (error) {
      [[RNAudioException fromError:error] reject:reject];
      return;
  }
    
  BOOL speakerOutput = [ioConfig.output.portType isEqual:AVAudioSessionPortBuiltInSpeaker];

  samplePlayers[id] = [RNASamplePlayer samplePlayerWithError:onError isSpeakerOutput:speakerOutput];
  resolve(nil);
}

RCT_EXPORT_METHOD(loadSample:(double)playerId
                  sampleName:(NSString *)sampleName
                  samplePath:(NSString *)samplePath
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  NSNumber *id = [NSNumber numberWithDouble:playerId];
  RNASamplePlayer *player = samplePlayers[id];
  if (player == nil) {
    [RNAudioException UNKNOWN_PLAYER_ID:reject];
    return;
  }
  [player load:sampleName fromPath:samplePath resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(playSample:(double)playerId
                  sampleName:(NSString *)sampleName
                  loop:(BOOL)loop
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  NSNumber *id = [NSNumber numberWithDouble:playerId];
  RNASamplePlayer *player = samplePlayers[id];
  if (player == nil) {
    [RNAudioException UNKNOWN_PLAYER_ID:reject];
    return;
  }

  [player play:sampleName loop:loop resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(stopSample:(double)playerId
                  sampleName:(NSString *)sampleName
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  NSNumber *id = [NSNumber numberWithDouble:playerId];
  RNASamplePlayer *player = samplePlayers[id];
  if (player == nil) {
    [RNAudioException UNKNOWN_PLAYER_ID:reject];
    return;
  }
  [player stop:sampleName resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(unloadSample:(double)playerId
                  sampleName:(NSString *)sampleName
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  NSNumber *id = [NSNumber numberWithDouble:playerId];
  RNASamplePlayer *player = samplePlayers[id];
  if (player == nil) {
    [RNAudioException UNKNOWN_PLAYER_ID:reject];
    return;
  }
  [player unload:sampleName resolve:resolve reject:reject];
}

+ (BOOL) requiresMainQueueSetup {
    return NO;
}

// Don't compile this code when we build for the old architecture.
#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeReactNativeAudioSpecJSI>(params);
}
#endif

@end
