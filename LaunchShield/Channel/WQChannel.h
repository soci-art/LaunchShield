//
//  WQChannel.h
//  LaunchShield
//
//  Thin, Swift-friendly façade over the ported WQAccess channel layer
//  (kolbicz/WQFiles, GPL-3.0-or-later). All container access goes through
//  WQAccess; this file only adapts it to typed results.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Result of one channel operation: never throws, carries a Chinese message.
@interface WQOp : NSObject

@property (nonatomic, readonly) BOOL ok;
@property (nonatomic, readonly, copy, nullable) NSString *error;
@property (nonatomic, readonly, strong, nullable) id value;

+ (instancetype)ok:(nullable id)value;
+ (instancetype)fail:(NSString *)error;

@end

/// One directory entry, already stat'ed.
@interface WQFileItem : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL isDirectory;
@property (nonatomic) BOOL isSymlink;
@property (nonatomic) unsigned long long size;
@property (nonatomic) NSTimeInterval modified;
@property (nonatomic) BOOL isImmutable;
@property (nonatomic) unsigned int posixMode;

@end

/// One app data container found through the container manager.
@interface WQAppContainer : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *category;
@property (nonatomic) BOOL isSystem;

@end

@interface WQChannel : NSObject

+ (instancetype)shared;

/// Full-scan UI bridge: on systems where the quick container queries
/// answer nothing, the scan machinery waits (on a background thread)
/// for the user to OK a long full scan. The app answers with this.
- (void)answerFullScan:(BOOL)yes;
- (void)stopFullScan;

/// Whether the detected signing mode has a working route. When NO, every
/// other call fails and `unavailableReason` says why, in Chinese.
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly, copy, nullable) NSString *groupID;
/// Automatically detected signing mode: @"free" or @"cert".
@property (nonatomic, readonly, copy) NSString *signMethod;
@property (nonatomic, readonly, copy) NSString *unavailableReason;

/// "bad_query", "worse_query" or "kernel"; a Chinese label when there is no
/// route (the version cannot run any backend).
@property (nonatomic, readonly, copy) NSString *routeName;
/// Chinese one-liner with the detected system version.
@property (nonatomic, readonly, copy) NSString *routeDetail;
/// App Group description for the UI; says so when the route needs none.
@property (nonatomic, readonly, copy) NSString *groupText;
@property (nonatomic, readonly) BOOL usesBadQuery;

/// Forgets the cached route so the next query re-reads the signed profile.
- (void)resetRoute;

/// iOS 17.0-18.7.1 runs the kernel chain instead of a container
/// query: no App Group, no signature-method detection, and it must be started
/// once from the home screen (a failed attempt can restart the app).
@property (nonatomic, readonly) BOOL kernelSupported;
@property (nonatomic, readonly) BOOL kernelActive;
@property (nonatomic, readonly) BOOL kernelRunning;
/// Runs the chain. Blocks 10-30 s: call it on a background queue.
- (BOOL)startKernel;

/// Every app data container (the container manager's class 2).
- (NSArray<WQAppContainer *> *)appContainers;
- (nullable WQAppContainer *)containerForBundleID:(NSString *)bundleID;

/// Every App Group (shared) container, labelled by its group identifier.
- (NSArray<WQAppContainer *> *)groupContainers;

- (WQOp *)listDirectory:(NSString *)path;
/// Deep-scan bulk walk (see wq_walk_files): one pass over a whole subtree,
/// files only, unsorted. progress may be nil.
- (WQOp *)walkFiles:(NSString *)path
              limit:(NSInteger)limit
      skipDirNames:(nullable NSSet<NSString *> *)skipDirNames
skipDirSubstrings:(nullable NSArray<NSString *> *)skipDirSubstrings
   skipAccountDirs:(BOOL)skipAccountDirs
           progress:(nullable void (^)(NSInteger visited))progress;
- (WQOp *)statPath:(NSString *)path;
- (WQOp *)fileVersion:(NSString *)path;
- (WQOp *)readFile:(NSString *)path maxBytes:(NSUInteger)maxBytes;

/// In-place overwrite of an existing file (backed up by WQAccess first).
- (WQOp *)writeData:(NSString *)path data:(NSData *)data;
/// In-place 0-byte truncation; the 0-byte replacement the app is built around.
- (WQOp *)truncateFile:(NSString *)path;
- (WQOp *)truncateFile:(NSString *)path expectingVersion:(NSDictionary<NSString *, NSNumber *> *)version;
/// Streams a local file over the target (restore of an existing file).
- (WQOp *)writeFromLocalFile:(NSString *)path source:(NSString *)source;
- (WQOp *)writeFromLocalFile:(NSString *)path source:(NSString *)source expectingVersion:(NSDictionary<NSString *, NSNumber *> *)version;
/// Creates the target from a local file when it no longer exists (restore
/// after a placeholder or a deletion); leaves no partial file on failure.
- (WQOp *)createFromLocalFile:(NSString *)path source:(NSString *)source;
/// Streams the target to a local path (backup).
- (WQOp *)copyToLocalFile:(NSString *)path destination:(NSString *)destination;

- (WQOp *)deletePath:(NSString *)path;
- (WQOp *)createDirectory:(NSString *)path;
- (WQOp *)renamePath:(NSString *)path newName:(NSString *)newName;

- (WQOp *)setImmutable:(BOOL)immutable forPath:(NSString *)path;
- (WQOp *)setMode:(unsigned int)mode forPath:(NSString *)path;
- (BOOL)isImmutable:(NSString *)path;

/// Streaming MD5 (hex, lower case) of a container file.
- (WQOp *)md5OfFile:(NSString *)path;

- (BOOL)fileExists:(NSString *)path;
- (BOOL)isDirectory:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
