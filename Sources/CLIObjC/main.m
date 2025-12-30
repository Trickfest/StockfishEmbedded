#import <Foundation/Foundation.h>
#import "SFEngine.h"

int main(int argc, const char* argv[]) {
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);

    SFEngine* engine = [[SFEngine alloc] initWithLineHandler:^(NSString* line) {
        printf("%s\n", line.UTF8String);
        if ([line hasPrefix:@"bestmove"])
            dispatch_semaphore_signal(finished);
    }];

    [engine start];
    [engine sendCommand:@"uci"];
    [engine sendCommand:@"isready"];
    [engine sendCommand:@"position startpos moves e2e4"];
    [engine sendCommand:@"go depth 8"];

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC));
    dispatch_semaphore_wait(finished, timeout);
    [engine stop];

    return 0;
}
