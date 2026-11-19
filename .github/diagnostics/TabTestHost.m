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
        XCTestSuite *suite = [cls defaultTestSuite];
        NSArray<NSString *> *methods = [NSProcessInfo.processInfo.environment[@"ELIGO_TAB_METHODS"]
                                       componentsSeparatedByString:@","];
        if (!methods.count) { exit(2); }
        [XCTestObservationCenter.sharedTestObservationCenter addTestObserver:self];
        BOOL allPassed = YES;
        for (NSString *method in methods) {
            NSPredicate *matches = [NSPredicate predicateWithFormat:@"name CONTAINS %@", method];
            NSArray<XCTest *> *cases = [suite.tests filteredArrayUsingPredicate:matches];
            if (cases.count != 1) {
                fprintf(stderr, "Found %lu matches for %s\n", (unsigned long)cases.count, method.UTF8String);
                exit(2);
            }
            XCTest *test = cases.firstObject;
            [test runTest];
            XCTestRun *run = test.testRun;
            BOOL passed = run.executionCount == 1 && run.skipCount == 0 && run.hasSucceeded;
            printf("ELIGO_HOST_TEST method=%s executed=%lu skipped=%lu failures=%lu passed=%s fullAccess=%s\n",
                   method.UTF8String, (unsigned long)run.executionCount, (unsigned long)run.skipCount,
                   (unsigned long)run.totalFailureCount, passed ? "true" : "false",
                   NSApp.isFullKeyboardAccessEnabled ? "true" : "false");
            allPassed = allPassed && passed;
        }
        exit(allPassed ? 0 : 1);
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
