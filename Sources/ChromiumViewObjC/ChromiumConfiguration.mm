#import "ChromiumViewObjC.h"

@implementation ChromiumConfiguration

- (instancetype)init {
  if ((self = [super init])) {
    _sandboxDisabled = YES;
  }
  return self;
}

- (id)copyWithZone:(NSZone*)zone {
  ChromiumConfiguration* c = [[ChromiumConfiguration alloc] init];
  c.userAgent = self.userAgent;
  c.locale = self.locale;
  c.cachePath = self.cachePath;
  c.sandboxDisabled = self.sandboxDisabled;
  c.useMockKeychain = self.useMockKeychain;
  return c;
}

@end
