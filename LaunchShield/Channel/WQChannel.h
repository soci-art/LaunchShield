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
@property (nonatomic) BOOL isSystem;

@end

@interface WQChannel : NSObject

+ (instancetype)shared;

/// Whether the signature gave a usable App Group. When NO, every other call
/// fails and `unavailableReason` says why, in Chinese.
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly, copy, nullable) NSString *groupID;
@property (nonatomic, readonly, copy) NSString *unavailableReason;

/// Every app data container (the container manager's class 2).
- (NSArray<WQAppContainer *> *)appContainers;
- (nullable WQAppContainer *)containerForBundleID:(NSString *)bundleID;

- (WQOp *)listDirectory:(NSString *)path;
- (WQOp *)statPath:(NSString *)path;
- (WQOp *)readFile:(NSString *)path maxBytes:(NSUInteger)maxBytes;

/// In-place overwrite of an existing file (backed up by WQAccess first).
- (WQOp *)writeData:(NSString *)path data:(NSData *)data;
/// In-place 0-byte truncation; the 0-byte replacement the app is built around.
- (WQOp *)truncateFile:(NSString *)path;
/// Streams a local file over the target (restore of an existing file).
- (WQOp *)writeFromLocalFile:(NSString *)path source:(NSString *)source;
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
