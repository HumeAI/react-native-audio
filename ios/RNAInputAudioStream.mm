#import "RNAInputAudioStream.h"

#import <AVFoundation/AVFoundation.h>
#import <React/RCTLog.h>

@implementation RNAInputAudioStream {
  BOOL destroyed;
  int chunkId;
  OnChunk onChunk;
  OnError onError;
  AVAudioEngine *audioEngine;
  AVAudioFormat *desiredFormat;
  int _samplingSize;
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
        self->_samplingSize = samplingSize;

        if (![self setupAudioEngineWithSampleRate:sampleRate channelCount:(channelConfig == MONO ? 1 : 2) audioFormat:audioFormat]) {
            return nil;
        }
    }
    return self;
}

- (void)reconfigureInputEngine {
    if (audioEngine.isRunning) {
        [audioEngine.inputNode removeTapOnBus:0];
        [audioEngine stop];
    }

    if (![self setupAudioEngineWithSampleRate:desiredFormat.sampleRate channelCount:desiredFormat.channelCount audioFormat:(desiredFormat.commonFormat == AVAudioPCMFormatInt16) ? PCM_16BIT : PCM_FLOAT]) {
        return;
    }
}

- (BOOL)setupAudioEngineWithSampleRate:(int)sampleRate
                         channelCount:(int)channelCount
                          audioFormat:(enum AUDIO_FORMATS)audioFormat
{
    audioEngine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = [audioEngine inputNode];
    
    NSError *error = nil;
    
    if (@available(iOS 13.0, *)) {
        // I'd like to not use voice processing when we don't need to, but there's no easy way to tell if sound will be played "out loud" or not.
        [inputNode setVoiceProcessingEnabled:YES error:&error];
        if (error) {
            onError([NSString stringWithFormat:@"Voice processing error: %@", error]);
            return NO;
        }
    } else {
        onError(@"Unsupported iOS version! You must be on version >= 13.0");
        return NO;
    }
    
    AVAudioFormat *inputFormat = [inputNode outputFormatForBus:0];
    
    AVAudioCommonFormat commonFormat = (audioFormat == PCM_16BIT) ? AVAudioPCMFormatInt16 : AVAudioPCMFormatFloat32;
    desiredFormat = [[AVAudioFormat alloc] initWithCommonFormat:commonFormat sampleRate:sampleRate channels:channelCount interleaved:YES];
    
    AVAudioConverter *audioConverter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:desiredFormat];
    if (!audioConverter) {
        onError(@"Conversion to desired format is not possible! Please ensure your stream settings and device capabilities are aligned.");
        return NO;
    }
    
    float sampleRateCoefficient = inputFormat.sampleRate / desiredFormat.sampleRate;
    UInt32 convertedBufferSize = UInt32(_samplingSize * sampleRateCoefficient);
    
    [self installTapOnInputNode:inputNode bufferSize:convertedBufferSize inputFormat:inputFormat audioConverter:audioConverter];
    
    [audioEngine prepare];
    [audioEngine startAndReturnError:&error];
    if (error) {
        onError([NSString stringWithFormat:@"AVAudioEngine start error: %@", error]);
        return NO;
    }
    
    return YES;
}

- (void)installTapOnInputNode:(AVAudioInputNode *)inputNode
                   bufferSize:(UInt32)bufferSize
                  inputFormat:(AVAudioFormat *)inputFormat
               audioConverter:(AVAudioConverter *)audioConverter
{
    if (bufferSize < 128 || inputFormat.sampleRate < 8000) { // 128 samples and 8000 Hz used as a generous minimum. In practice this would probably be too low, but we control this value upstream
        self->onError(@"Invalid input format from node (< 8000 Hz) or buffer size too small (< 128)");
        return;
    }
    
    [inputNode installTapOnBus:0 bufferSize:bufferSize format:inputFormat block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        buffer.frameLength = bufferSize; // The bufferSize argument above is usually ignored. Setting the frameLength like this forces the correct sizing
        
        // Since we are taking the given samplingSize to be in terms of output format, we don't need to adjust frameCapacity on the converted buffer
        AVAudioPCMBuffer *convertedBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self->desiredFormat frameCapacity:(AVAudioFrameCount)self->_samplingSize];
        
        AVAudioConverterInputBlock inputBlock = ^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumPackets, AVAudioConverterInputStatus *outStatus) {
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return buffer;
        };
        
        NSError *conversionError = nil;
        AVAudioConverterOutputStatus status = [audioConverter convertToBuffer:convertedBuffer error:&conversionError withInputFromBlock:inputBlock];
        
        if (status != AVAudioConverterOutputStatus_HaveData) {
            self->onError([NSString stringWithFormat:@"Conversion error: %@", conversionError]);
            return;
        }

        const AudioBufferList *bufferList = convertedBuffer.audioBufferList;
        for (NSUInteger i = 0; i < bufferList->mNumberBuffers; i++) {
            AudioBuffer audioBuffer = bufferList->mBuffers[i];
            NSData *_data = [NSData dataWithBytes:audioBuffer.mData length:audioBuffer.mDataByteSize];
            
            if (!self.muted) {
                self->onChunk(self->chunkId, (unsigned char *)[_data bytes], (unsigned int)[_data length]);
            }
            ++self->chunkId;
        }
    }];
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
