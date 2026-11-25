// Portable implementation helpers for WQAccess; no privileged access is performed here.
#ifndef WQ_ACCESS_SAFETY_H
#define WQ_ACCESS_SAFETY_H
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static inline BOOL WQSameObject(const struct stat *a, const struct stat *b)
{
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}

// Only Apple's documented /var alias is allowed. Do not standardize away '..'
// before walking: every actual ancestor must be opened without following links.
static inline NSString *WQCanonicalVarPath(NSString *path)
{
    if ([path isEqualToString:@"/var"] || [path hasPrefix:@"/var/"])
        return [@"/private" stringByAppendingString:path];
    return path;
}

static inline int WQOpenDirectoryNoLinksFlags(NSString *path, int flags)
{
    path = WQCanonicalVarPath(path);
    if (![path hasPrefix:@"/"] || [path rangeOfString:@"\0"].location != NSNotFound) { errno = EINVAL; return -1; }
    // Ancestors need traversal, not enumeration. A file/folder-specific sandbox
    // extension need not grant read-directory rights on all container parents.
    int fd = open("/", O_SEARCH | O_CLOEXEC);
    if (fd < 0) return -1;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) { close(fd); errno = EINVAL; return -1; }
        int next = openat(fd, part.fileSystemRepresentation, O_SEARCH | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        int err = errno;
        close(fd);
        if (next < 0) { errno = err; return -1; }
        fd = next;
    }
    if (flags == O_SEARCH) return fd;
    int result = openat(fd, ".", flags | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int err = errno;
    close(fd);
    if (result < 0) errno = err;
    return result;
}

static inline int WQOpenDirectoryNoLinks(NSString *path)
{
    return WQOpenDirectoryNoLinksFlags(path, O_RDONLY);
}

static inline BOOL WQSyncDirectory(int fd)
{
    int readable = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (readable < 0) return NO;
    BOOL ok = fsync(readable) == 0;
    int err = errno;
    if (close(readable) != 0 && ok) { ok = NO; err = errno; }
    if (!ok) errno = err;
    return ok;
}

static inline int WQOpenRegularAt(int parent, const char *name, int flags, mode_t mode)
{
    // Never allow truncation before the file type has been verified.
    if (flags & O_TRUNC) { errno = EINVAL; return -1; }
    struct stat entry;
    if (fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(entry.st_mode)) { errno = EINVAL; return -1; }
    } else if (errno != ENOENT || !(flags & O_CREAT)) return -1;
    int fd = openat(parent, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode);
    if (fd < 0) return -1;
    struct stat st = {0};
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        int err = errno;
        if (!S_ISREG(st.st_mode)) err = EINVAL;
        close(fd); errno = err; return -1;
    }
    return fd;
}

static inline BOOL WQWriteBytes(int fd, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    size_t done = 0;
    while (done < data.length) {
        ssize_t n = write(fd, bytes + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return NO; }
        done += (size_t)n;
    }
    return fsync(fd) == 0;
}


static inline BOOL WQAbsolutePathGrammar(NSString *path)
{
    if (![path hasPrefix:@"/"] || path.length < 2 || [path rangeOfString:@"\0"].location != NSNotFound) return NO;
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 1; i < parts.count; i++) {
        NSString *part = parts[i];
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    }
    return YES;
}

