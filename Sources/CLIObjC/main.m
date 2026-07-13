//
// StockfishEmbedded embeds Stockfish as an in-process engine for Apple platforms.
//
// See README.md and ThirdParty/Stockfish/Copying.txt for upstream attribution and license details.
//
// Licensed under the GNU General Public License v3.0.
// You may obtain a copy of the License at: https://www.gnu.org/licenses/gpl-3.0.html
// See the LICENSE file for more information.
//

#import <Foundation/Foundation.h>
#import "SFEngine.h"

int main(int argc, const char* argv[]) {
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    NSLock* stateLock = [[NSLock alloc] init];
    __block BOOL sawUCIOK = NO;
    __block BOOL sawReadyOK = NO;
    __block BOOL sawLegalBestmove = NO;

    SFEngine* engine = [[SFEngine alloc] initWithLineHandler:^(NSString* line) {
        printf("%s\n", line.UTF8String);

        [stateLock lock];
        if ([line isEqualToString:@"uciok"])
            sawUCIOK = YES;
        else if ([line isEqualToString:@"readyok"])
            sawReadyOK = YES;
        else if ([line rangeOfString:@"^bestmove [a-h][1-8][a-h][1-8][nbrq]?(?: |$)"
                              options:NSRegularExpressionSearch].location != NSNotFound)
            sawLegalBestmove = YES;
        BOOL shouldSignal = sawLegalBestmove;
        [stateLock unlock];

        if (shouldSignal)
            dispatch_semaphore_signal(finished);
    }];

    [engine start];
    [engine sendCommand:@"uci"];
    [engine sendCommand:@"isready"];
    [engine sendCommand:@"position startpos moves e2e4"];
    [engine sendCommand:@"go depth 8"];

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC));
    long waitResult = dispatch_semaphore_wait(finished, timeout);
    [engine stop];

    [stateLock lock];
    BOOL succeeded = waitResult == 0 && sawUCIOK && sawReadyOK && sawLegalBestmove;
    [stateLock unlock];
    if (!succeeded) {
        fprintf(stderr,
                "SFEngine Objective-C smoke test failed: expected uciok, readyok, and a legal bestmove.\n");
        return EXIT_FAILURE;
    }

    return 0;
}
