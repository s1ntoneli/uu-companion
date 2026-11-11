#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef void* (*Factory)(CFAllocatorRef, CFUUIDRef);

int main(int argc, char **argv) {
  const char *library=argc > 1 ? argv[1] : "./build/UUMicNative.driver/Contents/MacOS/UUMicNative";
  void *handle=dlopen(library, RTLD_NOW | RTLD_LOCAL);
  if (!handle) { printf("dlopen failed: %s\n", dlerror()); return 1; }
  Factory factory=(Factory)dlsym(handle,"UUMicCreate");
  if (!factory) { puts("factory export missing"); return 2; }
  CFUUIDRef type=CFUUIDCreateFromString(kCFAllocatorDefault,CFSTR("443ABAB8-E7B3-491A-B985-BEB9187030DB"));
  AudioServerPlugInDriverRef driver=(AudioServerPlugInDriverRef)factory(kCFAllocatorDefault,type);
  if(!driver || !(*driver)) { puts("factory returned null"); return 3; }
  AudioObjectPropertyAddress a={'uuap', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  printf("property present: %u\n",(*driver)->HasProperty(driver,2,0,&a));
  Boolean settable=false;
  OSStatus status=(*driver)->IsPropertySettable(driver,2,0,&a,&settable);
  printf("settable status: %d, value: %u\n",(int)status,settable);
  AudioObjectPropertyAddress infoAddr={kAudioObjectPropertyCustomPropertyInfoList,
                                       kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
  UInt32 listSize=0;
  OSStatus infoStatus=(*driver)->GetPropertyDataSize(driver,2,0,&infoAddr,0,NULL,&listSize);
  AudioServerPlugInCustomPropertyInfo custom={0};
  UInt32 readSize=0;
  OSStatus infoRead=(*driver)->GetPropertyData(driver,2,0,&infoAddr,0,NULL,
                                         sizeof(custom),&readSize,&custom);
  printf("custom info status=%d size=%u selector=0x%x dataType=%u read=%d\n",
         (int)infoStatus,listSize,custom.mSelector,custom.mPropertyDataType,(int)infoRead);
  if(infoStatus || infoRead || custom.mSelector != 'uuap') return 8;
  printf("start IO status: %d\n",(int)(*driver)->StartIO(driver,2,50));
  const unsigned N=6000;
  float *pcm=calloc(N*2,sizeof(float));
  for(unsigned i=0;i<N;i++) {
    float v=0.14f*sinf((float)i*2*3.1415926535f*440.0f/48000.0f);
    pcm[i*2]=v;
    pcm[i*2+1]=v;
  }
  CFDataRef block=CFDataCreate(kCFAllocatorDefault,(const UInt8*)pcm,N*8);
  status=(*driver)->SetPropertyData(driver,2,0,&a,0,NULL,sizeof(block),&block);
  CFRelease(block);
  printf("inject CFData status: %d\n",(int)status);
  float out[480*2]={0};
  AudioServerPlugInIOCycleInfo cycle={0};
  OSStatus readStatus=(*driver)->DoIOOperation(driver,2,3,50,'read',480,&cycle,out,NULL);
  unsigned nz=0;
  float peak=0;
  for(int i=0;i<480*2;i++) {
    float v=fabsf(out[i]);
    if(v>0.0001f) nz++;
    if(v>peak) peak=v;
  }
  printf("readStatus=%d nonzero=%u peak=%.5f\n",(int)readStatus,nz,peak);
  printf("stopStatus=%d\n",(int)(*driver)->StopIO(driver,2,50));
  free(pcm);
  if(status != 0 || readStatus != 0 || nz<300) return 5;
  puts("PASS native driver ABI/ring test");
  return 0;
}
