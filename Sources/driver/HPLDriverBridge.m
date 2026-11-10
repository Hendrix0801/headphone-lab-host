//
// HPLDriverBridge.m
// HeadphoneLab driver — ported from eqMac's native/driver/Source/Bridge/EQMDriverBridge.m
// Exports the CFPlugIn factory entry point declared in the bundle's Info.plist.
//

#import "HPLDriverBridge.h"
#import "HeadphoneLabDriver-Swift.h"

void *HPL_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
  return [HPLDriver createWithAllocator:allocator requestedTypeUUID:requestedTypeUUID];
}
