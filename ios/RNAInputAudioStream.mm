#import "RNAInputAudioStream.h"

#import <AVFoundation/AVFoundation.h>
#import <React/RCTLog.h>

@implementation RNAInputAudioStream {
  BOOL destroyed;
  int chunkId;
  OnChunk onChunk;
  OnError onError;
  AVAudioEngine *audioEngine;
}

- (id)initWithAudioSource:(enum AUDIO_SOURCES)audioSource
           withSampleRate:(int)sampleRate
        withChannelConfig:(enum CHANNEL_CONFIGS)channelConfig
          withAudioFormat:(enum AUDIO_FORMATS)audioFormat
         withSamplingSize:(int)samplingSize
                  onChunk:(OnChunk)onChunk
                  onError:(OnError)onError
{
  self = [super init];
    if (self) {
        
        self->onChunk = onChunk;
        self->onError = onError;
        

      audioEngine = [[AVAudioEngine alloc] init];
      AVAudioInputNode *inputNode = [audioEngine inputNode];
    
        
        NSError *error = nil;
        
        if (@available(iOS 13.0, *)) { // Not sure if there's a better place for this, but it silences the warning in Xcode as is.
            [inputNode setVoiceProcessingEnabled:YES error:&error];
        } else {
            onError(@"Unsupported iOS version! You must be on version >= 13.0");
            return nil;
        }
        
        AVAudioFormat *inputNodeFormat = [inputNode outputFormatForBus:0];
        NSLog(@"Native input audio format: %@", inputNodeFormat);
        
        AVAudioCommonFormat commonFormat;
        if (audioFormat == PCM_16BIT) {
            commonFormat = AVAudioPCMFormatInt16;
        } else {
            // PCM_FLOAT
            commonFormat = AVAudioPCMFormatFloat32;
        }
        
        
      AVAudioFormat *desiredFormat = [[AVAudioFormat alloc] initWithCommonFormat:commonFormat
                                                               sampleRate:sampleRate
                                                                 channels:(channelConfig == MONO ? 1 : 2)
                                                              interleaved:NO];
       NSLog(@"Desired input audio format: %@", desiredFormat);
        
        // This converter could be further configured, but the default settings are quite good imo
        AVAudioConverter *audioConverter = [[AVAudioConverter alloc] initFromFormat:inputNodeFormat toFormat:desiredFormat];
        if (audioConverter == nil) {
            onError(@"Conversion to desired format is not possible! Please ensure your stream settings and device capabilities are aligned.");
            return nil;
        }
        

        float sampleRateCoefficient = inputNodeFormat.sampleRate / desiredFormat.sampleRate;
        
        // A desired frame of size @samplingSize at sample rate @sampleRate can be obtained as below.
        // We have limited influence over the input format from the hardware, so we will defer our conversions to the AVAudioConverter
        UInt32 convertedBufferSize = UInt32(samplingSize * sampleRateCoefficient);
        
        [inputNode installTapOnBus:0 bufferSize:convertedBufferSize format:inputNodeFormat block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            
            buffer.frameLength = convertedBufferSize; // The bufferSize argument above is usually ignored. Setting the frameLength like this forces the correct sizing
        
            // Since we are taking the given samplingSize to be in terms of output format, we don't need to adjust frameCapacity on the converted buffer
            AVAudioPCMBuffer *convertedBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:desiredFormat frameCapacity:(AVAudioFrameCount)samplingSize];
            
            AVAudioConverterInputBlock inputBlock = ^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumPackets, AVAudioConverterInputStatus *outStatus) {
                *outStatus = AVAudioConverterInputStatus_HaveData;
                return buffer;
            };
            
            NSError *conversionError = nil;
            AVAudioConverterOutputStatus status = [audioConverter convertToBuffer:convertedBuffer error:&conversionError withInputFromBlock:inputBlock];
            
            if (status != AVAudioConverterOutputStatus_HaveData) {
                onError([NSString stringWithFormat:@"Conversion error: %@", conversionError]);
                return;
            }

            const AudioBufferList *bufferList = convertedBuffer.audioBufferList;

            for (NSUInteger i = 0; i < bufferList->mNumberBuffers; i++) {
                AudioBuffer audioBuffer = bufferList->mBuffers[i];
                
                if (!self.muted) {
                    self->onChunk(self->chunkId, (unsigned char *) audioBuffer.mData,(unsigned int) audioBuffer.mDataByteSize);
                }

                // Increment chunkId for the next audio chunk.
                ++self->chunkId;
            }
        }];
        

      [audioEngine prepare];
      [audioEngine startAndReturnError:&error];
      if (error) {
          onError([NSString stringWithFormat:@"AVAudioEngine start error: %@", error]);
          return nil;
      }
        
    }
    
  return self;
}

- (void)dealloc {
    [self stop];
}

- (void)stop {
    if (audioEngine.isRunning) {
        [audioEngine.inputNode removeTapOnBus:0];
        [audioEngine stop];
    }
}


+ (RNAInputAudioStream*) streamAudioSource:(enum AUDIO_SOURCES)audioSource
                                sampleRate:(int)sampleRate
                             channelConfig:(enum CHANNEL_CONFIGS)channelConfig
                               audioFormat:(enum AUDIO_FORMATS)audioFormat
                              samplingSize:(int)samplingSize
                                   onChunk:(OnChunk)onChunk
                                   onError:(OnError)onError
{
  return [[RNAInputAudioStream alloc]
          initWithAudioSource:audioSource
          withSampleRate:sampleRate
          withChannelConfig:channelConfig
          withAudioFormat:audioFormat
          withSamplingSize:samplingSize
          onChunk:onChunk
          onError:onError];
}

@end
