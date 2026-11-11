#include <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>
#include <stdint.h>
static atomic_uint frames = 0, nonzero = 0;
static atomic_uint peak = 0;
static void cb(void* opaque, AudioQueueRef q, AudioQueueBufferRef b,
               const AudioTimeStamp* ts, UInt32 packets, const AudioStreamPacketDescription* desc) {
    (void)opaque; (void)ts; (void)packets; (void)desc;
    const int16_t* data = (const int16_t*)b->mAudioData;
    unsigned n=b->mAudioDataByteSize / 2, z=0, m=0;
    for(unsigned i=0;i<n;i++) {
        unsigned v=(unsigned)abs((int)data[i]);
        z += v>2;
        if(v>m)m=v;
    }
    atomic_fetch_add(&frames,n);
    atomic_fetch_add(&nonzero,z);
    unsigned prev=atomic_load(&peak);
    while(m>prev && !atomic_compare_exchange_weak(&peak,&prev,m)){}
    AudioQueueEnqueueBuffer(q,b,0,NULL);
}
int main(void){
    setvbuf(stdout,NULL,_IOLBF,0);
    AudioStreamBasicDescription fmt={0};
    fmt.mSampleRate=44100;
    fmt.mFormatID=kAudioFormatLinearPCM;
    fmt.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket=2;fmt.mFramesPerPacket=1;fmt.mBytesPerFrame=2;
    fmt.mChannelsPerFrame=1;fmt.mBitsPerChannel=16;
    AudioQueueRef q=NULL;
    printf("AudioQueueNewInput starting\n");
    OSStatus s=AudioQueueNewInput(&fmt,cb,NULL,NULL,NULL,0,&q);
    printf("AudioQueueNewInput status=%d\n",(int)s);
    if(s) return 2;
    for(int i=0;i<4;i++){
        AudioQueueBufferRef b=NULL;
        s=AudioQueueAllocateBuffer(q,2048,&b);
        if(s){printf("allocate status=%d\n",(int)s);return 3;}
        s=AudioQueueEnqueueBuffer(q,b,0,NULL);
        if(s){printf("enqueue status=%d\n",(int)s);return 4;}
    }
    printf("AudioQueueStart starting\n");
    s=AudioQueueStart(q,NULL);
    printf("AudioQueueStart status=%d\n",(int)s);
    if(s){AudioQueueDispose(q,true);return 5;}
    sleep(3);
    printf("frames=%u nonzero=%u peak=%u\n",atomic_load(&frames),atomic_load(&nonzero),atomic_load(&peak));
    AudioQueueStop(q,true);
    AudioQueueDispose(q,true);
    return 0;
}
