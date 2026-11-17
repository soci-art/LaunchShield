/*
 *  bad_query.h
 *  LaunchShield
 *
 *  GPL-3.0-or-later. See bad_query.c and NOTICE.md.
 */

#ifndef bad_query_h
#define bad_query_h

#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>

int64_t bad_query(char* path, bool create, char *group_identifier, bool is_group);
void bad_query_release(int64_t handle);

#endif
