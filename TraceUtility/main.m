//
//  main.m
//  TraceUtility
//
//  Created by Qusic on 7/9/15.
//  Copyright (c) 2015 Qusic. All rights reserved.
//

#import "InstrumentsPrivateHeader.h"
#import <objc/runtime.h>

#define TUPrint(format, ...) CFShow((__bridge CFStringRef)[NSString stringWithFormat:format, ## __VA_ARGS__])
#define TUIvarCast(object, name, type) (*(type *)(void *)&((char *)(__bridge void *)object)[ivar_getOffset(class_getInstanceVariable(object_getClass(object), #name))])
#define TUIvar(object, name) TUIvarCast(object, name, id const)

// Workaround to fix search paths for Instruments plugins and packages.
static NSBundle *(*NSBundle_mainBundle_original)(id self, SEL _cmd);
static NSBundle *NSBundle_mainBundle_replaced(id self, SEL _cmd) {
    return [NSBundle bundleWithPath:@"/Applications/Xcode.app/Contents/Applications/Instruments.app"];
}

static void __attribute__((constructor)) hook() {
    Method NSBundle_mainBundle = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    NSBundle_mainBundle_original = (void *)method_getImplementation(NSBundle_mainBundle);
    method_setImplementation(NSBundle_mainBundle, (IMP)NSBundle_mainBundle_replaced);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Required. Each instrument is a plugin and we have to load them before we can process their data.
        DVTInitializeSharedFrameworks();
        [DVTDeveloperPaths initializeApplicationDirectoryName:@"Instruments"];
        [XRInternalizedSettingsStore configureWithAdditionalURLs:nil];
        [[XRCapabilityRegistry applicationCapabilities]registerCapability:@"com.apple.dt.instruments.track_pinning" versions:NSMakeRange(1, 1)];
        PFTLoadPlugins();

        // Instruments has its own subclass of NSDocumentController without overriding sharedDocumentController method.
        // We have to call this eagerly to make sure the correct document controller is initialized.
        [PFTDocumentController sharedDocumentController];

        // Open a trace document.
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if (arguments.count < 2) {
            TUPrint(@"Usage: %@ [%@]\n", arguments.firstObject.lastPathComponent, @"trace document");
            return 1;
        }
        NSString *tracePath = arguments[1];
        NSError *error = nil;
        PFTTraceDocument *document = [[PFTTraceDocument alloc]initWithContentsOfURL:[NSURL fileURLWithPath:tracePath] ofType:@"com.apple.instruments.trace" error:&error];
        if (error) {
            TUPrint(@"Error: %@\n", error);
            return 1;
        }
        TUPrint(@"Trace: %@\n", tracePath);

        // List some useful metadata of the document.
        XRDevice *device = document.targetDevice;
        TUPrint(@"Device: %@ (%@ %@ %@)\n", device.deviceDisplayName, device.productType, device.productVersion, device.buildVersion);
        PFTProcess *process = document.defaultProcess;
        TUPrint(@"Process: %@ (%@)\n", process.displayName, process.bundleIdentifier);

        // Each trace document consists of data from several different instruments.
        XRTrace *trace = document.trace;
        for (XRInstrument *instrument in trace.allInstrumentsList.allInstruments) {
            TUPrint(@"\nInstrument: %@ (%@)\n", instrument.type.name, instrument.type.uuid);

            // Each instrument can have multiple runs.
            NSArray<XRRun *> *runs = instrument.allRuns;
            if (runs.count == 0) {
                TUPrint(@"No data.\n");
                continue;
            }
            for (XRRun *run in runs) {
                TUPrint(@"Run #%@: %@\n", @(run.runNumber), run.displayName);
                instrument.currentRun = run;

                // Common routine to obtain contexts for the instrument.
                NSMutableArray<XRContext *> *contexts = [NSMutableArray array];
                if (![instrument isKindOfClass:XRLegacyInstrument.class]) {
                    XRAnalysisCoreStandardController *standardController = [[XRAnalysisCoreStandardController alloc]initWithInstrument:instrument document:document];
                    instrument.viewController = standardController;
                    [standardController instrumentDidChangeSwitches];
                    [standardController instrumentChangedTableRequirements];
                    XRAnalysisCoreDetailViewController *detailController = TUIvar(standardController, _detailController);
                    [detailController restoreViewState];
                    XRAnalysisCoreDetailNode *detailNode = TUIvar(detailController, _firstNode);
                    while (detailNode) {
                        [contexts addObject:XRContextFromDetailNode(detailController, detailNode)];
                        detailNode = detailNode.nextSibling;
                    }
                }

                // Different instruments can have different data structure.
                // Here are some straightforward example code demonstrating how to process the data from several commonly used instruments.
                NSString *instrumentID = instrument.type.uuid;
                if ([instrumentID isEqualToString:@"com.apple.xray.instrument-type.coresampler2"]) {
                    // Time Profiler: print out all functions in descending order of self execution time.
                    // 3 contexts: Profile, Narrative, Samples
                    XRContext *context = contexts[0];
                    [context display];
                    XRAnalysisCoreCallTreeViewController *controller = TUIvar(context.container, _callTreeViewController);
                    XRBacktraceRepository *backtraceRepository = TUIvar(controller, _backtraceRepository);
                    static NSMutableArray<PFTCallTreeNode *> * (^ const flattenTree)(PFTCallTreeNode *) = ^(PFTCallTreeNode *rootNode) { // Helper function to collect all tree nodes.
                        NSMutableArray *nodes = [NSMutableArray array];
                        if (rootNode) {
                            [nodes addObject:rootNode];
                            for (PFTCallTreeNode *node in rootNode.children) {
                                [nodes addObjectsFromArray:flattenTree(node)];
                            }
                        }
                        return nodes;
                    };
                    NSMutableArray<PFTCallTreeNode *> *nodes = flattenTree(backtraceRepository.rootNode);
                    [nodes sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:NSStringFromSelector(@selector(terminals)) ascending:NO]]];
                    for (PFTCallTreeNode *node in nodes) {
                        TUPrint(@"%@ %@ %i ms\n", node.libraryName, node.symbolName, node.terminals);
                    }
                } else if ([instrumentID isEqualToString:@"com.apple.xray.instrument-type.oa"]) {
                    // Allocations: print out the memory allocated during each second in descending order of the size.
                    XRObjectAllocInstrument *allocInstrument = (XRObjectAllocInstrument *)instrument;
                    // 4 contexts: Statistics, Call Trees, Allocations List, Generations.
                    [allocInstrument._topLevelContexts[2] display];
                    static NSMutableDictionary<NSNumber*, PFTCallTreeNode *> * (^ const dictrionaryTree)(PFTCallTreeNode *) = ^(PFTCallTreeNode *rootNode) { // Helper function to collect all tree nodes.
                        NSMutableDictionary *nodes = [NSMutableDictionary dictionary];
                        if (rootNode) {
                            [nodes setObject:rootNode forKey:[NSNumber numberWithUnsignedLongLong:[rootNode address]]];
                            for (PFTCallTreeNode *node in rootNode.children) {
                                [nodes setValuesForKeysWithDictionary:dictrionaryTree(node)];
                            }
                        }
                        return nodes;
                    };
                    XRBacktraceRepository *backtraceRepository = [run backtraceRepository];
                    PFTPersistentSymbols *symbols = TUIvar(backtraceRepository, _persistentSymbols);
                    PFTCallTreeNode *root = [backtraceRepository _newTreeRoot];
                    XRManagedEventArrayController *arrayController = TUIvar(TUIvar(allocInstrument, _objectListController), _ac);
                    NSString *filePath = [NSHomeDirectory() stringByAppendingPathComponent:@"test.txt"];
                    NSFileHandle* file =[NSFileHandle fileHandleForWritingAtPath:filePath];
                    for (XRObjectAllocEvent *event in arrayController.arrangedObjects) {
                        id category = event.categoryName;
                        uint64 address = event.address;
                        id eventTypeName = event.eventTypeName;
                        NSNumber *time = @(event.timestamp / NSEC_PER_USEC);
                        NSNumber *size = @(event.size);
                        id result = [NSMutableString stringWithFormat:@"0x%qx,%@,%@,%@,%@", address, category,eventTypeName,time,size];
                        if (event.backtraceIdentifier > 0) {
                            XRRawBacktrace* backtrace = event.backtrace;
                            int traceCount = backtrace.count;
                            if (traceCount > 0) [result appendString:@","];
                            long kernelFrameCount = [backtrace kernelFrameCount];
                            if (kernelFrameCount > 0) {
                            }
                            id library;
                            for(int i = 0; i < traceCount; i++) {
                                unsigned long long * frame = backtrace.frames + i;
                                unsigned long long value = *frame;
                                if (i == traceCount - 1) {
                                    library = [backtraceRepository libraryForAddress:value];
                                }
                                id symbol = [symbols symbolDataForAddress:value isKernelSymbol:false];
                                if (symbol != nil) {
                                    [result appendString:[symbol symbolName]];
                                } else {
                                    [result appendFormat:@"0x%qx", value];
                                }
                                [result appendString:@"\n"];
                            }
                            if (library != nil) {
                                [result appendFormat:@",%@", [library ownerName]];
                            }
                        }
                        [result appendString:@"\n"];
                        [file writeData:[result dataUsingEncoding:NSUTF8StringEncoding]];
                        //[file seekToEndOfFile];
                    }
                    [file closeFile];
                } else {
                    TUPrint(@"Data processor has not been implemented for this type of instrument.\n");
                }

                // Common routine to cleanup after done.
                if (![instrument isKindOfClass:XRLegacyInstrument.class]) {
                    [instrument.viewController instrumentWillBecomeInvalid];
                    instrument.viewController = nil;
                }
            }
        }

        // Close the document safely.
        [document close];
        PFTClosePlugins();
    }
    return 0;
}
