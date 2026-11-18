//
//  WQBadQuery.h
//  LaunchShield
//
//  GPL-3.0-or-later. bad_query by Taj C / forcequitOS (via the 3106
//  reference sources): a container-manager query that borrows a
//  system group container and walks up and back down to the target
//  path, so paths worse_query cannot grant on iOS 26 — a container
//  root itself, say — still get a sandbox token.
//

#ifndef WQBadQuery_h
#define WQBadQuery_h

#include <stdbool.h>
#include <stdint.h>

/// Obtains a sandbox extension for `path` through the traversal query.
/// `group_identifier` NULL means the system-group traversal (class 13);
/// a non-NULL identifier queries that app group instead (class 7).
/// Returns a handle >= 0 to release with wq_bad_query_release, or a
/// negative stage code when the daemon denies the query.
int64_t wq_bad_query(char *path, bool create, char *group_identifier, bool is_group);
void wq_bad_query_release(int64_t handle);

#endif /* WQBadQuery_h */
