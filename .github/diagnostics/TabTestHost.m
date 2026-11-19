#import <AppKit/AppKit.h>
#import <XCTest/XCTest.h>

@interface TabTestHost : NSObject <NSApplicationDelegate, XCTestObservation>
@end

@implementation TabTestHost
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *path = NSProcessInfo.processInfo.environment[@"ELIGO_TAB_TEST_BUNDLE"];
        NSError *error = nil;
        if (![[NSBundle bundleWithPath:path] loadAndReturnError:&error]) {
            fprintf(stderr, "Cannot load test bundle: %s\n", error.localizedDescription.UTF8String);
            exit(2);
        }
        Class cls = NSClassFromString(@"EligoTests.ChooserKeyboardFocusTests");
        NSString *method = @"testTabToNormalRowHighlightsAndActivatesThatBrowser";
        NSPredicate *matches = [NSPredicate predicateWithFormat:@"name CONTAINS %@", method];
        XCTestSuite *suite = [cls defaultTestSuite];
        NSArray<XCTest *> *cases = [suite.tests filteredArrayUsingPredicate:matches];
        if (cases.count != 1) {
            fprintf(stderr, "Found %lu matching tests\n", (unsigned long)cases.count);
            exit(2);
        }
        [XCTestObservationCenter.sharedTestObservationCenter addTestObserver:self];
        XCTest *test = cases.firstObject;
        [test runTest];
        XCTestRun *run = test.testRun;
        printf("ELIGO_HOST_TEST executed=%lu skipped=%lu failures=%lu passed=%s\n",
               (unsigned long)run.executionCount, (unsigned long)run.skipCount,
               (unsigned long)run.totalFailureCount, run.hasSucceeded ? "true" : "false");
        exit(run.hasSucceeded ? 0 : 1);
    });
}

- (void)testCase:(XCTestCase *)testCase didRecordIssue:(XCTIssue *)issue {
    printf("ELIGO_HOST_ASSERT %s\n", issue.compactDescription.UTF8String);
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        __attribute__((objc_precise_lifetime)) TabTestHost *host = [[TabTestHost alloc] init];
        app.delegate = host;
        [app run];
        return 2;
    }
}