static inline int WQCreateDirectoriesNoLinksMode(NSString *path, mode_t mode)
{
    path = WQCanonicalVarPath(path);
    if (!WQAbsolutePathGrammar(path)) { errno = EINVAL; return -1; }
    int fd = open("/", O_SEARCH | O_CLOEXEC);
    if (fd < 0) return -1;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        int next = openat(fd, part.fileSystemRepresentation, O_SEARCH | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (next < 0 && errno == ENOENT) {
            if (mkdirat(fd, part.fileSystemRepresentation, mode) != 0 && errno != EEXIST) { int err = errno; close(fd); errno = err; return -1; }
            if (!WQSyncDirectory(fd)) { int err = errno; close(fd); errno = err; return -1; }
            next = openat(fd, part.fileSystemRepresentation, O_SEARCH | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        }
        int err = errno;
        close(fd);
        if (next < 0) { errno = err; return -1; }
        fd = next;
    }
    int result = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int err = errno;
    close(fd);
    if (result < 0) errno = err;
    return result;
}

static inline int WQCreateDirectoriesNoLinks(NSString *path)
{
    return WQCreateDirectoriesNoLinksMode(path, 0700);
}

static inline BOOL WQBackupStampValid(NSString *stamp)
{
    if (stamp.length < 15) return NO;
    static NSCache<NSString *, NSNumber *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 1024;
    });
    NSNumber *known = [cache objectForKey:stamp];
    if (known) return known.boolValue;

    // Recognize the historical second/millisecond stamps and the current
    // millisecond-counter format. No arbitrary directory can become a restore.
    NSString *pattern = @"^[0-9]{8}-[0-9]{6}(-[0-9]{3}(-[1-9][0-9]*)?)?$";
    NSRange match = [stamp rangeOfString:pattern options:NSRegularExpressionSearch];
    if (match.location != 0 || match.length != stamp.length) return NO;
    NSArray *parts = [stamp componentsSeparatedByString:@"-"];
    if (parts.count == 4) {
        uint64_t number = 0;
        for (NSUInteger i = 0; i < [parts[3] length]; i++) {
            unsigned digit = [parts[3] characterAtIndex:i] - '0';
            if (number > (UINT64_MAX - digit) / 10) return NO;
            number = number * 10 + digit;
        }
    }
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    fmt.lenient = NO;
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *datePart = [stamp substringToIndex:15];
    NSDate *date = [fmt dateFromString:datePart];
    BOOL valid = date && [[fmt stringFromDate:date] isEqualToString:datePart];
    [cache setObject:@(valid) forKey:stamp];
    return valid;
}

// One numeric field of a valid stamp (digits only, overflow already ruled out
// by WQBackupStampValid).
static inline uint64_t WQBackupStampField(NSString *part)
{
    uint64_t number = 0;
    for (NSUInteger i = 0; i < part.length; i++) number = number * 10 + (uint64_t)([part characterAtIndex:i] - '0');
    return number;
}

// Chronological order of backup unit names: date-time, then milliseconds,
// then the counter as a number ("-10" is newer than "-9"). A legacy stamp
// without milliseconds or counter sorts before one with them at the same
// prefix. Invalid names fall back to text order, after every valid stamp.
// The time is local wall-clock time: a later clock or time-zone rollback can
// still make a newer unit compare older (the format stores no offset).
static inline NSComparisonResult WQBackupStampCompare(NSString *a, NSString *b)
{
    BOOL validA = WQBackupStampValid(a), validB = WQBackupStampValid(b);
    if (!validA || !validB) {
        if (validA != validB) return validA ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }
    NSArray<NSString *> *pa = [a componentsSeparatedByString:@"-"], *pb = [b componentsSeparatedByString:@"-"];
    for (NSUInteger i = 0; i < MAX(pa.count, pb.count); i++) {
        if (i >= pa.count) return NSOrderedAscending;
        if (i >= pb.count) return NSOrderedDescending;
        uint64_t x = WQBackupStampField(pa[i]), y = WQBackupStampField(pb[i]);
        if (x != y) return x < y ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}
// iOS 27.2 replaced the container's identifier attribute with
// "com.apple.containermanager.identity", text lines such as
// "v: 01", "schema: 002", "uuid: …", "identifier: group.com.apple.newsd".
// Returns the identifier, or nil when the text has none or several.
static inline NSString *WQIdentityAttributeIdentifier(NSData *value)
{
    if (value.length == 0 || value.length > 4096) return nil;
    NSString *text = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    if (!text) return nil;
    NSString *found = nil;
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![line hasPrefix:@"identifier:"]) continue;
        NSString *ident = [[line substringFromIndex:11] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!ident.length || [ident rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return nil;
        if (found) return nil;
        found = ident;
    }
    return found;
}
#endif
